//
//  CameraManager.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import Foundation
@preconcurrency import AVFoundation
import Observation
import Photos
import UIKit

@Observable
class CameraManager {
    var session = AVCaptureSession()

    // MARK: - Control state shown in the UI

    private(set) var flash: FlashSetting = .auto
    private(set) var isLivePhotoOn = false
    private(set) var aspectRatio: AspectRatio = .fourByThree
    private(set) var timer: TimerSetting = .off
    private(set) var style: PhotoStyle = .standard
    private(set) var isDepthOn = false
    private(set) var isNightModeOn = false
    private(set) var isCenterStageOn = false
    private(set) var format: PhotoFormat = .heif
    private(set) var isHistogramOn = false
    /// Exposure compensation in EV stops.
    private(set) var exposureBias: Float = 0
    // Manual values. `nil` means the camera manages that setting automatically.
    private(set) var focusPosition: Float?
    private(set) var shutterSeconds: Double?
    private(set) var whiteBalanceKelvin: Float?
    private(set) var aperture: Float?
    /// Luminance histogram, normalised to 0...1 per bin. Updated while the histogram is on.
    private(set) var histogram: [Float] = []

    // MARK: - Capture state

    /// True from pressing the shutter until the photo is saved.
    private(set) var isCapturing = false
    /// Seconds left on the self-timer, or `nil` when no countdown is running.
    private(set) var countdown: Int?
    /// Photos library identifier of the most recently saved photo, picked up by the gallery.
    private(set) var lastSavedAssetIdentifier: String?
    /// Goes up by one each time the sensor fires, so the view can blink the screen.
    private(set) var shutterCount = 0

    // MARK: - Capture pipeline

