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
import SwiftUI
import UIKit

@Observable
class CameraManager {
    var session = AVCaptureSession()

    // MARK: - Control state shown in the UI

    private(set) var flash: FlashSetting = .auto
    private(set) var isLivePhotoOn = false
    /// The person has turned Live on or off themselves, so it's no longer switched on for them.
    private var hasChosenLivePhoto = false
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
    /// Goes up by one each time a photo was taken but not saved to the library, so whatever was
    /// waiting to go with it can be dropped.
    private(set) var unsavedCaptureCount = 0

    // MARK: - When the camera can't work

    /// Whether the person allowed camera access. Shown as an explanation when they didn't.
    private(set) var cameraAccess: AVAuthorizationStatus = .notDetermined
    /// A phone call, Siri or another app has the camera for now.
    private(set) var isInterrupted = false
    /// Something went wrong that the person needs to know about, and may be able to fix.
    private(set) var problem: CameraProblem?
    /// True once the session has been set up, so starting again doesn't add inputs twice.
    private var isConfigured = false
    /// Watch for interruptions while the camera runs.
    private var lifecycleTasks: [Task<Void, Never>] = []

    /// True when the coach shouldn't spend effort on frames because the camera is paused.
    var isCoachPaused: Bool {
        isInterrupted
    }

    /// What to tell the person while the coach is paused, or nil when it isn't.
    var pauseNotice: String? {
        if isInterrupted { return "Camera paused while a call or another app is using it." }
        return nil
    }

    func clearProblem() {
        problem = nil
    }
    /// Goes up by one each time the sensor fires, so the view can blink the screen.
    private(set) var shutterCount = 0
    /// True while a Camera Control slider fills the screen, so the app can hide its own controls.
    private(set) var isCameraControlFullscreen = false
    /// Which way up the phone is held. The layout stays in portrait, like the Camera app,
    /// but icons, the advice and the coach follow this.
    private(set) var holdOrientation: HoldOrientation = .portrait

    // MARK: - Capture pipeline

    private(set) var device: AVCaptureDevice?
    private(set) var isUsingFrontCamera = false
    /// True while switching between the front and back cameras, so the viewfinder can blur.
    private(set) var isSwitchingCamera = false
    /// A tap has set where the camera focuses and meters. Cleared when the scene changes a lot.
    private(set) var isFocusPointSet = false
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
    /// Follows the phone's orientation so `holdOrientation` stays current.
    private var orientationTask: Task<Void, Never>?

    // MARK: - Camera Control (the hardware button on iPhone 16 and later)

    private let cameraControlsDelegate = CameraControlsDelegate()
    private var zoomControl: AVCaptureSlider?
    private var exposureControl: AVCaptureSlider?
    private var styleControl: AVCaptureIndexPicker?

