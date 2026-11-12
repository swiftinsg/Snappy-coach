//
//  CameraManager.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import Foundation
@preconcurrency import AVFoundation
import Observation

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

    // MARK: - Capture pipeline

    private(set) var device: AVCaptureDevice?
    let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let histogramProcessor = HistogramProcessor()
    private let sessionQueue = DispatchQueue(label: "CameraManager.session")
    private let videoQueue = DispatchQueue(label: "CameraManager.video")

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
            }
        } catch {
            print("Something went wrong: \(error)")
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Pipeline-level features must be enabled before the session starts running.
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        }
        // Frames from this output feed the histogram.
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        isLivePhotoOn = photoOutput.isLivePhotoCaptureEnabled
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

    // MARK: - Tap controls

    /// Handles a tap on a toggle or multi-option control and returns a short status message.
    func activate(_ control: PhotoControl) -> String {
        switch control {
        case .flash:
            flash = flash.next
            return "Flash \(flash.title)"
        case .live:
            guard photoOutput.isLivePhotoCaptureEnabled else { return "Live Photos aren't available" }
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
            format = format.next
            // Skip ProRAW on cameras that can't shoot it.
            if format == .proRAW && !photoOutput.isAppleProRAWEnabled {
                format = format.next
            }
            return "Format: \(format.title)"
        case .histogram:
            return setHistogram(!isHistogramOn)
        case .exposure, .focus, .shutterSpeed, .whiteBalance, .lensAperture:
            // Slider controls are adjusted through setAdjustment(_:for:).
            return control.title
        }
    }

    private func setDepth(_ on: Bool) -> String {
        guard photoOutput.isDepthDataDeliverySupported else { return "Depth isn't available on this camera" }
        session.beginConfiguration()
        photoOutput.isDepthDataDeliveryEnabled = on
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = on && photoOutput.isPortraitEffectsMatteDeliverySupported
        session.commitConfiguration()
        isDepthOn = on
        return on ? "Depth On" : "Depth Off"
    }

    /// Night mode lets the camera boost low light and use multi-frame fusion at capture.
    private func setNightMode(_ on: Bool) -> String {
        isNightModeOn = on
        configureDevice { device in
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = on
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
        if isLivePhotoOn && photoOutput.isLivePhotoCaptureEnabled && format != .proRAW {
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
        case .live: isLivePhotoOn ? "livephoto" : "livephoto.slash"
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
        case .live: isLivePhotoOn
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
