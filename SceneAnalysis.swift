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
    /// The front camera is a mirror: "your left" is the left of the screen, as it is from behind.
    var isFrontCamera = false
    /// White Balance has been set by hand, so a colour cast is the person's choice.
    var isWhiteBalanceSet = false
    // So the advice can say how much to move: "Zoom to 2×", "Turn about 10° left".
    /// The zoom, like the zoom buttons: 1 is the main lens.
    var zoom: Double = 1
    /// The zoom buttons this camera offers.
    var zoomStops: [Double] = [1, 2]
    /// How many degrees the view spans across the sensor's long side, at the current zoom.
    var fieldOfView: Double? = nil
    /// The lens's f-number, for working out how much light there is.
    var aperture: Double? = nil

    /// How much light there is, as EV at ISO 100: about 15 in direct sun, 12 to 13 under cloud,
    /// 11 or less in rain, and below 10 indoors. Nil until the camera reports its exposure.
    var lightLevel: Double? {
        guard let exposureSeconds, exposureSeconds > 0, let iso, iso > 0 else { return nil }
        // The main lens of recent iPhones, if the camera didn't say.
        let fNumber = aperture ?? 1.78
        return log2(fNumber * fNumber / exposureSeconds) - log2(iso / 100)
    }

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
            isFrontCamera: camera.isUsingFrontCamera,
            isWhiteBalanceSet: camera.whiteBalanceKelvin != nil,
            zoom: Double(camera.zoomLevel),
            zoomStops: camera.zoomStops.map(Double.init),
            fieldOfView: Self.fieldOfView(of: device),
            aperture: Double(device.lensAperture)
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
    /// For the biggest face: its darker side's brightness over its brighter side's, 0...1.
    /// Near 1 is evenly lit; low means one half of the face is lost in shadow. Nil without a face.
    var faceShadowRatio: Double? = nil
    /// The side of the biggest face that's clearly brighter, as seen on screen. Nil when it's even.
    var faceLitSide: LightSide? = nil
    /// A small, blown-out light source in the frame, like the sun, a lamp or a window, from the
    /// top left. Nil when there's none, or when the whole sky is bright rather than one spot.
    var lightSpot: CGRect? = nil
    /// Vision sees an outdoor scene, so a bright spot can be the sun.
    var isOutdoors = false
    /// The hour on the phone's clock when the frame was analysed, nil when unknown.
    var hour: Int? = nil
    /// Things in the shot apart from the people: what stands out, and what was tapped when it
    /// isn't a person. When there are people, these are meant to be in the photo with them.
    var otherThings: [CGRect] = []

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

    /// Daylight with no direct sun: outdoors, no sun in the shot, and too little light for sunshine.
    /// Cloud and rain spread the light out, so it can't cast hard shadows or patches of sun.
    nonisolated var isSoftDaylight: Bool {
        guard isOutdoors, !isOutdoorsAtNight, sunSpot == nil, let level = readings.lightLevel else { return false }
        return level < CoachRules.directSunLevel
    }

    /// Outdoors after dark, where the light comes from street lamps, signs and windows, which can
    /// cast hard shadows. Night is far darker than even heavy rain, so the light level decides;
    /// the clock catches brightly lit places at night, like a floodlit square.
    nonisolated var isOutdoorsAtNight: Bool {
        guard isOutdoors else { return false }
        if let hour, !CoachRules.isDaytime(hour: hour) { return true }
        if let level = readings.lightLevel, level < CoachRules.nightLevel { return true }
        return false
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

    /// Short facts for the model.
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
        // Where the light is, so the model's light tips agree with what's measured.
        if let lightSpot {
            let place = LightSide.of(lightSpot)
            let what = sunSpot != nil ? "likely the sun" : "likely a lamp or window"
            facts.append("a small, very bright light source (\(what)) at the \(place.rawValue) of the frame")
        }
        if let side = lightSide?.sideWord { facts.append("the light comes from the \(side) of the frame") }
        if isSoftDaylight { facts.append("the sky is overcast, so the daylight is soft and even, with no direct sun") }
        if isOutdoorsAtNight { facts.append("it is night outside, so the light comes from street lamps, signs or windows, not the sun") }
        // What's already on, so it isn't suggested again.
        var settings: [String] = []
        if readings.isNightModeOn { settings.append("Night Mode") }
        if readings.isFlashOn { settings.append("Flash") }
        if readings.isWhiteBalanceSet { settings.append("a hand-set White Balance") }
        if abs(readings.exposureBias) >= 0.3 {
            settings.append(String(format: "brightness adjusted by %+.1f stops", readings.exposureBias))
        }
        if !settings.isEmpty { facts.append("already on: " + settings.joined(separator: ", ")) }
        return facts.joined(separator: "; ")
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
        let outdoors = [scene, behind].contains { [.landscape, .city, .nature].contains($0) }
            || labels.contains { ["sky", "outdoor", "sun", "sunset", "sunrise", "cloud"].contains($0.identifier.lowercased()) }
        let faceLight = faceLighting(of: faces, in: gray)
        // Apart from the people, including bodies only guessed from faces, since a close selfie
        // often shows too little of a body to be found.
        let everyone = found.people + faces.map { bodyBox(below: $0) }
        var others = SubjectFinder.otherThings(found.others, apartFrom: everyone)
        // A tapped thing that isn't a person is meant to be in the shot, however small.
        if let selectedSubject, !everyone.contains(where: { $0.intersects(selectedSubject) }) {
            others.append(selectedSubject)
        }

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
            scene: scene,
            people: found.people,
            layout: (0..<64).map { cell in
                gray.mean(in: CGRect(x: Double(cell % 8) / 8, y: Double(cell / 8) / 8, width: 1.0 / 8, height: 1.0 / 8))
            },
            backdrop: backdrop,
            backgroundBusyness: subject.map { gray.edgeShare(in: $0.insetBy(dx: -0.15, dy: -0.15), excluding: $0) },
            subjectContrast: gray.contrast(in: region),
            faceShadowRatio: faceLight?.ratio,
            faceLitSide: faceLight.flatMap { $0.ratio < Self.faceEvenRatio ? $0.litSide : nil },
            lightSpot: LightSpotFinder.find(in: gray),
            isOutdoors: outdoors,
            hour: Calendar.current.component(.hour, from: .now),
            otherThings: others
        )
    }

    /// Roughly where the body under a face is: a little wider than the face, and several faces
    /// tall below it, kept inside the frame.
    nonisolated static func bodyBox(below face: CGRect) -> CGRect {
        CGRect(x: face.minX - face.width * 0.75, y: face.minY - face.height * 0.3,
               width: face.width * 2.5, height: face.height * 4)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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

    /// How evenly the biggest face is lit across, comparing its left and right halves. Only the
    /// middle of the face is measured, so hair and background at the edges of the box don't count.
    nonisolated static func faceShadowRatio(of faces: [CGRect], in gray: GrayImage) -> Double? {
        faceLighting(of: faces, in: gray)?.ratio
    }

    /// Above this, a face looks evenly lit, so no side counts as the lit one.
    nonisolated static let faceEvenRatio = 0.8

    /// The biggest face's darker-over-brighter ratio, and which half is the brighter one.
    nonisolated static func faceLighting(of faces: [CGRect], in gray: GrayImage) -> (ratio: Double, litSide: LightSide)? {
        guard let face = faces.max(by: { $0.width * $0.height < $1.width * $1.height }),
              face.width >= 0.05 else { return nil }
        let inner = face.insetBy(dx: face.width * 0.12, dy: face.height * 0.15)
        let half = inner.width / 2
        let left = gray.mean(in: CGRect(x: inner.minX, y: inner.minY, width: half, height: inner.height))
        let right = gray.mean(in: CGRect(x: inner.midX, y: inner.minY, width: half, height: inner.height))
        let brighter = max(left, right)
        guard brighter > 0.08 else { return nil }
        return (min(left, right) / brighter, left >= right ? .left : .right)
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

    /// The share of pixels inside `rect` that pass `isIncluded`.
    func share(in rect: CGRect, where isIncluded: (UInt8) -> Bool) -> Double {
        let (xs, ys) = bounds(of: rect)
        var count = 0
        for y in ys { for x in xs where isIncluded(pixels[y * width + x]) { count += 1 } }
        return Double(count) / Double(xs.count * ys.count)
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


// MARK: - Where the light comes from

/// A side of the frame, as seen on screen.
nonisolated enum LightSide: String, Sendable, Equatable {
    case left, right, top, centre

    /// "left", "right": for "the light on your left". Nil for top and centre, which have no side to walk to.
    var sideWord: String? {
        switch self {
        case .left: "left"
        case .right: "right"
        default: nil
        }
    }

    var opposite: LightSide {
        switch self {
        case .left: .right
        case .right: .left
        default: self
        }
    }

    /// The side a spot is on, from its position in the frame.
    static func of(_ box: CGRect) -> LightSide {
        if box.midX < 0.4 { return .left }
        if box.midX > 0.6 { return .right }
        return box.midY < 0.35 ? .top : .centre
    }
}

extension SceneAnalysis {
    /// The sun, when the bright spot is outdoors. Indoors the same spot is a lamp or a window.
    /// At night a bright spot outdoors is a street lamp, not the sun.
    nonisolated var sunSpot: CGRect? { isOutdoors && !isOutdoorsAtNight ? lightSpot : nil }

    /// Which side the light comes from, only when the measurements are sure. A bright spot and
    /// the lit side of a face have to agree; on its own, only a clear sun or a face lost in deep
    /// shadow on one side is enough. Otherwise nil, and the advice doesn't name a side.
    nonisolated var lightSide: LightSide? {
        let fromSpot = lightSpot.map(LightSide.of)
        switch (fromSpot, faceLitSide) {
        case let (spot?, face?):
            return spot == face ? spot : nil
        case let (spot?, nil):
            return sunSpot != nil ? spot : nil
        case let (nil, face?):
            return (faceShadowRatio ?? 1) < CoachRules.faceShadowLimit ? face : nil
        case (nil, nil):
            return nil
        }
    }

    /// Someone is in the shot with something else that matters: scenery Vision recognises behind
    /// them, another thing that stands out, something tapped, or the place itself in a wide selfie.
    /// The camera mustn't move and nobody should turn around, or it would leave the shot.
    nonisolated var sceneryMatters: Bool {
        guard personCount > 0 else { return false }
        if backdrop != nil || !otherThings.isEmpty { return true }
        // A selfie with the face small in the frame is about where you are.
        return readings.isFrontCamera && (faces.map(\.height).max() ?? 0) < CoachRules.wideSelfieFace
    }

    /// How much of the frame the subject fills, 0...1, or nil without a subject.
    nonisolated var subjectShare: Double? {
        subject.map { Double($0.width * $0.height) }
    }

    /// Flash reaches a nearby subject, never a building or a view.
    nonisolated var flashCanReach: Bool {
        !isFixedScene
    }

    /// A scene that can't be moved or turned: a building or a view, with nobody in it.
    nonisolated var isFixedScene: Bool {
        personCount == 0 && (isWideScene || scene == .city || scene == .landscape)
    }

    /// Whether what's being photographed can move into better light: a person can be asked (or it's
    /// you, on the front camera), and food or an object can be carried. A building, a view, a plant
    /// or an animal can't, so light tips never ask them to.
    nonisolated var canMoveSubject: Bool {
        readings.isFrontCamera || personCount > 0 || !(isFixedScene || scene == .nature)
    }
}

/// Finds a small, blown-out light source: the sun, a bare bulb, a bright window. A whole bright
/// sky or a white wall isn't one: the spot must be compact, and clearly brighter than around it.
nonisolated enum LightSpotFinder {
    static let columns = 16
    static let rows = 16
    /// A cell counts as blown out when this share of its pixels is near white.
    static let hotShare = 0.5
    /// At most this many cells (about 6% of the frame): bigger is the sky or a wall, not a source.
    static let maxCells = 15
    /// The most of the frame a light source can cover.
    static let maxShare = Double(maxCells) / Double(columns * rows)
    /// At most this wide or tall, as a share of the frame.
    static let maxSpan = 0.3
    /// Around the spot must be darker than this, or the bright area is just the scene.
    static let darkerAround = 0.85

    static func find(in gray: GrayImage) -> CGRect? {
        let hot = (0..<rows).map { row in
            (0..<columns).map { column in gray.share(in: cell(row: row, column: column)) { $0 >= 250 } }
        }
        let brightness = (0..<rows).map { row in
            (0..<columns).map { column in gray.mean(in: cell(row: row, column: column)) }
        }
        return find(hot: hot, brightness: brightness)
    }

    static func cell(row: Int, column: Int) -> CGRect {
        CGRect(x: Double(column) / Double(columns), y: Double(row) / Double(rows),
               width: 1 / Double(columns), height: 1 / Double(rows))
    }

    /// The spot from each cell's share of blown-out pixels and its brightness, rows from the top.
    static func find(hot: [[Double]], brightness: [[Double]]) -> CGRect? {
        guard hot.count == rows, hot.allSatisfy({ $0.count == columns }),
              brightness.count == rows, brightness.allSatisfy({ $0.count == columns }) else { return nil }
        let hotCells = (0..<rows).flatMap { r in (0..<columns).filter { hot[r][$0] >= hotShare }.map { (r, $0) } }
        // Lots of blown-out cells is a bright sky or a white wall, not one light source.
        guard !hotCells.isEmpty, hotCells.count <= maxCells * 2 else { return nil }

        // The biggest group of blown-out cells touching side by side.
        var remaining = Set(hotCells.map { $0.0 * columns + $0.1 })
        var best: [Int] = []
        while let start = remaining.first {
            remaining.remove(start)
            var group = [start], index = 0
            while index < group.count {
                let r = group[index] / columns, c = group[index] % columns
                index += 1
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard (0..<rows).contains(nr), (0..<columns).contains(nc) else { continue }
                    if remaining.remove(nr * columns + nc) != nil { group.append(nr * columns + nc) }
                }
            }
            if group.count > best.count { best = group }
        }
        guard (1...maxCells).contains(best.count) else { return nil }

        let groupRows = best.map { $0 / columns }, groupColumns = best.map { $0 % columns }
        let minRow = groupRows.min()!, maxRow = groupRows.max()!
        let minColumn = groupColumns.min()!, maxColumn = groupColumns.max()!
        let width = Double(maxColumn - minColumn + 1) / Double(columns)
        let height = Double(maxRow - minRow + 1) / Double(rows)
        guard width <= maxSpan, height <= maxSpan else { return nil }

        // The ring of cells around the spot has to be clearly darker than it.
        let members = Set(best)
        var ring: [Double] = []
        for r in max(minRow - 1, 0)...min(maxRow + 1, rows - 1) {
            for c in max(minColumn - 1, 0)...min(maxColumn + 1, columns - 1) where !members.contains(r * columns + c) {
                ring.append(brightness[r][c])
            }
        }
        guard !ring.isEmpty, ring.reduce(0, +) / Double(ring.count) < darkerAround else { return nil }

        return CGRect(x: Double(minColumn) / Double(columns), y: Double(minRow) / Double(rows), width: width, height: height)
    }
}
