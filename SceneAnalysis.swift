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
    // The app's own settings, so the coach can tell a tip was followed even when the change
    // only shows up in the saved photo (Flash) or can't fully fix the frame (a lamp stays white).
    /// The Exposure slider, in EV stops.
    var exposureBias: Double = 0
    var isNightModeOn = false
    var isFlashOn = false

    @MainActor
    static func read(from camera: CameraManager) -> CameraReadings {
        guard let device = camera.device else { return CameraReadings() }
        return CameraReadings(
            exposureOffset: Double(device.exposureTargetOffset),
            exposureSeconds: device.exposureDuration.seconds,
            iso: Double(device.iso),
            exposureBias: Double(camera.exposureBias),
            isNightModeOn: camera.isNightModeOn,
            isFlashOn: camera.flash == .on
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

    /// Degrees the phone is turned from upright portrait, clockwise positive. Nil when it points
    /// almost straight up or down. Used to draw the level, which also works held sideways.
    var roll: Double? {
        smoothedGravity.flatMap { abs($0.z) < 0.8 ? atan2($0.x, -$0.y) * 180 / .pi : nil }
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

/// What kind of photo the camera is looking at. Good advice depends on it: food wants a high
/// angle and window light, a landscape wants a level horizon on a third, and so on.
nonisolated enum SceneType: String, CaseIterable, Sendable {
    case people, food, landscape, city, nature, object

    var title: String {
        switch self {
        case .people: "People"
        case .food: "Food"
        case .landscape: "Landscape"
        case .city: "City"
        case .nature: "Nature"
        case .object: "Object"
        }
    }

    /// One line of photography theory for the model, so it judges the photo like this kind of shot.
    var coachingHint: String {
        switch self {
        case .people: "People look best shot at eye level, with the eyes sharp and a little space above the head."
        case .food: "Food looks best from 45 degrees or straight above, in soft side light, with a clean plate edge."
        case .landscape: "Landscapes need a level horizon on a third line, and some foreground to give depth."
        case .city: "City shots need straight vertical lines, with streets and edges used as leading lines."
        case .nature: "Nature shots work best close to the subject with a simple background."
        case .object: "An object stands out against a clean background, filling the frame."
        }
    }

    /// Words in Vision's classification labels that point to each kind of scene.
    private static let keywords: [SceneType: Set<String>] = [
        .people: ["people", "person", "adult", "child", "portrait", "crowd", "baby"],
        .food: ["food", "dessert", "fruit", "vegetable", "drink", "meal", "baked", "bread", "cake", "pizza",
                "sushi", "salad", "coffee", "beverage", "breakfast", "sandwich", "pasta", "plate", "dish"],
        .landscape: ["landscape", "mountain", "beach", "shore", "sky", "sunset", "sunrise", "desert", "lake",
                     "ocean", "sea", "hill", "valley", "field", "horizon", "waterfall", "cloud", "snow"],
        .city: ["cityscape", "city", "building", "skyscraper", "street", "structure", "bridge", "road",
                "vehicle", "car", "architecture", "tower", "house", "downtown", "urban"],
        .nature: ["plant", "flower", "tree", "foliage", "forest", "animal", "bird", "insect", "leaf",
                  "garden", "grass", "mammal", "cat", "dog", "butterfly"],
    ]

    /// Below this total confidence the scene isn't clear, so it counts as a plain object.
    static let minimumScore: Float = 0.3

    /// Picks the scene from Vision's labels (identifier and confidence). A visible face always means people.
    static func classify(labels: [(identifier: String, confidence: Float)], faces: [CGRect]) -> SceneType {
        if faces.contains(where: { $0.width * $0.height > 0.02 }) { return .people }
        var scores: [SceneType: Float] = [:]
        for label in labels {
            let words = Set(label.identifier.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init))
            for (type, keys) in keywords where !words.isDisjoint(with: keys) {
                scores[type, default: 0] += label.confidence
            }
        }
        // Ties go to the earlier case, so the result is stable.
        var best = SceneType.object
        var bestScore: Float = 0
        for type in allCases {
            let score = scores[type] ?? 0
            if score > bestScore {
                best = type
                bestScore = score
            }
        }
        return bestScore >= minimumScore ? best : .object
    }

    /// The most common scene in recent frames, with ties going to the newest, so the label doesn't flip.
    static func smoothed(_ recent: [SceneType]) -> SceneType? {
        guard let newest = recent.last else { return nil }
        let counts = Dictionary(recent.map { ($0, 1) }, uniquingKeysWith: +)
        let top = counts.values.max() ?? 0
        if counts[newest] == top { return newest }
        return recent.reversed().first { counts[$0] == top }
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
    /// What kind of photo this looks like.
    var scene: SceneType = .object

    /// The subject is clearly darker than what's behind it.
    var isBacklit: Bool {
        guard let subjectBrightness, let backgroundBrightness else { return false }
        return backgroundBrightness - subjectBrightness > 0.25
    }

    /// Short facts for the model and the debug overlay.
    var summary: String {
        var facts: [String] = []
        if scene != .object { facts.append("this looks like a \(scene.title.lowercased()) photo") }
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
            "subject \(subjectText)  faces \(faces.count)  scene \(scene.rawValue)",
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
        let scene = SceneType.classify(labels: classify(image), faces: faces)

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
            shake: shake,
            scene: scene
        )
    }

    /// Vision's on-device labels for the frame, keeping only ones it is reasonably sure of.
    private nonisolated static func classify(_ image: CGImage) -> [(identifier: String, confidence: Float)] {
        let request = VNClassifyImageRequest()
        request.runOnCPUInSimulator()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.3 }
            .map { ($0.identifier, $0.confidence) }
    }

    private nonisolated static func detectFaces(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        request.runOnCPUInSimulator()
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