    private(set) var device: AVCaptureDevice?
    private(set) var isUsingFrontCamera = false
    /// Zoom buttons to show, e.g. [0.5, 1, 2, 5], depending on the phone's lenses.
    private(set) var zoomStops: [CGFloat] = [1, 2]
    /// Current zoom relative to the main 1× lens.
    private(set) var zoomLevel: CGFloat = 1
    private var videoInput: AVCaptureDeviceInput?
    let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let histogramProcessor = HistogramProcessor()
    /// Supplies camera frames to the auto-rendering coach.
    let frameGrabber = FrameGrabber()
    private let sessionQueue = DispatchQueue(label: "CameraManager.session")
    private let videoQueue = DispatchQueue(label: "CameraManager.video")
    /// Keeps each capture's delegate alive until its photo is saved.
    private var inProgressCaptures: [Int64: PhotoCaptureProcessor] = [:]
    private var countdownTask: Task<Void, Never>?
    /// Tracks how the phone is held so photos are saved upright.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// True when the back camera has a physically adjustable aperture (iPhone 18 Pro / Pro Max).
    /// Checks the hardware capability instead of the model name, so it also covers future devices.
    static var supportsVariableAperture: Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }
        return camera.formats.contains { $0.minLensAperture < $0.maxLensAperture }
    }

    init() {
        // Frames are processed off the main thread; hop back to publish the result.
        let update: @MainActor ([Float]) -> Void = { [weak self] bins in
            self?.histogram = bins
        }
        histogramProcessor.onUpdate = { bins in
            Task { @MainActor in update(bins) }
        }
    }

    func configure(){
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back) else{
            print("Sorry the camera got munched")
            return
            
        }
        device = camera
        session.beginConfiguration()
        session.sessionPreset = .photo
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
        } catch {
            print("Something went wrong: \(error)")
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Pipeline-level features must be enabled before the session starts running.
            photoOutput.maxPhotoQualityPrioritization = .quality
            configurePhotoPipeline()
        }
        // Frames from this output feed the histogram.
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(videoOutput)
        }
        // A second video output, only for the auto-rendering coach.
        if session.canAddOutput(frameGrabber.output) {
            session.addOutput(frameGrabber.output)
        }
        session.commitConfiguration()
        isLivePhotoOn = photoOutput.isLivePhotoCaptureEnabled
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        refreshZoomStops()
    }

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for:.video)
        guard granted else {
            print("sorry ur device does not like us")
            return
        }
       
        configure()
        // startRunning() blocks, so keep it off the main thread.
        let session = session
        sessionQueue.async {
            session.startRunning()
        }
    }

    // MARK: - Switching cameras and lenses

    /// Swaps between the back and front cameras. Returns a message if it couldn't switch.
    func switchCamera() -> String? {
        guard videoInput != nil else { return "The camera isn't available" }
        let newPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .back : .front
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
            return "That camera isn't available"
        }
        guard use(newDevice) else { return "Couldn't switch cameras" }
        isUsingFrontCamera = newPosition == .front
        zoomLevel = 1
        refreshZoomStops()
        return nil
    }

    /// Zooms like the Camera app's lens buttons: below 1× uses the ultra wide lens, the
    /// telephoto's native zoom uses the telephoto, and everything else zooms the main lens.
    func setZoom(_ level: CGFloat) -> String? {
        guard videoInput != nil, var target = device else { return "The camera isn't available" }
        // The two-lens depth camera handles its own lens switching.
        if target.isVirtualDevice {
            zoomLevel = level
            applyZoomOnCurrentDevice(level)
            return nil
        }
        var lensZoom = level
        if !isUsingFrontCamera, let wide = Self.backCamera(.builtInWideAngleCamera) {
            if level < 1, let ultraWide = Self.backCamera(.builtInUltraWideCamera) {
                target = ultraWide
                lensZoom = level / (Self.magnification(of: ultraWide, relativeTo: wide) ?? 0.5)
            } else if let telephoto = Self.backCamera(.builtInTelephotoCamera),
                      let teleZoom = Self.magnification(of: telephoto, relativeTo: wide),
                      teleZoom > 2, level >= teleZoom.rounded() {
                target = telephoto
                lensZoom = level / teleZoom
            } else {
                target = wide
            }
        }
        if target.uniqueID != device?.uniqueID {
            guard use(target) else { return "Couldn't change lens" }
        }
        zoomLevel = level
        configureDevice { device in
            let factor = min(max(lensZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.ramp(toVideoZoomFactor: factor, withRate: 16)
        }
        return nil
    }

    /// Zooms a multi-lens (virtual) camera, where zoom factor 1 is its widest lens, so
    /// "1×" sits at the first lens switch-over point.
    private func applyZoomOnCurrentDevice(_ level: CGFloat) {
        configureDevice { device in
            let oneX = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
            let factor = min(max(level * oneX, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.ramp(toVideoZoomFactor: factor, withRate: 16)
        }
    }

    /// Works out which zoom buttons this camera can offer.
    private func refreshZoomStops() {
        if device?.isVirtualDevice == true {
            zoomStops = [1, 2]
            return
        }
        guard !isUsingFrontCamera, let wide = Self.backCamera(.builtInWideAngleCamera) else {
            zoomStops = [1, 2]
            return
        }
        var stops: [CGFloat] = []
        if Self.backCamera(.builtInUltraWideCamera) != nil {
            stops.append(0.5)
        }
        stops += [1, 2]
        if let telephoto = Self.backCamera(.builtInTelephotoCamera),
           let teleZoom = Self.magnification(of: telephoto, relativeTo: wide), teleZoom > 2 {
            stops.append(teleZoom.rounded())
        }
        zoomStops = stops
    }

    private static func backCamera(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        AVCaptureDevice.default(type, for: .video, position: .back)
    }

    /// How much a lens magnifies compared with the main 1× lens, e.g. about 0.5 or 5.
    private static func magnification(of lens: AVCaptureDevice, relativeTo wide: AVCaptureDevice) -> CGFloat? {
        guard lens.nominalFocalLengthIn35mmFilm > 0, wide.nominalFocalLengthIn35mmFilm > 0 else { return nil }
        return CGFloat(lens.nominalFocalLengthIn35mmFilm / wide.nominalFocalLengthIn35mmFilm)
    }

    /// Replaces the session's camera input with `newDevice` and resets settings that
    /// belonged to the old one. Returns false if the session can't use it.
    private func use(_ newDevice: AVCaptureDevice) -> Bool {
        guard let currentInput = videoInput,
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return false }

        session.beginConfiguration()
        session.removeInput(currentInput)
        guard session.canAddInput(newInput) else {
            session.addInput(currentInput)
            session.commitConfiguration()
            return false
        }
        session.addInput(newInput)
        videoInput = newInput
        device = newDevice

        // Photo features depend on the camera, so re-check what this one supports.
        if format == .proRAW && !photoOutput.isAppleProRAWSupported {
            format = .heif
        }
        configurePhotoPipeline()
        let keepDepth = isDepthOn && photoOutput.isDepthDataDeliverySupported
        photoOutput.isDepthDataDeliveryEnabled = keepDepth
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = keepDepth && photoOutput.isPortraitEffectsMatteDeliverySupported
        session.commitConfiguration()

        isDepthOn = keepDepth
        isCenterStageOn = newDevice.activeFormat.isCenterStageSupported && AVCaptureDevice.isCenterStageEnabled
        // Manual values belonged to the old lens, so hand them back to auto.
        exposureBias = 0
        focusPosition = nil
        shutterSeconds = nil
        whiteBalanceKelvin = nil
        aperture = nil
        _ = setNightMode(isNightModeOn)
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
        return true
    }

    /// Turns on the photo output features for the current format. iOS can't shoot Apple
    /// ProRAW and Live Photos together, so ProRAW is only enabled while RAW is chosen.
    /// Call inside begin/commitConfiguration.
    private func configurePhotoPipeline() {
        photoOutput.isAppleProRAWEnabled = format == .proRAW && photoOutput.isAppleProRAWSupported
        photoOutput.isLivePhotoCaptureEnabled = !photoOutput.isAppleProRAWEnabled && photoOutput.isLivePhotoCaptureSupported
    }

    /// Live Photos are recorded only when the person wants them and the pipeline allows it.
    var isLivePhotoActive: Bool {
        isLivePhotoOn && photoOutput.isLivePhotoCaptureEnabled
    }

    // MARK: - Tap controls

    /// Handles a tap on a toggle or multi-option control and returns a short status message.
    func activate(_ control: PhotoControl) -> String {
        switch control {
        case .flash:
            flash = flash.next
            return "Flash \(flash.title)"
        case .live:
            if format == .proRAW { return "Live Photos are off while shooting RAW" }
            guard photoOutput.isLivePhotoCaptureEnabled else { return "Live Photos aren't available on this camera" }
            isLivePhotoOn.toggle()
            return isLivePhotoOn ? "Live On" : "Live Off"
        case .aspect:
            aspectRatio = aspectRatio.next
            return aspectRatio.title
        case .timer:
            timer = timer.next
            return "Timer \(timer.title)"
        case .styles:
            style = style.next
            return "Style: \(style.title)"
        case .depth:
            return setDepth(!isDepthOn)
        case .nightMode:
            return setNightMode(!isNightModeOn)
        case .centerStage:
            return setCenterStage(!isCenterStageOn)
        case .format:
            let wasRAW = format == .proRAW
            format = format.next
            // Skip ProRAW on cameras that can't shoot it.
            if format == .proRAW && !photoOutput.isAppleProRAWSupported {
                format = format.next
            }
            // Entering or leaving RAW swaps ProRAW and Live Photos in the pipeline.
            if wasRAW != (format == .proRAW) {
                session.beginConfiguration()
                configurePhotoPipeline()
                session.commitConfiguration()
            }
            return format == .proRAW ? "Format: RAW (Live off)" : "Format: \(format.title)"
        case .histogram:
            return setHistogram(!isHistogramOn)
        case .exposure, .focus, .shutterSpeed, .whiteBalance, .lensAperture:
            // Slider controls are adjusted through setAdjustment(_:for:).
            return control.title
        }
    }

    private func setDepth(_ on: Bool) -> String {
        guard videoInput != nil else { return "The camera isn't available" }
        if on && !isUsingFrontCamera && !photoOutput.isDepthDataDeliverySupported {
            // A single lens can't measure depth, so switch to the two-lens back camera.
            guard let depthCamera = Self.backCamera(.builtInDualWideCamera) ?? Self.backCamera(.builtInDualCamera),
                  use(depthCamera) else {
                return "Depth isn't available on this camera"
            }
            zoomLevel = 1
            refreshZoomStops()
            applyZoomOnCurrentDevice(1)
        } else if !on && device?.isVirtualDevice == true {
            // Back to the main lens, which allows full manual control.
            if let wide = Self.backCamera(.builtInWideAngleCamera), use(wide) {
                zoomLevel = 1
                refreshZoomStops()
            }
            isDepthOn = false
            return "Depth Off"
        }
        guard photoOutput.isDepthDataDeliverySupported else { return "Depth isn't available on this camera" }
        session.beginConfiguration()
        photoOutput.isDepthDataDeliveryEnabled = on
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = on && photoOutput.isPortraitEffectsMatteDeliverySupported
        session.commitConfiguration()
        isDepthOn = on
        return on ? "Depth On" : "Depth Off"
    }

    /// Night mode lets auto-exposure use much longer shutter times (brighter in the dark,
    /// visible in the viewfinder), boosts low light where supported, and uses
    /// multi-frame fusion at capture.
    private func setNightMode(_ on: Bool) -> String {
        isNightModeOn = on
        configureDevice { device in
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = on
            }
            if on {
                let longest = CMTime(seconds: 1.0 / 4, preferredTimescale: 1_000_000)
                device.activeMaxExposureDuration = min(longest, device.activeFormat.maxExposureDuration)
            } else {
                // .invalid restores the camera's normal limit.
                device.activeMaxExposureDuration = .invalid
            }
        }
        return on ? "Night Mode On" : "Night Mode Off"
    }

    private func setCenterStage(_ on: Bool) -> String {
        guard let device, device.activeFormat.isCenterStageSupported else {
            return "Center Stage isn't available on this camera"
        }
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = on
        isCenterStageOn = on
        return on ? "Center Stage On" : "Center Stage Off"
    }

    private func setHistogram(_ on: Bool) -> String {
        isHistogramOn = on
        if on {
            videoOutput.setSampleBufferDelegate(histogramProcessor, queue: videoQueue)
        } else {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            histogram = []
        }
        return on ? "Histogram On" : "Histogram Off"
    }

    // MARK: - Slider controls

    /// Slider range for a control. Shutter speed uses log2(seconds) so each step is one stop.
    func sliderRange(for control: PhotoControl) -> ClosedRange<Float> {
        switch control {
        case .exposure:
            return -2...2
        case .focus:
            return 0...1
        case .shutterSpeed:
            let fastest = max(1.0 / 8000, device?.activeFormat.minExposureDuration.seconds ?? 1.0 / 8000)
            let slowest = min(1.0, device?.activeFormat.maxExposureDuration.seconds ?? 1.0)
            return Float(log2(fastest))...Float(log2(max(slowest, fastest * 2)))
        case .whiteBalance:
            return 2500...8000
        case .lensAperture:
            if let format = device?.activeFormat, format.minLensAperture < format.maxLensAperture {
                return format.minLensAperture...format.maxLensAperture
            }
            return 1.4...8
        default:
            return 0...1
        }
    }

    /// Current slider position: the manual value if set, otherwise what the camera is using now.
    func sliderValue(for control: PhotoControl) -> Float {
        let value: Float
        switch control {
        case .exposure:
            value = exposureBias
        case .focus:
            value = focusPosition ?? device?.lensPosition ?? 0.5
        case .shutterSpeed:
            value = Float(log2(shutterSeconds ?? device?.exposureDuration.seconds ?? 1.0 / 125))
        case .whiteBalance:
            if let whiteBalanceKelvin {
                value = whiteBalanceKelvin
            } else if let device {
                value = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
            } else {
                value = 5500
            }
        case .lensAperture:
            value = aperture ?? device?.lensAperture ?? sliderRange(for: control).lowerBound
        default:
            value = 0
        }
        let range = sliderRange(for: control)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func isAuto(_ control: PhotoControl) -> Bool {
        switch control {
        case .exposure: exposureBias == 0
        case .focus: focusPosition == nil
        case .shutterSpeed: shutterSeconds == nil
        case .whiteBalance: whiteBalanceKelvin == nil
        case .lensAperture: aperture == nil
        default: true
        }
    }

    func sliderLabel(for control: PhotoControl) -> String {
        if control != .exposure && isAuto(control) { return "Auto" }
        let value = sliderValue(for: control)
        switch control {
        case .exposure:
            return String(format: "%+.1f EV", value)
        case .focus:
            return "\(Int((value * 100).rounded()))%"
        case .shutterSpeed:
            let seconds = pow(2, Double(value))
            return seconds >= 0.5 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
        case .whiteBalance:
            return "\(Int(value.rounded()))K"
        case .lensAperture:
            return String(format: "ƒ/%.1f", value)
        default:
            return ""
        }
    }

    func setAdjustment(_ value: Float, for control: PhotoControl) {
        switch control {
        case .exposure:
            exposureBias = value
            configureDevice { device in
                device.setExposureTargetBias(min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias))
            }
        case .focus:
            focusPosition = value
            configureDevice { device in
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: value)
                }
            }
        case .shutterSpeed:
            // Shutter priority: lock the duration and keep the current ISO.
            shutterSeconds = pow(2, Double(value))
            aperture = nil
            let target = CMTime(seconds: pow(2, Double(value)), preferredTimescale: 1_000_000)
            configureDevice { device in
                guard device.isExposureModeSupported(.custom) else { return }
                let format = device.activeFormat
                let duration = min(max(target, format.minExposureDuration), format.maxExposureDuration)
                device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
            }
        case .whiteBalance:
            whiteBalanceKelvin = value
            configureDevice { device in
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                var gains = device.deviceWhiteBalanceGains(for: .init(temperature: value, tint: 0))
                // Gains outside 1...maxWhiteBalanceGain throw, so clamp each channel.
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        case .lensAperture:
            // Aperture priority: lock the aperture and let auto-exposure pick shutter and ISO.
            aperture = value
            shutterSeconds = nil
            configureDevice { device in
                let format = device.activeFormat
                guard format.minLensAperture < format.maxLensAperture else { return }
                let fStop = min(max(value, format.minLensAperture), format.maxLensAperture)
                guard format.supportsExposureModeCustom(lensAperture: fStop,
                                                        duration: AVCaptureDevice.autoExposureDuration,
                                                        iso: AVCaptureDevice.autoISO) else { return }
                device.setExposureModeCustom(lensAperture: fStop,
                                             duration: AVCaptureDevice.autoExposureDuration,
                                             iso: AVCaptureDevice.autoISO,
                                             completionHandler: nil)
            }
        default:
            break
        }
    }

    /// Returns a slider control to automatic (or 0 EV for exposure).
    func resetAdjustment(_ control: PhotoControl) {
        switch control {
        case .exposure:
            setAdjustment(0, for: .exposure)
        case .focus:
            focusPosition = nil
            configureDevice { device in
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
        case .shutterSpeed, .lensAperture:
            shutterSeconds = nil
            aperture = nil
            configureDevice { device in
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        case .whiteBalance:
            whiteBalanceKelvin = nil
            configureDevice { device in
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        default:
            break
        }
    }

    // MARK: - Capture

    /// Builds photo settings from the current controls, ready for the shutter button.
    func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        switch format {
        case .proRAW:
            if let raw = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
        case .jpeg:
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        case .heif:
            settings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
        }
        if photoOutput.supportedFlashModes.contains(flash.avMode) {
            settings.flashMode = flash.avMode
        }
        if isLivePhotoActive {
            settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
        }
        settings.isDepthDataDeliveryEnabled = isDepthOn && photoOutput.isDepthDataDeliveryEnabled
        settings.isPortraitEffectsMatteDeliveryEnabled = isDepthOn && photoOutput.isPortraitEffectsMatteDeliveryEnabled
        // Manual shutter/aperture are only honoured at .speed; night mode wants maximum fusion.
        if shutterSeconds != nil || aperture != nil {
            settings.photoQualityPrioritization = .speed
        } else {
            settings.photoQualityPrioritization = isNightModeOn ? .quality : .balanced
        }
        return settings
    }

    // MARK: - Taking photos

    /// Called by the shutter button. Starts the self-timer if one is set, cancels a running
    /// countdown if tapped again, otherwise takes the photo. Returns a message to show, if any.
    func shutterTapped() async -> String? {
        if countdownTask != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            return "Timer Cancelled"
        }
        guard !isCapturing else { return nil }
        guard timer != .off else { return await capturePhoto() }

        let task = Task { [timer] in
            for remaining in stride(from: timer.seconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
        countdownTask = task
        await task.value
        // A cancelled countdown already reported itself when the shutter was tapped again.
        guard countdownTask != nil, !task.isCancelled else { return nil }
        countdownTask = nil
        countdown = nil
        return await capturePhoto()
    }

    private func capturePhoto() async -> String? {
        guard device != nil, session.isRunning else { return "The camera isn't available" }

        // Read/write access (not add-only) so the in-app gallery can show and delete these photos.
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            return "Allow Photos access in Settings to save photos"
        }

        // Keep the photo level with the horizon, whichever way the phone is held.
        if let connection = photoOutput.connection(with: .video),
           let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        let settings = makePhotoSettings()
        let id = settings.uniqueID
        isCapturing = true

        return await withCheckedContinuation { continuation in
            // The delegate calls back off the main thread; these hop back to update the UI.
            let onWillCapture: @MainActor () -> Void = { [weak self] in
                self?.shutterCount += 1
            }
            let onFinish: @MainActor (Result<String?, Error>) -> Void = { [weak self] result in
                self?.inProgressCaptures[id] = nil
                self?.isCapturing = false
                switch result {
                case .success(let assetIdentifier):
                    self?.lastSavedAssetIdentifier = assetIdentifier
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(returning: "Couldn't save photo: \(error.localizedDescription)")
                }
            }
            let processor = PhotoCaptureProcessor(
                aspectRatio: aspectRatio,
                style: style,
                encodeAsJPEG: format == .jpeg,
                willCapture: { Task { @MainActor in onWillCapture() } },
                completion: { result in Task { @MainActor in onFinish(result) } }
            )
            inProgressCaptures[id] = processor
            photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: - Helpers

    /// Locks the device, applies `change`, and unlocks. Does nothing without a camera (e.g. the Simulator).
    private func configureDevice(_ change: (AVCaptureDevice) -> Void) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {
            print("Couldn't configure the camera: \(error)")
        }
    }
}

// MARK: - How each control looks in the top bar

extension CameraManager {
    func systemImage(for control: PhotoControl) -> String {
        switch control {
        case .flash: flash.systemImage
        case .live: isLivePhotoActive ? "livephoto" : "livephoto.slash"
        case .nightMode: isNightModeOn ? "moon.fill" : "moon"
        default: control.systemImage
        }
    }

    /// Short text shown inside the icon instead of a symbol, e.g. "16:9".
    func badgeText(for control: PhotoControl) -> String? {
        switch control {
        case .aspect: aspectRatio.title
        case .timer: timer == .off ? nil : timer.title
        case .format: format.title
        default: nil
        }
    }

    /// Whether the control is in a non-default state, which the bar highlights in yellow.
    func isActive(_ control: PhotoControl) -> Bool {
        switch control {
        case .flash: flash == .on
        case .live: isLivePhotoActive
        case .timer: timer != .off
        case .styles: style != .standard
        case .depth: isDepthOn
        case .nightMode: isNightModeOn
        case .centerStage: isCenterStageOn
        case .format: format == .proRAW
        case .histogram: isHistogramOn
        case .exposure, .focus, .shutterSpeed, .whiteBalance, .lensAperture: !isAuto(control)
        case .aspect: false
        }
    }
}