    /// True when the back camera has a physically adjustable aperture (iPhone 18 Pro / Pro Max).
    /// Checks the hardware capability instead of the model name, so it also covers future devices.
    static var supportsVariableAperture: Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }
        return camera.formats.contains { $0.minLensAperture < $0.maxLensAperture }
    }

    /// Controls no camera on this iPhone can use, so they're never offered: Aperture before
    /// iPhone 18 Pro, Center Stage without a Center Stage camera, and so on. Like
    /// `supportsVariableAperture`, it asks the hardware rather than checking model names.
    static var unsupportedControls: Set<PhotoControl> {
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        var unsupported: Set<PhotoControl> = []
        if !supportsVariableAperture {
            unsupported.insert(.lensAperture)
        }
        // Portrait is always offered: without depth hardware it blurs the background behind
        // people instead, like the Camera app on single-lens iPhones.
        if !cameras.contains(where: { $0.formats.contains(where: \.isCenterStageSupported) }) {
            unsupported.insert(.centerStage)
        }
        if !cameras.contains(where: \.isLockingFocusWithCustomLensPositionSupported) {
            unsupported.insert(.focus)
        }
        return unsupported
    }

    /// Whether a control works with the camera in use right now. On an iPhone 18 Pro, say, only
    /// the main back lens has an adjustable aperture, so Aperture is hidden on the others.
    func isAvailableOnCurrentCamera(_ control: PhotoControl) -> Bool {
        guard let device else { return true }
        switch control {
        case .lensAperture:
            return manualLens?.formats.contains { $0.minLensAperture < $0.maxLensAperture } ?? false
        case .focus:
            return manualLens?.isLockingFocusWithCustomLensPositionSupported ?? false
        case .centerStage:
            return device.activeFormat.isCenterStageSupported
        case .flash:
            return photoOutput.supportedFlashModes.contains(.on)
        default:
            return true
        }
    }

    /// The lens manual controls act on. The combined back camera can't take them, so
    /// `usePhysicalLensForManualControl` hands over to the lens for the current zoom, chosen as in `setZoom`.
    private var manualLens: AVCaptureDevice? {
        guard let device, device.isVirtualDevice, device.position == .back, !isDepthOn,
              let wide = Self.backCamera(.builtInWideAngleCamera) else { return device }
        if zoomLevel < 1, let ultraWide = Self.backCamera(.builtInUltraWideCamera) {
            return ultraWide
        }
        if let telephoto = Self.backCamera(.builtInTelephotoCamera),
           let teleZoom = Self.magnification(of: telephoto, relativeTo: wide),
           teleZoom > 2, zoomLevel >= teleZoom.rounded() {
            return telephoto
        }
        return wide
    }

    init() {
        // Frames are processed off the main thread; hop back to publish the result.
        let update: @MainActor ([Float]) -> Void = { [weak self] bins in
            self?.histogram = bins
        }
        histogramProcessor.onUpdate = { bins in
            Task { @MainActor in update(bins) }
        }
        cameraControlsDelegate.onFullscreenChange = { [weak self] isFullscreen in
            self?.isCameraControlFullscreen = isFullscreen
        }
    }

    func configure(){
        // The back lenses as one camera, so zooming past 0.5×, 1× and the telephoto is smooth.
        guard let camera = Self.smoothBackCamera() ?? AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back) else{
            problem = CameraProblem(message: "The camera couldn't start. Close the app and open it again.", opensSettings: false)
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
            // Without an input the viewfinder stays black, so say so rather than failing quietly.
            problem = CameraProblem(message: "The camera couldn't start. Close the app and open it again.", opensSettings: false)
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
        trackRotation(of: camera)
        // The system only shows the Camera Control overlay once a delegate is set.
        if session.supportsControls {
            session.setControlsDelegate(cameraControlsDelegate, queue: .main)
        }
        refreshZoomStops()
        // A combined camera starts on its widest lens; 1× is the main lens.
        if camera.isVirtualDevice {
            applyZoomOnCurrentDevice(1, smoothly: false)
        }
    }

    /// Follows how the phone is held with `device`, so photos are saved level.
    private func trackRotation(of device: AVCaptureDevice) {
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        // The other lens may deliver frames the other way round.
        frameGrabber.setFrameOrientation(holdOrientation.frameOrientation(isFrontCamera: device.position == .front))
    }

    /// Keeps `holdOrientation` in step with how the phone is held, for icons, the advice and the coach.
    private func trackHoldOrientation() {
        guard orientationTask == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateHoldOrientation()
        orientationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                self?.updateHoldOrientation()
            }
        }
    }

    private func updateHoldOrientation() {
        // Flat on a table or unknown says nothing about which way is up, so keep the last one.
        guard let orientation = HoldOrientation(UIDevice.current.orientation) else { return }
        frameGrabber.setFrameOrientation(orientation.frameOrientation(isFrontCamera: isUsingFrontCamera))
        guard orientation != holdOrientation else { return }
        withAnimation(.snappy) {
            holdOrientation = orientation
        }
    }

    func start() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        // Denied or restricted: the screen explains it and links to Settings.
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraAccess == .authorized else { return }

        if !isConfigured {
            configure()
            isConfigured = true
        }
        trackHoldOrientation()
        watchLifecycle()
        runSession()
    }

    /// Starts the session if it isn't running, e.g. after coming back to the app.
    func resumeIfNeeded() {
        guard isConfigured, cameraAccess == .authorized else { return }
        runSession()
    }

    private func runSession() {
        // startRunning() blocks, so keep it off the main thread.
        let session = session
        // The photo output finishes setting up once the session runs, and only then
        // reports Live Photos as supported, so check again now.
        let onRunning: @MainActor () -> Void = { [weak self] in
            self?.turnOnLivePhotosIfNowSupported()
        }
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
            Task { @MainActor in onRunning() }
        }
    }

    /// Turns Live Photos on in the pipeline once the camera says it can, since that can only be
    /// known after the session starts. Live is on by default, like the Camera app, until the
    /// person turns it off themselves.
    private func turnOnLivePhotosIfNowSupported() {
        guard enableLivePhotoPipeline(), !hasChosenLivePhoto else { return }
        isLivePhotoOn = true
    }

    /// Enables Live Photo capture if it's off but now supported. Returns whether it's enabled.
    @discardableResult
    private func enableLivePhotoPipeline() -> Bool {
        if photoOutput.isLivePhotoCaptureEnabled { return true }
        guard format != .proRAW, photoOutput.isLivePhotoCaptureSupported else { return false }
        session.beginConfiguration()
        configurePhotoPipeline()
        session.commitConfiguration()
        return photoOutput.isLivePhotoCaptureEnabled
    }

    /// Follows interruptions (calls, Siri, other apps) and camera errors,
    /// so the screen can say what's happening and the coach can rest.
    private func watchLifecycle() {
        guard lifecycleTasks.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleTasks = [
            Task { [weak self] in
                for await _ in center.notifications(named: AVCaptureSession.wasInterruptedNotification) {
                    self?.isInterrupted = true
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                    self?.isInterrupted = false
                }
            },
            Task { [weak self] in
                // After a media-services reset or another error, the session has stopped: start it again.
                for await _ in center.notifications(named: AVCaptureSession.runtimeErrorNotification) {
                    self?.runSession()
                }
            },
            Task { [weak self] in
                // The camera has been pointed somewhere new, so a tapped focus spot no longer fits.
                for await _ in center.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification) {
                    self?.resetFocusPoint()
                }
            },
        ]
    }

    // MARK: - Switching cameras and lenses

    /// Swaps between the back and front cameras. Returns a message if it couldn't switch.
    /// Starting the other camera takes a moment, so it happens on the session queue while the
    /// viewfinder blurs (`isSwitchingCamera`), instead of freezing the screen.
    func switchCamera() async -> String? {
        guard videoInput != nil else { return "The camera isn't available" }
        guard !isSwitchingCamera else { return nil }
        let newPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .back : .front
        let smooth = newPosition == .back ? Self.smoothBackCamera() : nil
        guard let newDevice = smooth ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
            return "That camera isn't available"
        }
        isSwitchingCamera = true
        defer { isSwitchingCamera = false }
        guard await useInBackground(newDevice) else { return "Couldn't switch cameras" }
        isUsingFrontCamera = newPosition == .front
        zoomLevel = 1
        refreshZoomStops()
        if newDevice.isVirtualDevice {
            applyZoomOnCurrentDevice(1, smoothly: false)
        }
        // The new camera's first frames settle exposure and focus; keep them behind the blur.
        try? await Task.sleep(for: .milliseconds(150))
        return nil
    }

    /// Zooms like the Camera app. The combined back camera switches lenses by itself, smoothly.
    /// A single lens (used while a manual control is set) swaps to the ultra wide below 1× and
    /// the telephoto at its native zoom.
    /// `smoothly` glides there, for the zoom buttons; pinches and the Camera Control follow the
    /// finger exactly instead, since each tiny step would otherwise start a new glide and lag behind.
    func setZoom(_ level: CGFloat, smoothly: Bool = false) -> String? {
        guard videoInput != nil, var target = device else { return "The camera isn't available" }
        if target.isVirtualDevice {
            zoomLevel = level
            applyZoomOnCurrentDevice(level, smoothly: smoothly)
            syncZoomControl()
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
            Self.zoom(device, to: factor, smoothly: smoothly)
        }
        syncZoomControl()
        return nil
    }

    /// Zooms a combined camera. When it includes the ultra wide, zoom factor 1 is that lens,
    /// so "1×" (the main lens) sits at the first switch-over point.
    private func applyZoomOnCurrentDevice(_ level: CGFloat, smoothly: Bool = true) {
        configureDevice { device in
            let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            let oneX = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1) : 1
            let factor = min(max(level * oneX, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            Self.zoom(device, to: factor, smoothly: smoothly)
        }
    }

    /// Glides to `factor`, or jumps straight there. Call with the device locked.
    private static func zoom(_ device: AVCaptureDevice, to factor: CGFloat, smoothly: Bool) {
        if smoothly {
            device.ramp(toVideoZoomFactor: factor, withRate: 16)
        } else {
            // Stop any glide still running, or it fights the finger.
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            device.videoZoomFactor = factor
        }
    }

    /// The back lenses as one camera, which switches between them by itself as the zoom changes,
    /// like the Camera app. It can't take manual shutter, ISO, focus or white balance, though.
    private static func smoothBackCamera() -> AVCaptureDevice? {
        backCamera(.builtInTripleCamera) ?? backCamera(.builtInDualWideCamera) ?? backCamera(.builtInDualCamera)
    }

    /// Manual shutter, aperture, focus and white balance only work on a single lens, so move from the
    /// combined camera to whichever lens shows the current zoom. The view stays the same; only
    /// zooming across lenses is less smooth while a manual value is set.
    private func usePhysicalLensForManualControl() {
        guard let current = device, current.isVirtualDevice, current.position == .back, !isDepthOn,
              let wide = Self.backCamera(.builtInWideAngleCamera) else { return }
        let level = zoomLevel
        let bias = exposureBias
        guard use(wide) else { return }
        refreshZoomStops()
        _ = setZoom(level)
        // Swapping lenses resets the exposure bias; keep the person's setting.
        if bias != 0 { setAdjustment(bias, for: .exposure) }
    }

    /// Back to the smooth combined camera once every manual control is on auto again.
    private func returnToSmoothCameraIfAuto() {
        guard let current = device, !current.isVirtualDevice, current.position == .back,
              focusPosition == nil, shutterSeconds == nil, whiteBalanceKelvin == nil, aperture == nil,
              let smooth = Self.smoothBackCamera() else { return }
        let level = zoomLevel
        let bias = exposureBias
        guard use(smooth) else { return }
        refreshZoomStops()
        zoomLevel = level
        applyZoomOnCurrentDevice(level, smoothly: false)
        if bias != 0 { setAdjustment(bias, for: .exposure) }
    }

    /// Works out which zoom buttons this camera can offer.
    private func refreshZoomStops() {
        // The Camera Control's zoom slider spans these stops, so rebuild it to match.
        defer { refreshCameraControls() }
        if let device, device.isVirtualDevice {
            // The combined camera's own lenses decide the buttons.
            let lenses = device.constituentDevices
            var stops: [CGFloat] = []
            if lenses.contains(where: { $0.deviceType == .builtInUltraWideCamera }) { stops.append(0.5) }
            stops += [1, 2]
            if let wide = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }),
               let telephoto = lenses.first(where: { $0.deviceType == .builtInTelephotoCamera }),
               let teleZoom = Self.magnification(of: telephoto, relativeTo: wide), teleZoom > 2 {
                stops.append(teleZoom.rounded())
            }
            zoomStops = stops
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
              let swapped = Self.swapInput(
                  in: session, from: currentInput, to: newDevice, photoOutput: photoOutput,
                  wantsProRAW: format == .proRAW, wantsDepth: isDepthOn
              ) else { return false }
        finishUsing(newDevice, swapped)
        return true
    }

    /// Same as `use`, but the slow session work runs on the session queue so the screen stays smooth.
    private func useInBackground(_ newDevice: AVCaptureDevice) async -> Bool {
        guard let currentInput = videoInput else { return false }
        let session = session
        let photoOutput = photoOutput
        let wantsProRAW = format == .proRAW
        let wantsDepth = isDepthOn
        let swapped = await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: Self.swapInput(
                    in: session, from: currentInput, to: newDevice, photoOutput: photoOutput,
                    wantsProRAW: wantsProRAW, wantsDepth: wantsDepth
                ))
            }
        }
        guard let swapped else { return false }
        finishUsing(newDevice, swapped)
        return true
    }

    /// What a swap kept: the new input, and whether RAW and depth still work on the new camera.
    private struct SwappedInput {
        let input: AVCaptureDeviceInput
        let keepsProRAW: Bool
        let keepsDepth: Bool
    }

    /// The part of a camera swap that talks to the session. Touches no state of its own, so it
    /// can run on the session queue. Returns nil, with the old camera kept, if it can't swap.
    private nonisolated static func swapInput(
        in session: AVCaptureSession,
        from currentInput: AVCaptureDeviceInput,
        to newDevice: AVCaptureDevice,
        photoOutput: AVCapturePhotoOutput,
        wantsProRAW: Bool,
        wantsDepth: Bool
    ) -> SwappedInput? {
        guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.removeInput(currentInput)
        guard session.canAddInput(newInput) else {
            session.addInput(currentInput)
            return nil
        }
        session.addInput(newInput)
        // Photo features depend on the camera, so re-check what this one supports.
        let keepsProRAW = wantsProRAW && photoOutput.isAppleProRAWSupported
        configurePhotoPipeline(photoOutput, proRAW: keepsProRAW)
        let keepsDepth = wantsDepth && photoOutput.isDepthDataDeliverySupported
        photoOutput.isDepthDataDeliveryEnabled = keepsDepth
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = keepsDepth && photoOutput.isPortraitEffectsMatteDeliverySupported
        return SwappedInput(input: newInput, keepsProRAW: keepsProRAW, keepsDepth: keepsDepth)
    }

    /// Updates the camera's state once the session has the new input.
    private func finishUsing(_ newDevice: AVCaptureDevice, _ swapped: SwappedInput) {
        videoInput = swapped.input
        device = newDevice
        // A tapped focus spot belonged to the old lens; the new one starts on auto.
        isFocusPointSet = false
        if format == .proRAW && !swapped.keepsProRAW {
            format = .heif
        }
        // Portrait stays on: a camera without depth blurs the background behind people instead.
        isCenterStageOn = newDevice.activeFormat.isCenterStageSupported && AVCaptureDevice.isCenterStageEnabled
        // Manual values belonged to the old lens, so hand them back to auto.
        exposureBias = 0
        focusPosition = nil
        shutterSeconds = nil
        whiteBalanceKelvin = nil
        aperture = nil
        syncExposureControl()
        _ = setNightMode(isNightModeOn)
        trackRotation(of: newDevice)
    }

    /// Turns on the photo output features for the current format. iOS can't shoot Apple
    /// ProRAW and Live Photos together, so ProRAW is only enabled while RAW is chosen.
    /// Call inside begin/commitConfiguration.
    private func configurePhotoPipeline() {
        Self.configurePhotoPipeline(photoOutput, proRAW: format == .proRAW)
    }

    private nonisolated static func configurePhotoPipeline(_ photoOutput: AVCapturePhotoOutput, proRAW: Bool) {
        photoOutput.isAppleProRAWEnabled = proRAW && photoOutput.isAppleProRAWSupported
        photoOutput.isLivePhotoCaptureEnabled = !photoOutput.isAppleProRAWEnabled && photoOutput.isLivePhotoCaptureSupported
    }

    /// Live Photos are recorded only when the person wants them and the pipeline allows it.
    /// Portrait photos are re-made with the blur, which can't keep the movie, so Live is off then.
    var isLivePhotoActive: Bool {
        isLivePhotoOn && photoOutput.isLivePhotoCaptureEnabled && !isDepthOn
    }

    // MARK: - Tap controls

    /// Handles a tap on a toggle or multi-option control and returns a short status message.
    func activate(_ control: PhotoControl) -> String {
        switch control {
        case .flash:
            // The button is hidden on such cameras; this covers a tap as the lens changes.
            guard photoOutput.supportedFlashModes.contains(.on) else { return "Flash isn't available on this camera" }
            flash = flash.next
            return "Flash \(flash.title)"
        case .live:
            if format == .proRAW { return "Live Photos are off while shooting RAW" }
            if isDepthOn { return "Live Photos are off while Portrait is on" }
            guard enableLivePhotoPipeline() else { return "Live Photos aren't available on this camera" }
            hasChosenLivePhoto = true
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
            styleControl?.selectedIndex = PhotoStyle.allCases.firstIndex(of: style) ?? 0
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
        // A single lens can't measure depth, so switch to the two-lens back camera when there is one.
        if on && !isUsingFrontCamera && !photoOutput.isDepthDataDeliverySupported,
           let depthCamera = Self.backCamera(.builtInDualWideCamera) ?? Self.backCamera(.builtInDualCamera),
           use(depthCamera) {
            zoomLevel = 1
            refreshZoomStops()
            applyZoomOnCurrentDevice(1)
        } else if !on && device?.isVirtualDevice == true && device?.deviceType != Self.smoothBackCamera()?.deviceType {
            // Off a depth-only camera and back to the smooth combined one.
            if let smooth = Self.smoothBackCamera() ?? Self.backCamera(.builtInWideAngleCamera), use(smooth) {
                zoomLevel = 1
                refreshZoomStops()
                if smooth.isVirtualDevice { applyZoomOnCurrentDevice(1, smoothly: false) }
            }
            isDepthOn = false
            return "Portrait Off"
        }
        if photoOutput.isDepthDataDeliverySupported {
            session.beginConfiguration()
            photoOutput.isDepthDataDeliveryEnabled = on
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = on && photoOutput.isPortraitEffectsMatteDeliverySupported
            session.commitConfiguration()
        }
        isDepthOn = on
        guard on else { return "Portrait Off" }
        // Without depth, only people can be told apart from the background, as in the Camera app.
        return photoOutput.isDepthDataDeliveryEnabled
            ? "Portrait On: the background blurs when you take the photo"
            : "Portrait On: the background behind people blurs when you take the photo"
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
            // The lens the aperture will be set on, which may not be switched to until the slider moves.
            if let format = manualLens?.activeFormat, format.minLensAperture < format.maxLensAperture {
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
            value = aperture ?? manualLens?.lensAperture ?? sliderRange(for: control).lowerBound
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
            syncExposureControl()
            configureDevice { device in
                device.setExposureTargetBias(min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias))
            }
        case .focus:
            usePhysicalLensForManualControl()
            focusPosition = value
            configureDevice { device in
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: value)
                }
            }
        case .shutterSpeed:
            // Shutter priority: lock the duration and keep the current ISO.
            usePhysicalLensForManualControl()
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
            usePhysicalLensForManualControl()
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
            usePhysicalLensForManualControl()
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
        returnToSmoothCameraIfAuto()
    }

    // MARK: - Tap to focus

    /// Focuses and sets the brightness on one spot, like a tap in the Camera app. `point` is in the
    /// sensor's coordinates (see `FrameMapping.sensorPoint`). Manual focus or shutter settings win,
    /// so a tap never undoes them. Both return to automatic once the scene changes a lot.
    func focusAndExpose(at point: CGPoint) {
        let keepsManualFocus = focusPosition != nil
        let keepsManualExposure = shutterSeconds != nil || aperture != nil
        configureDevice { device in
            if !keepsManualFocus, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                // Focus once on the spot and hold it there.
                device.focusMode = .autoFocus
            }
            if !keepsManualExposure, device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
        isFocusPointSet = true
    }

    /// Back to focusing and metering the whole frame, after the scene changed or the lens switched.
    private func resetFocusPoint() {
        guard isFocusPointSet else { return }
        isFocusPointSet = false
        let keepsManualFocus = focusPosition != nil
        let keepsManualExposure = shutterSeconds != nil || aperture != nil
        configureDevice { device in
            let centre = CGPoint(x: 0.5, y: 0.5)
            if !keepsManualFocus, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = centre
                device.focusMode = .continuousAutoFocus
            }
            if !keepsManualExposure, device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = centre
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
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
        // Portrait blurs the background from the depth (and the person matte) kept in the file.
        if settings.isDepthDataDeliveryEnabled {
            settings.isDepthDataFiltered = true
            settings.embedsDepthDataInPhoto = true
            settings.embedsPortraitEffectsMatteInPhoto = settings.isPortraitEffectsMatteDeliveryEnabled
        }
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
        guard device != nil, session.isRunning else {
            problem = CameraProblem(message: "The camera isn't available right now", opensSettings: false)
            return nil
        }

        // Read/write access (not add-only) so the in-app gallery can show and delete these photos.
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            problem = CameraProblem(message: "Allow Photos access in Settings to save photos", opensSettings: true)
            return nil
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
                    if let assetIdentifier {
                        self?.lastSavedAssetIdentifier = assetIdentifier
                    } else {
                        self?.unsavedCaptureCount += 1
                    }
                    continuation.resume(returning: nil)
                case .failure(let error):
                    self?.unsavedCaptureCount += 1
                    self?.problem = CameraProblem(message: "Couldn't save the photo: \(error.localizedDescription)", opensSettings: false)
                    continuation.resume(returning: nil)
                }
            }
            let processor = PhotoCaptureProcessor(
                aspectRatio: aspectRatio,
                style: style,
                encodeAsJPEG: format == .jpeg,
                portrait: isDepthOn,
                willCapture: { Task { @MainActor in onWillCapture() } },
                completion: { result in Task { @MainActor in onFinish(result) } }
            )
            inProgressCaptures[id] = processor
            photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: - Camera Control

    /// Adds Zoom, Exposure and Styles to the Camera Control's light-press overlay, like the
    /// Camera app. Each control drives the same code as the on-screen controls, so both stay in sync.
    private func refreshCameraControls() {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        for control in session.controls {
            session.removeControl(control)
        }

        // Spans the same range as pinch-to-zoom, with the lens buttons as detents.
        let zoomRange = cameraControlZoomRange
        let zoom = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", in: zoomRange)
        zoom.prominentValues = zoomStops.map { Float($0) }
        zoom.localizedValueFormat = "%@×"
        zoom.value = min(max(Float(zoomLevel), zoomRange.lowerBound), zoomRange.upperBound)
        zoom.setActionQueue(.main) { [weak self] value in
            MainActor.assumeIsolated {
                _ = self?.setZoom(CGFloat(value))
            }
        }

        let exposureRange = sliderRange(for: .exposure)
        let exposure = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: exposureRange, step: 0.1)
        exposure.prominentValues = [0]
        exposure.value = min(max(exposureBias, exposureRange.lowerBound), exposureRange.upperBound)
        exposure.setActionQueue(.main) { [weak self] value in
            MainActor.assumeIsolated {
                self?.setAdjustment(value, for: .exposure)
            }
        }

        let styles = AVCaptureIndexPicker("Styles", symbolName: "camera.filters",
                                          localizedIndexTitles: PhotoStyle.allCases.map(\.title))
        styles.selectedIndex = PhotoStyle.allCases.firstIndex(of: style) ?? 0
        styles.setActionQueue(.main) { [weak self] index in
            MainActor.assumeIsolated {
                self?.style = PhotoStyle.allCases[index]
            }
        }

        for control in [zoom, exposure, styles] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
        session.commitConfiguration()
        zoomControl = zoom
        exposureControl = exposure
        styleControl = styles
    }

    /// Moves the Camera Control's zoom slider when zoom changes from the screen.
    private func syncZoomControl() {
        guard let zoomControl else { return }
        let range = cameraControlZoomRange
        let value = min(max(Float(zoomLevel), range.lowerBound), range.upperBound)
        if zoomControl.value != value {
            zoomControl.value = value
        }
    }

    /// Moves the Camera Control's exposure slider when exposure changes from the screen.
    private func syncExposureControl() {
        guard let exposureControl else { return }
        let range = sliderRange(for: .exposure)
        let value = min(max(exposureBias, range.lowerBound), range.upperBound)
        if exposureControl.value != value {
            exposureControl.value = value
        }
    }

    /// Same limits as pinch-to-zoom.
    private var cameraControlZoomRange: ClosedRange<Float> {
        Float(zoomStops.first ?? 1)...Float(max(10, zoomStops.last ?? 1))
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
            // The device stays as it was; the control just doesn't change.
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

/// Tells the camera when the Camera Control's overlay appears and goes fullscreen.
/// Callbacks arrive on the main queue (set in `configure()`).
nonisolated private final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    @MainActor var onFullscreenChange: (Bool) -> Void = { _ in }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        MainActor.assumeIsolated { onFullscreenChange(true) }
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        MainActor.assumeIsolated { onFullscreenChange(false) }
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        MainActor.assumeIsolated { onFullscreenChange(false) }
    }
}

