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
    // So the advice can say how much to move: "Zoom to 2×", "Turn about 10° left".
    /// The zoom, like the zoom buttons: 1 is the main lens.
    var zoom: Double = 1
    /// The zoom buttons this camera offers.
    var zoomStops: [Double] = [1, 2]
    /// How many degrees the view spans across the sensor's long side, at the current zoom.
    var fieldOfView: Double? = nil

    @MainActor
    static func read(from camera: CameraManager) -> CameraReadings {
        guard let device = camera.device else { return CameraReadings() }
        return CameraReadings(
            exposureOffset: Double(device.exposureTargetOffset),
            exposureSeconds: device.exposureDuration.seconds,
            iso: Double(device.iso),
            exposureBias: Double(camera.exposureBias),
            isNightModeOn: camera.isNightModeOn,
            isFlashOn: camera.flash == .on,
            zoom: Double(camera.zoomLevel),
            zoomStops: camera.zoomStops.map(Double.init),
            fieldOfView: Self.fieldOfView(of: device)
        )
    }

    /// The lens's field of view narrowed by its zoom. Nil when the camera doesn't report one.
    @MainActor
    private static func fieldOfView(of device: AVCaptureDevice) -> Double? {
        let widest = Double(device.activeFormat.videoFieldOfView)
        guard widest > 0 else { return nil }
        let halfAngle = widest / 2 * .pi / 180
        return 2 * atan(tan(halfAngle) / Double(device.videoZoomFactor)) * 180 / .pi
    }

    /// The view's span in degrees across and down, as the phone is held. Sensors are 4:3,
    /// so the short side spans a little less than the long one.
    func viewSpan(isLandscape: Bool) -> FieldOfView? {
        guard let fieldOfView else { return nil }
        let long = fieldOfView
        let short = 2 * atan(tan(long / 2 * .pi / 180) * 3 / 4) * 180 / .pi
        return isLandscape ? FieldOfView(horizontal: long, vertical: short) : FieldOfView(horizontal: short, vertical: long)
    }
}

