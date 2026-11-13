//
//  SceneAnalysis.swift
//  Grp 6pm Photo App
//
//  Plain measurements of what the camera sees, so the coach doesn't have to guess
//  brightness, sharpness or tilt from a small image.
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreMotion
import Vision

/// Camera settings read at the moment a frame is analysed.
nonisolated struct CameraReadings: Sendable, Equatable {
    /// The camera's own exposure meter, in EV stops. Negative means darker than the camera
    /// thinks it should be. Stays near 0 while exposure is automatic.
    var exposureOffset: Double?
    /// Shutter speed in seconds.
    var exposureSeconds: Double?
    var iso: Double?

    @MainActor
    static func read(from camera: CameraManager) -> CameraReadings {
        guard let device = camera.device else { return CameraReadings() }
        return CameraReadings(
            exposureOffset: Double(device.exposureTargetOffset),
            exposureSeconds: device.exposureDuration.seconds,
            iso: Double(device.iso)
        )
    }
}

/// Reads how the phone is held, like the level in the Camera app. Gravity is smoothed so
/// normal hand jitter doesn't make the advice flicker.
nonisolated final class PhoneAttitude: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var gravity: CMAcceleration?
    private var recentRotation: [Double] = []
    private var users = 0

    /// How far each new sample moves the smoothed gravity, 0...1. Lower is steadier but slower.
    private static let smoothing = 0.15
    /// Samples the shake reading averages: about half a second at 30 updates a second.
    private static let shakeWindow = 15

    init() {
        queue.maxConcurrentOperationCount = 1
    }

    /// Starts updates. Each call must be balanced by `stop()`. Updates only stop with the last
    /// user, so a coach task that is restarting can't switch motion off for the one replacing it.
    func start() {
        lock.lock()
        users += 1
        let isFirst = users == 1
        lock.unlock()
        guard isFirst, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.add(motion)
        }
    }

    func stop() {
        lock.lock()
        users = max(0, users - 1)
        let isLast = users == 0
        if isLast {
            gravity = nil
            recentRotation = []
        }
        lock.unlock()
        if isLast { manager.stopDeviceMotionUpdates() }
    }

    private func add(_ motion: CMDeviceMotion) {
        let rate = motion.rotationRate
        let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
        let new = motion.gravity
        lock.lock()
        defer { lock.unlock() }
        if let old = gravity {
            let a = Self.smoothing
            gravity = CMAcceleration(
                x: old.x + (new.x - old.x) * a,
                y: old.y + (new.y - old.y) * a,
                z: old.z + (new.z - old.z) * a
            )
        } else {
            gravity = new
        }
        recentRotation.append(speed)
        if recentRotation.count > Self.shakeWindow { recentRotation.removeFirst() }
    }

    private var smoothedGravity: CMAcceleration? {
        lock.lock()
        defer { lock.unlock() }
        return gravity
    }

    /// Degrees the back camera points above (+) or below (-) the horizon.
    var pitch: Double? {
        smoothedGravity.map { Self.pitch(gravityZ: $0.z) }
    }

    /// Degrees the phone is rotated away from level, in portrait or landscape.
    var tilt: Double? {
        smoothedGravity.flatMap { Self.tilt(x: $0.x, y: $0.y, z: $0.z) }
    }

    /// How much the phone has been turning over the last half second, in radians a second.
    /// Near 0 when held still; above `CoachRules.shakeThreshold` the photo is likely to blur.
    var shake: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !recentRotation.isEmpty else { return nil }
        return recentRotation.reduce(0, +) / Double(recentRotation.count)
    }

    static func pitch(gravityZ z: Double) -> Double {
        // The back camera looks along the phone's -z axis, so its elevation is asin(gravity.z).
        asin(min(max(z, -1), 1)) * 180 / .pi
    }

    static func tilt(x: Double, y: Double, z: Double) -> Double? {
        // A phone pointing almost straight up or down has no meaningful level.
        guard abs(z) < 0.8 else { return nil }
        // Positive when the phone is turned clockwise.
        let roll = atan2(x, -y) * 180 / .pi
        // Measure from the nearest of portrait or landscape.
        return roll - (roll / 90).rounded() * 90
    }
}