/// How the phone is held, as the Camera app sees it. Upside down counts as portrait.
nonisolated enum HoldOrientation: Equatable, Sendable {
    /// Upright.
    case portrait
    /// Turned anticlockwise, so the top of the phone is on the left.
    case landscapeLeft
    /// Turned clockwise, so the top of the phone is on the right.
    case landscapeRight

    /// Reads the phone's own orientation. Nil when it's flat or unknown. Upside down counts as portrait.
    init?(_ deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait, .portraitUpsideDown: self = .portrait
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }

    var isLandscape: Bool {
        self != .portrait
    }

    /// How far to turn icons and text so they read upright for the person holding the phone.
    var uiRotation: Angle {
        switch self {
        case .portrait: .zero
        // The top of the phone is on the left, so turn clockwise to stand the text up.
        case .landscapeLeft: .degrees(90)
        case .landscapeRight: .degrees(-90)
        }
    }

    /// How to turn a camera frame so the scene is upright. The back camera's frames arrive upright
    /// when the top of the phone is on the left; the front camera's when it's on the right.
    /// The front camera's preview is mirrored, like a mirror, so its frames are mirrored too:
    /// then everything the coach finds and draws is on the side the person sees it.
    func frameOrientation(isFrontCamera: Bool) -> CGImagePropertyOrientation {
        switch self {
        case .portrait: isFrontCamera ? .leftMirrored : .right
        case .landscapeLeft: isFrontCamera ? .downMirrored : .up
        case .landscapeRight: isFrontCamera ? .upMirrored : .down
        }
    }
}

/// Something the person needs to know went wrong, like Photos access being off.
struct CameraProblem: Equatable {
    let message: String
    /// True when the fix is in Settings, so the message offers a button to go there.
    let opensSettings: Bool
}