/// How many degrees the view spans across and down, for turning a shift in the frame into a turn of the phone.
nonisolated struct FieldOfView: Equatable, Sendable {
    var horizontal: Double
    var vertical: Double

    /// Degrees to turn the phone for a shift of `share` of the frame, rounded to 5°, at least 5°.
    static func degrees(_ share: Double, across span: Double) -> Int {
        max(5, Int((abs(share) * span / 5).rounded()) * 5)
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
        // Not "structure", "vehicle" or "car": Vision gives those to desks, rooms and toy cars too,
        // which then got city advice, like a horizon tip for a computer.
        .city: ["cityscape", "city", "building", "skyscraper", "street", "bridge", "road",
                "architecture", "tower", "house", "downtown", "urban"],
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
    /// The subject, from the top left: the whole group when there are people,
    /// otherwise the most eye-catching thing.
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
    /// Everyone found in the frame by their whole body, so people facing away count too.
    var people: [CGRect] = []
    /// Brightness of an 8×8 grid over the frame, row by row. Compared between checks to tell
    /// whether the camera has been reframed.
    var layout: [Double] = []
    /// What's behind the people in a people photo, like a landscape or a city, so both kinds
    /// of advice apply. Nil when there's no person or the backdrop isn't clear.
    var backdrop: SceneType? = nil
    /// How busy the background right around the subject is: the share of it on a clear edge, 0...1.
    /// Nil without a subject. Walls, doors and glass score low; clutter scores high.
    var backgroundBusyness: Double? = nil
    /// How much the brightness varies inside the subject, 0...0.5. Low for plain, smooth things.
    var subjectContrast: Double? = nil
    /// Where a finger seems to be over the lens, from the top left. Nil when the lens looks clear.
    var lensBlock: CGRect? = nil

    /// How many people are in the frame, whether their faces or only their bodies show.
    var personCount: Int {
        max(faces.count, people.count)
    }

    /// Whether the subject (or the group) runs off an edge of the frame.
    var subjectTouchesEdge: Bool {
        guard let subject else { return false }
        let margin = 0.02
        return subject.minX < margin || subject.minY < margin || subject.maxX > 1 - margin || subject.maxY > 1 - margin
    }

    /// How different two layouts are, 0...1. Near 0 for the same view; a clear reframe
    /// (moving, turning or zooming the camera) is well above `CoachRules.reframeThreshold`.
    static func reframeAmount(from start: [Double], to now: [Double]) -> Double {
        guard start.count == now.count, !start.isEmpty else { return 0 }
        return zip(start, now).map { abs($0 - $1) }.reduce(0, +) / Double(start.count)
    }

    /// The main scene, then the backdrop if there is one.
    var scenes: [SceneType] {
        [scene] + (backdrop.map { [$0] } ?? [])
    }

    /// A wide view such as a landscape or a street has no single subject to fill the frame
    /// with, so "get closer" tips don't apply. A small person in a big view is a fine shot.
    var isWideScene: Bool {
        scenes.contains(.landscape) || scenes.contains(.city)
    }

    /// The subject is clearly darker than what's behind it.
    var isBacklit: Bool {
        guard let subjectBrightness, let backgroundBrightness else { return false }
        // A dark laptop on a white desk is darker than its background but isn't backlit. Light
        // from behind shows as a glaring background: blown-out patches, or very bright overall.
        let brightBehind = highlightClip > 0.02 || backgroundBrightness > 0.85
        return brightBehind && backgroundBrightness - subjectBrightness > 0.25
    }

    /// The subject has too little detail to judge sharpness: a plain mug or a wall looks the
    /// same in focus or not, so the focus tip would be a guess.
    var subjectIsFlat: Bool {
        (subjectContrast ?? 1) < CoachRules.flatContrast
    }

    /// Short facts for the model and the debug overlay.
    /// Where the subject sits and how big it is, in words the model can use, like "the subject is on
    /// the left third, high up, filling about 10% of the frame". Nil when there's no subject.
    /// Vision measures this exactly; the model would otherwise have to guess it from a small image.
    var positionPhrase: String? {
        guard let subject else { return nil }
        let across = switch subject.midX {
        case ..<0.25: "near the left edge"
        case ..<0.42: "on the left third"
        case ...0.58: "in the centre"
        case ...0.75: "on the right third"
        default: "near the right edge"
        }
        let height: String? = switch subject.midY {
        case ..<0.4: "high up"
        case 0.6...: "low down"
        default: nil
        }
        let share = Double(subject.width * subject.height)
        let size = switch share {
        case ..<0.05: "filling under 5% of the frame"
        case 0.6...: "filling most of the frame"
        default: "filling about \(Int((share * 20).rounded()) * 5)% of the frame"
        }
        return (["the subject is \(across)", height, size] as [String?]).compactMap(\.self).joined(separator: ", ")
    }

    /// A head touches the top edge of the frame, so it's cut off.
    var headAtTopEdge: Bool {
        faces.contains { $0.minY < 0.02 }
    }

    var summary: String {
        var facts: [String] = []
        if let backdrop {
            facts.append("this looks like a \(scene.title.lowercased()) photo with a \(backdrop.title.lowercased()) behind")
        } else if scene != .object {
            facts.append("this looks like a \(scene.title.lowercased()) photo")
        }
        facts.append("overall brightness \(Self.percent(brightness))")
        if highlightClip > 0.02 { facts.append("\(Self.percent(highlightClip)) of the frame is blown out to white") }
        if shadowClip > 0.05 { facts.append("\(Self.percent(shadowClip)) is pure black") }
        if isBacklit { facts.append("the subject is darker than the background (backlit)") }
        facts.append(subjectSharpness < CoachRules.softThreshold ? "the subject looks soft" : "the subject is sharp")
        if personCount > 0 { facts.append("\(personCount) \(personCount == 1 ? "person" : "people")") }
        // Where the subject is: framing facts the model can't measure well from a small image.
        if let positionPhrase { facts.append(positionPhrase) }
        if headAtTopEdge { facts.append("a head touches the top edge") }
        if subjectTouchesEdge { facts.append("the subject runs off the edge of the frame") }
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
            "subject \(subjectText)  faces \(faces.count)  people \(people.count)  scene \(scenes.map(\.rawValue).joined(separator: "+"))",
            positionPhrase ?? "no subject",
            String(format: "EV %.2f  1/%.0fs  ISO %.0f", readings.exposureOffset ?? 0, 1 / (readings.exposureSeconds ?? 1), readings.iso ?? 0),
            String(format: "pitch %.0f°  tilt %.1f°  shake %.2f", pitch ?? 0, tilt ?? 0, shake ?? 0),
            String(format: "background busy %.3f (plain below %.3f)", backgroundBusyness ?? -1, CoachRules.plainBackgroundLimit),
            String(format: "subject contrast %.3f (flat below %.3f)", subjectContrast ?? -1, CoachRules.flatContrast),
            "lens block " + (lensBlock.map { LensBlockFinder.placeName(of: $0) } ?? "none"),
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
        shake: Double? = nil,
        selectedSubject: CGRect? = nil
    ) async -> SceneAnalysis? {
        guard let gray = GrayImage(image) else { return nil }
        let found = SubjectFinder.find(in: image)
        // What the person tapped is the subject, whatever else stands out.
        let subject = selectedSubject ?? found.subject
        let faces = detectFaces(in: image)
        let labels = classify(image)
        // A clearly visible body means people too, even when the face is turned away.
        let bodies = found.people.filter { $0.width * $0.height >= 0.06 }
        let scene = SceneType.classify(labels: labels, faces: faces + bodies)
        // What the labels alone say, so a person in front of a landscape keeps the landscape too.
        let behind = SceneType.classify(labels: labels, faces: [])
        let backdrop = scene == .people && behind != .object && behind != .people ? behind : nil

        // Without a subject, judge sharpness and brightness in the middle of the frame.
        let region = subject ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let inside = gray.mean(in: region)
        let outside = subject == nil ? nil : gray.mean(outside: region)

        // A finger over the lens, unless it's what the person tapped or a face.
        var lensBlock = ColorGrid(image).flatMap { colors in
            LensBlockFinder.find(cells: LensBlockFinder.cells(gray: gray, colors: colors), exempt: faces + [selectedSubject].compactMap(\.self))
        }
        // A hand Vision can make out is in focus, so it's in the shot on purpose.
        if let block = lensBlock, LensBlockFinder.overlapsMost(block, detectHands(in: image)) {
            lensBlock = nil
        }

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
            scene: scene,
            people: found.people,
            layout: (0..<64).map { cell in
                gray.mean(in: CGRect(x: Double(cell % 8) / 8, y: Double(cell / 8) / 8, width: 1.0 / 8, height: 1.0 / 8))
            },
            backdrop: backdrop,
            backgroundBusyness: subject.map { gray.edgeShare(in: $0.insetBy(dx: -0.15, dy: -0.15), excluding: $0) },
            subjectContrast: gray.contrast(in: region),
            lensBlock: lensBlock
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

    /// Hands Vision can make out, from the top left. A finger right on the lens is too blurred to find.
    private nonisolated static func detectHands(in image: CGImage) -> [CGRect] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        request.runOnCPUInSimulator()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { hand in
            let points = ((try? hand.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence > 0.5 }
            guard points.count >= 6 else { return nil }
            let xs = points.map(\.location.x)
            let ys = points.map(\.location.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            // Vision measures from the bottom left, the screen from the top left.
            return CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY).insetBy(dx: -0.05, dy: -0.05)
        }
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

// MARK: - A finger over the lens

/// Finds a finger resting over the lens. Right on the glass it can't be focused, and it blocks the
/// light, so it shows up as a large, very blurry patch coming in from a corner or part of one side,
/// clearly redder than the rest of the picture and darker than it (or glowing red where light shines
/// through). The rest of the scene stays sharp. A finger held up in the shot on purpose is in focus,
/// so it doesn't count. Smooth things that span the frame, like a ceiling, sky or table, don't either.
nonisolated enum LensBlockFinder {
    /// One cell of the grid laid over the frame.
    struct Cell: Equatable, Sendable {
        /// Variance of the Laplacian, as in `SceneAnalysis.subjectSharpness`.
        var sharpness: Double
        /// Average red, green and blue, 0...1.
        var red: Double
        var green: Double
        var blue: Double

        var brightness: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

        /// Skin's order of colours, red over green over blue, whatever the lighting.
        var hasSkinHue: Bool {
            red >= 0.04 && red > green && green >= blue * 0.8
        }
    }

    static let columns = 8
    static let rows = 8
    /// Scenes with less detail than this in their sharper parts are soft all over: nothing to compare against.
    static let detailedScene = 60.0
    /// A cell this much softer than the scene's detailed parts is as blurred as something on the lens.
    static let blurShare = 0.06
    /// Between about 5% and half the frame: smaller is a speck, bigger is the scene itself.
    static let cellRange = 3...32
    /// How much redder than the whole picture a finger is. Comparing with the picture rather than
    /// a fixed colour means warm lighting, which makes everything look warm, doesn't count.
    static let redderThanScene = 1.15
    /// A finger blocks light, so it's at least this much darker than the picture overall...
    static let darkerThanScene = 0.8
    /// ...unless light shines through it, which makes it glow far redder than anything else.
    static let glowRedness = 1.4

    /// The patch covered by a finger, from the top left, or nil when the lens looks clear.
    /// `exempt` is what's in the shot on purpose, like faces or the tapped subject.
    static func find(cells: [[Cell]], exempt: [CGRect] = []) -> CGRect? {
        let all = cells.flatMap(\.self)
        guard cells.count == rows, cells.allSatisfy({ $0.count == columns }) else { return nil }
        let sorted = all.map(\.sharpness).sorted()
        // The sharper quarter of the frame stands for how detailed the scene is.
        let detail = sorted[sorted.count * 3 / 4]
        guard detail >= detailedScene else { return nil }
        let blurLimit = max(6, detail * blurShare)
        // The picture's typical colour and brightness, so each cell is judged against its own scene.
        let sceneRedness = median(all.map { $0.red / max($0.green, 0.01) })
        let sceneBrightness = median(all.map(\.brightness))
        let isBlocked = { (cell: Cell) -> Bool in
            guard cell.sharpness < blurLimit, cell.hasSkinHue else { return false }
            let redness = (cell.red / max(cell.green, 0.01)) / max(sceneRedness, 0.01)
            guard redness >= redderThanScene else { return false }
            return redness >= glowRedness || cell.brightness <= sceneBrightness * darkerThanScene
        }

        // Grow the patch in from blocked cells on the edge of the frame.
        var inPatch = Array(repeating: Array(repeating: false, count: columns), count: rows)
        var queue: [(row: Int, column: Int)] = []
        for row in 0..<rows {
            for column in 0..<columns where row == 0 || row == rows - 1 || column == 0 || column == columns - 1 {
                if isBlocked(cells[row][column]) {
                    inPatch[row][column] = true
                    queue.append((row, column))
                }
            }
        }
        var index = 0
        while index < queue.count {
            let (row, column) = queue[index]
            index += 1
            for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let r = row + dr, c = column + dc
                guard (0..<rows).contains(r), (0..<columns).contains(c), !inPatch[r][c], isBlocked(cells[r][c]) else { continue }
                inPatch[r][c] = true
                queue.append((r, c))
            }
        }

        // Only the largest patch counts; a few stray cells along different edges aren't a finger.
        let patch = largestGroup(of: queue.map { ($0.row, $0.column) })
        guard cellRange.contains(patch.count) else { return nil }
        // A finger comes in from a corner or part of one side. Something running right across the
        // frame, edge to edge, is part of the scene: a ceiling, the sky, a floor or a table top.
        let patchRows = Set(patch.map(\.0)), patchColumns = Set(patch.map(\.1))
        let spansAcross = patch.contains { $0.1 == 0 } && patch.contains { $0.1 == columns - 1 }
        let spansDown = patch.contains { $0.0 == 0 } && patch.contains { $0.0 == rows - 1 }
        guard !spansAcross, !spansDown, patchRows.count < rows, patchColumns.count < columns else { return nil }

        // The rest of the frame has to be clearly sharp, so a soft scene isn't mistaken for a finger.
        let patchSet = Set(patch.map { $0.0 * columns + $0.1 })
        let sharpElsewhere = all.indices.filter { !patchSet.contains($0) && all[$0].sharpness >= blurLimit * 4 }.count
        guard sharpElsewhere >= 8 else { return nil }

        let minRow = patch.map(\.0).min() ?? 0, maxRow = patch.map(\.0).max() ?? 0
        let minColumn = patch.map(\.1).min() ?? 0, maxColumn = patch.map(\.1).max() ?? 0
        let box = CGRect(
            x: Double(minColumn) / Double(columns), y: Double(minRow) / Double(rows),
            width: Double(maxColumn - minColumn + 1) / Double(columns), height: Double(maxRow - minRow + 1) / Double(rows)
        )
        return overlapsMost(box, exempt) ? nil : box
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// How much two patches overlap, 0...1 (intersection over union).
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let sharedArea = shared.width * shared.height
        let union = a.width * a.height + b.width * b.height - sharedArea
        return union > 0 ? sharedArea / union : 0
    }

    /// Whether a third or more of `box` is covered by one of `others`.
    static func overlapsMost(_ box: CGRect, _ others: [CGRect]) -> Bool {
        let area = box.width * box.height
        guard area > 0 else { return false }
        return others.contains { other in
            let shared = box.intersection(other)
            return !shared.isNull && shared.width * shared.height >= area / 3
        }
    }

    /// Where the patch is, for the advice: "the top left corner", "the bottom edge".
    static func placeName(of box: CGRect) -> String {
        let vertical = box.minY <= 0.01 && box.maxY < 0.99 ? "top" : (box.maxY >= 0.99 && box.minY > 0.01 ? "bottom" : nil)
        let horizontal = box.minX <= 0.01 && box.maxX < 0.99 ? "left" : (box.maxX >= 0.99 && box.minX > 0.01 ? "right" : nil)
        switch (vertical, horizontal) {
        case let (v?, h?): return "the \(v) \(h) corner"
        case let (v?, nil): return "the \(v) edge"
        case let (nil, h?): return "the \(h) edge"
        default: return "the edge"
        }
    }

    /// Measures each cell of the grid.
    static func cells(gray: GrayImage, colors: ColorGrid) -> [[Cell]] {
        (0..<rows).map { row in
            (0..<columns).map { column in
                let rect = CGRect(
                    x: Double(column) / Double(columns), y: Double(row) / Double(rows),
                    width: 1 / Double(columns), height: 1 / Double(rows)
                )
                let color = colors.mean(row: row, column: column)
                return Cell(sharpness: gray.sharpness(in: rect), red: color.red, green: color.green, blue: color.blue)
            }
        }
    }

    /// The biggest set of cells joined side by side.
    private static func largestGroup(of cells: [(Int, Int)]) -> [(Int, Int)] {
        var remaining = Set(cells.map { $0.0 * columns + $0.1 })
        var best: [(Int, Int)] = []
        while let start = remaining.first {
            remaining.remove(start)
            var group = [start]
            var index = 0
            while index < group.count {
                let cell = group[index]
                index += 1
                let row = cell / columns, column = cell % columns
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let r = row + dr, c = column + dc
                    guard (0..<rows).contains(r), (0..<columns).contains(c) else { continue }
                    if remaining.remove(r * columns + c) != nil { group.append(r * columns + c) }
                }
            }
            if group.count > best.count { best = group.map { ($0 / columns, $0 % columns) } }
        }
        return best
    }
}

/// The average colour of each cell of the `LensBlockFinder` grid.
nonisolated struct ColorGrid {
    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init?(_ image: CGImage) {
        // Four pixels per cell each way is plenty for an average colour.
        width = LensBlockFinder.columns * 4
        height = LensBlockFinder.rows * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    /// Rows count from the top, like the rest of the analysis.
    func mean(row: Int, column: Int) -> (red: Double, green: Double, blue: Double) {
        let size = 4
        var sums = (0.0, 0.0, 0.0)
        for y in row * size..<(row + 1) * size {
            for x in column * size..<(column + 1) * size {
                let i = (y * width + x) * 4
                sums.0 += Double(pixels[i])
                sums.1 += Double(pixels[i + 1])
                sums.2 += Double(pixels[i + 2])
            }
        }
        let count = Double(size * size) * 255
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }
}

/// A small grayscale copy of a frame for quick pixel measurements.
nonisolated struct GrayImage {
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

    /// The spread of brightness inside `rect` (standard deviation, 0...0.5).
    func contrast(in rect: CGRect) -> Double {
        let (xs, ys) = bounds(of: rect)
        var sum = 0.0
        var sumOfSquares = 0.0
        for y in ys {
            for x in xs {
                let value = Double(pixels[y * width + x]) / 255
                sum += value
                sumOfSquares += value * value
            }
        }
        let count = Double(xs.count * ys.count)
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean).squareRoot()
    }

    /// Share of pixels inside `rect` but outside `excluded` that sit on a clear edge, 0...1.
    /// Counting edges rather than how strong they are means the few straight lines of a door
    /// frame or a window score low, while clutter, with edges everywhere, scores high.
    func edgeShare(in rect: CGRect, excluding excluded: CGRect) -> Double {
        let (xs, ys) = bounds(of: rect)
        let (skipXs, skipYs) = bounds(of: excluded)
        var edges = 0
        var count = 0
        for y in max(ys.lowerBound, 1)..<min(ys.upperBound, height - 1) {
            for x in max(xs.lowerBound, 1)..<min(xs.upperBound, width - 1) where !(skipXs.contains(x) && skipYs.contains(y)) {
                let center = Int(pixels[y * width + x])
                let laplacian = Int(pixels[(y - 1) * width + x]) + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + x - 1]) + Int(pixels[y * width + x + 1]) - 4 * center
                if abs(laplacian) > 24 { edges += 1 }
                count += 1
            }
        }
        return count == 0 ? 0 : Double(edges) / Double(count)
    }
}