/// Measured facts about one frame. Everything is in 0...1 unless noted.
nonisolated struct SceneAnalysis: Sendable, Equatable {
    /// Average brightness of the whole frame.
    var brightness: Double
    /// Share of the frame that is pure white (detail lost in the highlights).
    var highlightClip: Double
    /// Share of the frame that is pure black (detail lost in the shadows).
    var shadowClip: Double
    /// The most eye-catching thing in the frame, from the top left.
    var subject: CGRect?
    var subjectBrightness: Double?
    var backgroundBrightness: Double?
    /// Fine detail inside the subject (or the centre when there is no subject). Low means soft.
    var subjectSharpness: Double
    /// Faces in the frame, from the top left.
    var faces: [CGRect]
    var readings: CameraReadings
    /// See `PhoneAttitude`. Nil when there is no motion data, e.g. on a still photo.
    var pitch: Double?
    var tilt: Double?
    /// See `PhoneAttitude.shake`. Nil without motion data.
    var shake: Double? = nil

    /// The subject is clearly darker than what's behind it.
    var isBacklit: Bool {
        guard let subjectBrightness, let backgroundBrightness else { return false }
        return backgroundBrightness - subjectBrightness > 0.25
    }

    /// Short facts for the model and the debug overlay.
    var summary: String {
        var facts: [String] = []
        facts.append("overall brightness \(Self.percent(brightness))")
        if highlightClip > 0.02 { facts.append("\(Self.percent(highlightClip)) of the frame is blown out to white") }
        if shadowClip > 0.05 { facts.append("\(Self.percent(shadowClip)) is pure black") }
        if isBacklit { facts.append("the subject is darker than the background (backlit)") }
        facts.append(subjectSharpness < CoachRules.softThreshold ? "the subject looks soft" : "the subject is sharp")
        if !faces.isEmpty { facts.append("\(faces.count) face\(faces.count == 1 ? "" : "s")") }
        if let tilt, abs(tilt) >= CoachRules.tiltThreshold { facts.append("the phone is tilted \(Int(abs(tilt).rounded()))°") }
        if let shake, shake >= CoachRules.shakeThreshold { facts.append("the phone is moving") }
        return facts.joined(separator: "; ")
    }

    /// Numbers for the debug overlay.
    var debugDescription: String {
        let subjectText = subject.map { String(format: "%.2f,%.2f %.2fx%.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none"
        return [
            String(format: "bright %.2f  clipHi %.3f  clipLo %.3f", brightness, highlightClip, shadowClip),
            String(format: "subj %.2f  bg %.2f  sharp %.0f", subjectBrightness ?? -1, backgroundBrightness ?? -1, subjectSharpness),
            "subject \(subjectText)  faces \(faces.count)",
            String(format: "EV %.2f  1/%.0fs  ISO %.0f", readings.exposureOffset ?? 0, 1 / (readings.exposureSeconds ?? 1), readings.iso ?? 0),
            String(format: "pitch %.0f°  tilt %.1f°  shake %.2f", pitch ?? 0, tilt ?? 0, shake ?? 0),
        ].joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension SceneAnalysis {
    /// Measures an upright frame. Runs off the main thread because Vision and the pixel loops take a moment.
    @concurrent
    nonisolated static func analyze(
        _ image: CGImage,
        readings: CameraReadings = CameraReadings(),
        pitch: Double? = nil,
        tilt: Double? = nil,
        shake: Double? = nil
    ) async -> SceneAnalysis? {
        guard let gray = GrayImage(image) else { return nil }
        let subject = SubjectFinder.subject(in: image)
        let faces = detectFaces(in: image)

        // Without a subject, judge sharpness and brightness in the middle of the frame.
        let region = subject ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let inside = gray.mean(in: region)
        let outside = subject == nil ? nil : gray.mean(outside: region)

        return SceneAnalysis(
            brightness: gray.mean(in: CGRect(x: 0, y: 0, width: 1, height: 1)),
            highlightClip: gray.share { $0 >= 248 },
            shadowClip: gray.share { $0 <= 6 },
            subject: subject,
            subjectBrightness: subject == nil ? nil : inside,
            backgroundBrightness: outside,
            subjectSharpness: gray.sharpness(in: region),
            faces: faces,
            readings: readings,
            pitch: pitch,
            tilt: tilt,
            shake: shake
        )
    }

    private nonisolated static func detectFaces(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        // Vision measures from the bottom left, the screen from the top left.
        return (request.results ?? []).map {
            CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height)
        }
    }
}

/// A small grayscale copy of a frame for quick pixel measurements.
private nonisolated struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, width: Int = 256) {
        let height = max(1, Int(Double(width) * Double(image.height) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, height > 2 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Pixel bounds of a 0...1 top-left rect, kept at least 3 pixels wide so sharpness can be measured.
    private func bounds(of rect: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        let minX = min(max(Int(rect.minX * Double(width)), 0), width - 3)
        let minY = min(max(Int(rect.minY * Double(height)), 0), height - 3)
        let maxX = max(min(Int(rect.maxX * Double(width)), width), minX + 3)
        let maxY = max(min(Int(rect.maxY * Double(height)), height), minY + 3)
        return (minX..<maxX, minY..<maxY)
    }

    func mean(in rect: CGRect) -> Double {
        let (xs, ys) = bounds(of: rect)
        var sum = 0.0
        for y in ys { for x in xs { sum += Double(pixels[y * width + x]) } }
        return sum / Double(xs.count * ys.count) / 255
    }

    func mean(outside rect: CGRect) -> Double? {
        let (xs, ys) = bounds(of: rect)
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<width where !(xs.contains(x) && ys.contains(y)) {
                sum += Double(pixels[y * width + x])
                count += 1
            }
        }
        return count == 0 ? nil : sum / Double(count) / 255
    }

    func share(where isIncluded: (UInt8) -> Bool) -> Double {
        Double(pixels.lazy.filter(isIncluded).count) / Double(pixels.count)
    }

    /// Variance of the Laplacian, a standard sharpness measure, inside `rect`.
    func sharpness(in rect: CGRect) -> Double {
        let (xs, ys) = bounds(of: rect)
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0
        for y in max(ys.lowerBound, 1)..<min(ys.upperBound, height - 1) {
            for x in max(xs.lowerBound, 1)..<min(xs.upperBound, width - 1) {
                let center = Double(pixels[y * width + x])
                let laplacian = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                    + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
                sum += laplacian
                sumOfSquares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let average = sum / count
        return sumOfSquares / count - average * average
    }
}
