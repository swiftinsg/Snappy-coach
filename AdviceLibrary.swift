//
//  AdviceLibrary.swift
//  Grp 6pm Photo App
//
//  Everything the coach can say. Measurements and the model only pick an issue;
//  the words come from here, so advice is always short, correct and teaches why.
//

import Foundation
import CoreGraphics
import FoundationModels

/// A problem the coach can point out.
nonisolated enum CoachIssue: String, CaseIterable, Sendable {
    // Found by measuring the frame.
    case underexposed, overexposed, highlightsClipped, backlitSubject
    case tooDark, harshContrast, highISO
    case cameraShaking, subjectSoft, slowShutter
    case phoneTilted, shootingDown, pointingUp
    case headCutOff, tooMuchHeadroom, subjectTooSmall
    // Judged by the model, because they can't be measured.
    case clutteredBackground, distractingEdges, subjectCutOff, noClearSubject
    case tooMuchEmptySpace, horizonThroughMiddle
    // Judged by the model against a chosen composition style.
    case linesDontLead, notSymmetric, vanishingPointOffCentre, linesNotStraight
    case noTriangle, noClearVertex, notOverhead, layersNotStacked, subjectTooBig, jointsCropped
}

/// What to do now, and the photography idea behind it.
nonisolated struct Advice: Equatable, Sendable {
    let action: String
    let why: String
    /// An arrow showing which way to move, when the advice has a direction.
    var symbol: String? = nil
    /// The third lines the advice names, like the bottom one for "put the horizon on the bottom
    /// third", so the viewfinder grid can light them up.
    var thirdsLines: Set<ThirdsLine> = []

    /// True when following both would undo each other, like moving left then right,
    /// so the coach never shows them together.
    func conflicts(with other: Advice) -> Bool {
        let mine = Self.directions(of: symbol)
        let theirs = Self.directions(of: other.symbol)
        let opposites: [(String, String)] = [("left", "right"), ("up", "down")]
        if opposites.contains(where: { (mine.contains($0.0) && theirs.contains($0.1)) || (mine.contains($0.1) && theirs.contains($0.0)) }) {
            return true
        }
        // Stepping closer and stepping back undo each other too.
        let closer = "arrow.up.left.and.arrow.down.right", back = "arrow.down.right.and.arrow.up.left"
        return (symbol == closer && other.symbol == back) || (symbol == back && other.symbol == closer)
    }

    /// The directions a plain arrow symbol points, like ["up", "left"] for "arrow.up.left".
    private static func directions(of symbol: String?) -> Set<String> {
        guard let symbol, symbol.hasPrefix("arrow."), !symbol.contains(".and.") else { return [] }
        return Set(symbol.split(separator: ".").dropFirst().map(String.init))
    }
}

/// Where in the frame the model saw the problem.
@Generable
enum FrameRegion: String {
    case left, right, top, bottom, centre, background, whole
}

/// What the model said about where the problem is and what causes it.
struct IssueDetail: Equatable {
    let region: FrameRegion
    /// A short, cleaned-up name like "the lamp post", or nil when the model's words weren't usable
    /// or Vision saw something else there.
    var thing: String?
    /// What the person tapped, like "cup", so the advice names it instead of "the subject".
    var subjectName: String? = nil
    /// Where `thing` was found on screen, in 0...1 viewfinder coordinates from the top left.
    var box: CGRect? = nil
    /// True when `box` is only the part of the frame named, because no single object stood out there.
    var boxIsArea = false
    /// The subject's box, in the same coordinates, so a step can be pointed the right way.
    var subjectBox: CGRect? = nil
    /// True for the front camera, whose view is mirrored, so the scene follows the phone.
    var isMirrored = false

    /// How to move the camera toward `region` of the view. In a mirrored view the scene moves
    /// the same way as the phone, so left and right swap.
    func cameraToward(_ region: FrameRegion) -> (text: String, symbol: String)? {
        let isSideways = region == .left || region == .right
        return (isMirrored && isSideways ? region.opposite ?? region : region).turnToward
    }

    /// How to move the camera away from `region` of the view.
    func cameraAway(from region: FrameRegion) -> (text: String, symbol: String)? {
        region.opposite.flatMap(cameraToward)
    }

    init(region: FrameRegion, rawThing: String, subjectName: String? = nil) {
        self.region = region
        self.thing = Self.cleanedThing(rawThing)
        // Vague names read worse than "the subject", and people are never described.
        if let subjectName, !["person", "object"].contains(subjectName) {
            self.subjectName = subjectName
        }
    }

    /// Whether Vision's view of the spot agrees with the name the model gave, so a thing the
    /// model imagined is never named or outlined. Only a confident label that matches nothing
    /// counts against the name: when Vision isn't sure, the model gets the benefit of the doubt.
    func matches(labels: [(label: String, confidence: Float)]) -> Bool {
        guard let thing else { return true }
        let named = thing.split(separator: " ").map(String.init).filter { $0 != "the" }
        guard labels.contains(where: { $0.confidence >= 0.4 }) else { return true }
        let seen = labels.flatMap { $0.label.lowercased().split(separator: "_").map(String.init) }
        return named.contains { word in seen.contains { Self.sameThing(word, $0) } }
    }

    /// Two words for the same kind of thing: the same stem, like "car" and "cars", or synonyms.
    static func sameThing(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        if shorter.count >= 3, longer.hasPrefix(shorter) { return true }
        return CoachRules.objectSynonyms.contains { $0.contains(a) && $0.contains(b) }
    }

    /// How the advice names the subject: what was tapped, or else "the subject".
    var subjectPhrase: String {
        subjectName.map { "the \($0)" } ?? "the subject"
    }

    /// The thing the model named, unless it named the subject, which can't be a distraction.
    var distraction: String? {
        let subjectNames = ["the subject", "the subjects", subjectName.map { "the \($0)" }]
        return subjectNames.contains(thing) ? nil : thing
    }

    /// Which way to step so `thing` slides out from behind the subject, or nil when it's
    /// straight behind it. Stepping toward the side it's on moves it further that way, because
    /// the background shifts less than the nearer subject.
    var stepSide: FrameRegion? {
        // With the front camera the subject is usually the person holding it, who moves too.
        guard !isMirrored, let box, let subjectBox else { return nil }
        let offset = box.midX - subjectBox.midX
        guard abs(offset) >= 0.03 else { return nil }
        return offset < 0 ? .left : .right
    }

    /// Words that describe a person. The coach never describes people, so these become "the subject".
    private static let personWords: Set<String> = [
        "man", "woman", "boy", "girl", "person", "guy", "lady", "child", "kid", "baby",
    ]
    /// Words for several people, which become "the subjects".
    private static let groupWords: Set<String> = [
        "people", "group", "friends", "family", "men", "women", "kids", "children", "couple", "crowd",
    ]

    /// Keeps the model's object name to a few plain words, or drops it.
    static func cleanedThing(_ text: String) -> String? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) else { return nil }
        var words = trimmed.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an", "this", "that"].contains(first) {
            words.removeFirst()
        }
        guard (1...3).contains(words.count), !["none", "nothing"].contains(words[0]) else { return nil }
        if words.contains(where: groupWords.contains) { return "the subjects" }
        if words.contains(where: personWords.contains) { return "the subject" }
        return "the " + words.joined(separator: " ")
    }
}

extension FrameRegion {
    /// The edge of the frame this region names, if it is one.
    nonisolated var edgeName: String? {
        switch self {
        case .left: "left edge"
        case .right: "right edge"
        case .top: "top"
        case .bottom: "bottom"
        default: nil
        }
    }

    /// How to move the camera toward this side of the frame. Framing only: no turning or tilting.
    nonisolated var turnToward: (text: String, symbol: String)? {
        switch self {
        case .left: ("Move the camera slightly left", "arrow.left")
        case .right: ("Move the camera slightly right", "arrow.right")
        case .top: ("Move the camera up a little", "arrow.up")
        case .bottom: ("Move the camera down a little", "arrow.down")
        default: nil
        }
    }

    /// The other side of the frame, or nil for regions without one.
    nonisolated var opposite: FrameRegion? {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        default: nil
        }
    }
}

extension CoachIssue {
    /// Short, beginner-friendly advice that names the controls in the topic's top bar.
    /// With a `detail` from the model, the action names what to move away from and which way.
    /// With `keepsPlacement`, the subject is already where the target guide wants it, so the advice
    /// never asks to move the camera across the frame, which would undo that.
    func advice(
        for topic: AdviceTopic,
        analysis: SceneAnalysis? = nil,
        detail: IssueDetail? = nil,
        keepsPlacement: Bool = false
    ) -> Advice {
        // The main scene's wording first, then the backdrop's, e.g. a person in a landscape.
        let sceneWording = analysis?.scenes.lazy.compactMap { sceneAdvice(for: $0) }.first
        let general = sceneWording ?? generalAdvice(for: topic, analysis: analysis)
        if keepsPlacement, let safe = placementSafeAction(detail) {
            return Advice(action: safe.text, why: general.why, symbol: safe.symbol)
        }
        guard let detail, let specific = specificAction(detail) else {
            // Say how much: the zoom button to tap, rather than just "step closer".
            if let analysis, let distance = distanceAction(analysis) {
                return Advice(action: distance, why: general.why, symbol: general.symbol)
            }
            return general
        }
        return Advice(action: specific.text, why: general.why, symbol: specific.symbol ?? general.symbol, thirdsLines: general.thirdsLines)
    }

    /// How much of the frame the subject should fill once it's close enough.
    static let comfortableShare = 0.06

    /// A step closer or back with an amount: the zoom button that gets there, from how much
    /// of the frame the subject fills now. Nil for other issues, or when zoom can't help.
    func distanceAction(_ analysis: SceneAnalysis) -> String? {
        let readings = analysis.readings
        let stops = readings.zoomStops.sorted()
        switch asksToMove {
        case .closer:
            let size = analysis.subject.map { Double($0.width * $0.height) }
                ?? analysis.faces.map { Double($0.width * $0.height) }.max()
            guard let size, size > 0 else { return nil }
            // Zooming by a factor makes the subject that much wider and taller.
            let needed = readings.zoom * (Self.comfortableShare / size).squareRoot()
            if let stop = stops.first(where: { $0 >= needed - 0.05 && $0 > readings.zoom + 0.05 }) {
                return "Zoom to \(Self.zoomText(stop)), or walk closer"
            }
            return "Walk a few steps closer"
        case .back:
            // Zoomed in: the next button down shows more, without walking.
            guard let stop = stops.last(where: { $0 < readings.zoom - 0.05 }) else { return nil }
            return "Zoom out to \(Self.zoomText(stop)), or step back"
        case nil:
            return nil
        }
    }

    /// A zoom like the buttons show it: "0.5×", "2×".
    static func zoomText(_ zoom: Double) -> String {
        String(format: "%g×", zoom)
    }

    /// Tips that can only be followed by moving the subject off the spot the target guide put it in,
    /// so they lose to the guide.
    func undoesPlacement(_ placement: SubjectPlacement) -> Bool {
        switch self {
        case .vanishingPointOffCentre: true
        // Moving the horizon means moving the camera up or down, which only matters
        // when the guide fixes the subject's height too.
        case .horizonThroughMiddle: placement.fixesHeight
        default: false
        }
    }

    /// The same fix without moving the camera across the frame: stepping or zooming keeps the
    /// subject where the guide put it. Nil when the usual advice doesn't move the camera sideways.
    private func placementSafeAction(_ detail: IssueDetail?) -> (text: String, symbol: String?)? {
        switch self {
        case .distractingEdges:
            let target = detail?.distraction ?? "distractions at the edges"
            return ("Step closer or zoom in a little to drop \(target)", "arrow.up.left.and.arrow.down.right")
        case .subjectCutOff:
            let cut = detail.map { $0.distraction ?? $0.subjectPhrase } ?? "the subject"
            return ("Step back so \(cut) fits", "arrow.down.right.and.arrow.up.left")
        default:
            return nil
        }
    }

    private func generalAdvice(for topic: AdviceTopic, analysis: SceneAnalysis?) -> Advice {
        switch self {
        case .underexposed:
            Advice(action: "Drag the Exposure slider right", why: "A dark photo hides detail and looks muddy.")
        case .overexposed:
            Advice(action: "Drag the Exposure slider left", why: "Slightly dark beats too bright: lost highlights can't come back.")
        case .highlightsClipped:
            Advice(action: "Drag Exposure left until bright areas show detail", why: "Pure white areas have no detail left, even in editing.")
        case .backlitSubject:
            topic == .exposure
                ? Advice(action: "Drag the Exposure slider right for the subject", why: "Bright light behind the subject makes the camera darken it.")
                : Advice(action: "Turn so the light falls on the subject's front", why: "Light from behind leaves the subject in shadow.")
        case .tooDark:
            Advice(action: "Tap Night Mode, or move nearer a light", why: "In dim light the camera adds grain and blur.")
        case .harshContrast:
            Advice(action: "Move into open shade or softer light", why: "Harsh light makes deep shadows and hot spots.")
        case .highISO:
            Advice(action: "Move toward a window or brighter light", why: "Low light forces high ISO, which adds grainy noise.")
        case .cameraShaking:
            Advice(action: "Hold still with both hands, elbows tucked in", why: "Movement while the shutter is open blurs the whole photo.")
        case .subjectSoft:
            Advice(action: "Drag the Focus slider until the subject is crisp", why: "The eye goes to the sharpest part of a photo first.")
        case .slowShutter:
            Advice(action: "Tuck your elbows in and hold very still", why: "A slow shutter turns small shakes into blur.")
        case .phoneTilted:
            tiltAdvice(analysis?.tilt)
        case .shootingDown:
            Advice(action: "Lower the phone to the subject's eye level", why: "Shooting down makes people and pets look small.", symbol: "arrow.down")
        case .pointingUp:
            Advice(action: "Hold the phone upright to keep lines straight", why: "Tilting up makes buildings look like they're falling back.")
        case .headCutOff:
            Advice(action: "Tilt the camera up to show the whole head", why: "Cutting off the top of a head looks like a mistake.", symbol: "arrow.up")
        case .tooMuchHeadroom:
            Advice(action: "Tilt down to align eyes with the upper third line", why: "Too much space above the head makes the subject look sunk.", symbol: "arrow.down", thirdsLines: [.top])
        case .subjectTooSmall:
            Advice(action: "Step closer or tap a zoom button", why: "Filling the frame makes it clear what the photo is about.")
        case .clutteredBackground:
            Advice(action: "Step left or right to put a plain background behind", why: "A busy background pulls the eye away from the subject.")
        case .distractingEdges:
            Advice(action: "Move the camera so bright things leave the edges", why: "Bright things near the edge drag the eye out of the photo.")
        case .subjectCutOff:
            Advice(action: "Step back so the whole subject fits", why: "Cropping through the subject looks accidental.")
        case .noClearSubject:
            Advice(action: "Pick one subject and move closer to it", why: "A photo needs one clear thing to look at.")
        case .tooMuchEmptySpace:
            Advice(action: "Step closer to fill the frame", why: "Empty space only helps when it gives the subject room to breathe.")
        case .horizonThroughMiddle:
            Advice(action: "Put the horizon on the top or bottom third line", why: "A horizon across the middle splits the photo in two.", thirdsLines: [.top, .bottom])
        case .linesDontLead:
            Advice(action: "Move so the lines run toward the subject", why: "Lines pull the eye along them, so they should end at what matters.")
        case .notSymmetric:
            Advice(action: "Step left or right until both halves mirror each other", why: "Symmetry works when both halves closely match.")
        case .vanishingPointOffCentre:
            Advice(action: "Move until the lines meet in the middle", why: "Lines meeting near the centre give the deepest look.")
        case .linesNotStraight:
            Advice(action: "Turn the phone until the lines match the grid", why: "Straight lines that lean make a photo look careless.")
        case .noTriangle:
            Advice(action: "Frame three key things so they form a triangle", why: "A triangle leads the eye around the photo and feels stable.")
        case .noClearVertex:
            Advice(action: "Move the camera until lines meet on a grid line", why: "Where lines meet is a natural place for the eye to rest.")
        case .notOverhead:
            Advice(action: "Hold the phone flat, straight above the table", why: "A true top-down view shows the arrangement like a map.")
        case .layersNotStacked:
            Advice(action: "Step back and zoom in to stack the layers", why: "Zooming from farther away pulls the background closer.")
        case .subjectTooBig:
            Advice(action: "Step back so the subject is small", why: "Negative space works when empty space outweighs the subject.")
        case .jointsCropped:
            Advice(action: "Frame at the waist, not at elbows or knees", why: "Cropping at a joint makes a body look cut off.")
        }
    }

    /// Wording for the kind of photo being taken, where the usual tip doesn't fit it well.
    private func sceneAdvice(for scene: SceneType?) -> Advice? {
        switch (self, scene) {
        case (.clutteredBackground, .food):
            Advice(action: "Move the plate so only the table is behind it", why: "A plain surface keeps the eye on the food.")
        case (.horizonThroughMiddle, .landscape):
            Advice(action: "Put the horizon on the bottom third for more sky", why: "Giving the sky or the land two thirds makes a clear choice.", thirdsLines: [.bottom])
        case (.subjectTooSmall, .nature):
            Advice(action: "Step closer, or tap 2× to fill the frame", why: "Small details in nature only shine when they fill the photo.")
        case (.harshContrast, .people):
            Advice(action: "Move the subject into shade for soft light", why: "Shade stops squinting and harsh shadows on the face.")
        case (.tooDark, .food), (.highISO, .food):
            Advice(action: "Move the plate next to a window", why: "Soft window light shows the texture of food.")
        case (.distractingEdges, .food):
            Advice(action: "Move cups and phones out of the frame", why: "Only what belongs to the meal should share the plate's space.")
        case (.subjectCutOff, .people):
            Advice(action: "Step back so you don't crop at joints", why: "Cutting at the neck, elbows or knees looks like a mistake.")
        case (.clutteredBackground, .people):
            Advice(action: "Move them a few steps away from the background", why: "Distance softens the background and lifts the subject off it.")
        case (.subjectTooSmall, .landscape), (.tooMuchEmptySpace, .landscape):
            Advice(action: "Add a rock or flower in the foreground", why: "Something close gives a landscape depth and a place to start.")
        case (.distractingEdges, .city):
            Advice(action: "Step closer to drop cars and signs at the edges", why: "Busy streets crowd the edges and pull the eye out.")
        case (.linesDontLead, .city):
            Advice(action: "Stand so the street runs toward the subject", why: "Streets and kerbs are lines that lead the eye.")
        case (.clutteredBackground, .nature):
            Advice(action: "Get low so the sky is behind it", why: "A plain sky makes a flower or animal stand out.")
        default:
            nil
        }
    }

    /// Advice that uses what the model saw, or nil when the detail doesn't help for this issue.
    private func specificAction(_ detail: IssueDetail) -> (text: String, symbol: String?)? {
        // "The subject" can't be a distraction in the background or at the edge.
        let object = detail.distraction
        let subject = detail.subjectPhrase
        switch self {
        case .clutteredBackground:
            return object.map { object in
                switch detail.stepSide {
                case .left: ("Step left so \(object) isn't behind \(subject)", "arrow.left")
                case .right: ("Step right so \(object) isn't behind \(subject)", "arrow.right")
                default: ("Step left or right so \(object) isn't behind \(subject)", "arrow.left.and.right")
                }
            }
        case .distractingEdges:
            guard let move = detail.cameraAway(from: detail.region), let edge = detail.region.edgeName else { return nil }
            return (object.map { "\(move.text) to drop \($0)" } ?? "\(move.text) to clear the \(edge)", move.symbol)
        case .subjectCutOff:
            guard let move = detail.cameraToward(detail.region) else { return nil }
            let cut = detail.thing == "the subjects" ? "the subjects" : (object ?? subject)
            return ("\(move.text), or step back, so \(cut) fits", move.symbol)
        case .tooMuchEmptySpace:
            return object.map { ("Step closer to \($0) to fill the frame", "arrow.up.forward") }
        case .linesDontLead:
            return object.map { ("Move until \($0) points at \(subject)", nil) }
        case .vanishingPointOffCentre:
            return detail.cameraToward(detail.region).map { ("\($0.text) so the lines meet in the middle", $0.symbol) }
        case .linesNotStraight:
            return object.map { ("Turn the phone until \($0) matches the grid", "rotate.right") }
        default:
            return nil
        }
    }

    /// A different way to fix the same problem, shown once the usual tip has been ignored a few times.
    func alternativeAdvice(for topic: AdviceTopic) -> Advice? {
        switch self {
        // The Shutter slider is only in the Exposure topic's bar. Slower speeds are to the right.
        case .underexposed, .backlitSubject:
            topic == .exposure
                ? Advice(action: "Drag the Shutter slider right for more light", why: "A slower shutter lets in more light, so the subject gets brighter.", symbol: "arrow.right")
                : nil
        case .overexposed, .highlightsClipped:
            topic == .exposure
                ? Advice(action: "Drag the Shutter slider left for less light", why: "A faster shutter lets in less light, keeping bright detail.", symbol: "arrow.left")
                : nil
        case .tooDark, .highISO:
            Advice(action: "Turn on Flash for a close subject", why: "Flash adds light where there isn't enough, keeping the photo clean.")
        case .cameraShaking, .slowShutter:
            Advice(action: "Lean on a wall or rest the phone on something", why: "A steady support stops blur better than steady hands.")
        case .subjectSoft:
            Advice(action: "Step back a little so the camera can focus", why: "Phones can't focus on things that are very close.")
        case .phoneTilted, .linesNotStraight:
            Advice(action: "Turn the phone until the level line turns green", why: "The level shows when the camera is straight.")
        case .subjectTooSmall, .tooMuchEmptySpace:
            Advice(action: "Tap a zoom button to zoom in", why: "Zooming in fills the frame without moving.")
        case .clutteredBackground:
            Advice(action: "Move closer so the subject hides the clutter", why: "The closer you are, the less background fits around the subject.")
        case .distractingEdges:
            Advice(action: "Step closer so the subject fills the edges", why: "Moving closer pushes distractions out of the frame.")
        case .noClearSubject:
            Advice(action: "Get close to one thing so it fills the middle", why: "Choosing one thing tells the viewer where to look.")
        case .shootingDown:
            Advice(action: "Hold the phone at chest height, level", why: "A lower camera treats the subject as an equal.")
        default:
            nil
        }
    }

    /// Past tense, for the one-line memory the coach carries into its next session.
    var accomplishment: String {
        switch self {
        case .underexposed, .overexposed: "balanced the exposure"
        case .highlightsClipped: "kept detail in the highlights"
        case .backlitSubject: "lit the subject from the front"
        case .tooDark, .highISO: "found better light"
        case .harshContrast: "softened the light"
        case .cameraShaking, .slowShutter: "held the camera steady"
        case .subjectSoft: "got the subject sharp"
        case .phoneTilted: "levelled the phone"
        case .shootingDown: "got down to eye level"
        case .pointingUp: "kept the lines straight"
        case .headCutOff, .tooMuchHeadroom: "fixed the headroom"
        case .subjectTooSmall, .tooMuchEmptySpace: "filled the frame"
        case .clutteredBackground: "cleaned up the background"
        case .distractingEdges: "cleared the edges"
        case .subjectCutOff: "fitted the whole subject in"
        case .noClearSubject: "picked a clear subject"
        case .horizonThroughMiddle: "moved the horizon off centre"
        case .linesDontLead: "made the lines lead to the subject"
        case .notSymmetric: "balanced both halves"
        case .vanishingPointOffCentre: "centred the vanishing point"
        case .linesNotStraight: "straightened the lines"
        case .noTriangle: "found a triangle"
        case .noClearVertex: "placed the vertex"
        case .notOverhead: "got directly overhead"
        case .layersNotStacked: "stacked the layers"
        case .subjectTooBig: "left space around the subject"
        case .jointsCropped: "cropped the portrait cleanly"
        }
    }

    /// The way a model-judged tip asks the person to move. The camera can measure this:
    /// stepping closer or zooming in makes the subject bigger in the frame, stepping back smaller.
    var asksToMove: DistanceMove? {
        switch self {
        case .subjectTooSmall: .closer
        case .subjectCutOff, .subjectTooBig: .back
        default: nil
        }
    }

    /// Tips only the model can judge. The camera can't check the fix itself, so these clear
    /// once the person has clearly reframed after the tip appeared.
    var isModelOnly: Bool {
        switch self {
        case .clutteredBackground, .distractingEdges, .subjectCutOff, .horizonThroughMiddle,
             .linesDontLead, .notSymmetric, .vanishingPointOffCentre, .noTriangle, .noClearVertex,
             .layersNotStacked, .jointsCropped:
            true
        default:
            false
        }
    }

    /// Problems the model can't see past, so it isn't asked while they're on screen.
    var blocksModel: Bool {
        self != .subjectTooSmall
    }

    private func tiltAdvice(_ tilt: Double?) -> Advice {
        let why = "A tilted horizon makes the whole photo feel off balance."
        guard let tilt else { return Advice(action: "Level the phone", why: why) }
        let degrees = max(1, Int(abs(tilt).rounded()))
        // A positive tilt means the phone is turned clockwise.
        return tilt > 0
            ? Advice(action: "Rotate the phone about \(degrees)° left to level it", why: why, symbol: "rotate.left")
            : Advice(action: "Rotate the phone about \(degrees)° right to level it", why: why, symbol: "rotate.right")
    }
}

/// Moving toward or away from the subject, measured by how much of the frame it fills.
nonisolated enum DistanceMove: Sendable {
    case closer, back

    /// How much the subject's size must change for the move to count. Big enough that
    /// the subject box jittering between frames doesn't count as a step.
    static let change = 1.5

    /// Whether the subject went from `start` to `now` (shares of the frame) the asked-for way.
    func isDone(from start: Double, to now: Double) -> Bool {
        switch self {
        case .closer: now >= start * Self.change
        case .back: now <= start / Self.change
        }
    }
}

/// Issues the model picks from. Only things that can't be measured.
@Generable
enum VisualIssue: String, CaseIterable {
    case none
    case clutteredBackground
    case distractingEdges
    case subjectCutOff
    case noClearSubject
    case tooMuchEmptySpace
    case horizonThroughMiddle
    case linesDontLead
    case notSymmetric
    case vanishingPointOffCentre
    case linesNotStraight
    case noTriangle
    case noClearVertex
    case notOverhead
    case layersNotStacked
    case subjectTooBig
    case jointsCropped

    nonisolated var coachIssue: CoachIssue? {
        self == .none ? nil : CoachIssue(rawValue: rawValue)
    }

    /// The composition styles this issue belongs to, or nil for issues that apply to any framing.
    var styles: Set<CompositionGuide>? {
        switch self {
        case .linesDontLead: [.leadingLines, .onePointPerspective]
        case .notSymmetric: [.symmetry]
        case .vanishingPointOffCentre: [.onePointPerspective]
        case .linesNotStraight: [.leadingLinesAligning, .onePointPerspective, .symmetry]
        case .noTriangle: [.triangle]
        case .notOverhead: [.tableTop90]
        case .layersNotStacked: [.compression]
        case .subjectTooBig: [.negativeSpace]
        case .jointsCropped: [.halfBodyPortrait]
        default: nil
        }
    }
}

/// What the model returns for a live frame.
@Generable
struct CoachJudgement {
    @Guide(description: "The single biggest problem a beginner should fix for the chosen topic, or none if it already works")
    var issue: VisualIssue

    @Guide(description: "Where in the frame the problem is. Use whole if it is everywhere or the issue is none")
    var region: FrameRegion

    @Guide(description: "The thing causing the problem, 1 to 3 plain words like \"the lamp post\". Call one person the subject and several people the subjects. Empty if the issue is none")
    var thing: String

    @Guide(description: "One thing that already works in the photo, 2 to 5 words. Call one person the subject and several people the subjects. Empty if nothing stands out")
    var strength: String
}

/// Turns measurements into issues for each topic. Pure functions, so they're easy to test.
nonisolated enum CoachRules {
    /// Below this the subject counts as soft. Measured on a 256-pixel-wide copy of the frame.
    static let softThreshold = 40.0
    /// Degrees of tilt worth pointing out. Nobody can hold a phone perfectly level, so small tilts are fine.
    static let tiltThreshold = 4.0
    /// Once tilt is being pointed out, it counts as fixed below this: close enough by hand, not perfect.
    static let tiltFixedThreshold = 3.0
    /// Average turning speed, in radians a second, above which hand shake is likely to blur the photo.
    static let shakeThreshold = 0.25
    /// How much the view must change (see `SceneAnalysis.reframeAmount`) to count as a reframe.
    static let reframeThreshold = 0.12
    /// Share of the frame above which the subject is too big for the Negative Space style.
    static let negativeSpaceLimit = 0.12
    /// Model issues the coach never uses: "get closer" tips it can't check (getting closer is
    /// measured instead), the Negative Space size, which is measured too, and the vertex tip,
    /// whose Single and Double Vertex styles were removed.
    static let unusedModelIssues: Set<VisualIssue> = [.noClearSubject, .tooMuchEmptySpace, .subjectTooBig, .noClearVertex]
    /// Below this share of edges (see `SceneAnalysis.backgroundBusyness`) the background is
    /// measurably plain, so the model's "cluttered background" isn't believed.
    static let plainBackgroundLimit = 0.08
    /// Surfaces that make a clean background, not a distraction, whatever the model says,
    /// unless the background measures clearly busy (a window onto a busy street, say).
    static let plainSurfaces: Set<String> = [
        "wall", "walls", "door", "doors", "glass", "window", "windows", "floor", "ceiling",
        "sky", "curtain", "curtains", "blind", "blinds", "background", "panel", "panels",
    ]

    /// Told to the model wherever it judges a photo, so the live coach and the photo review agree.
    static let plainSurfaceRule = """
        Plain surfaces such as walls, doors, glass, windows, floors and sky are a clean background, not a distraction. \
        Only report clutteredBackground for a separate object, like a pole, sign or person, that sticks out from right behind the subject.
        """

    /// Whether the model's praise says something the camera measured as wrong, like "Bright light"
    /// on a dark frame. Wrong praise makes all the advice harder to trust, so it isn't shown.
    static func contradicts(strength: String, analysis a: SceneAnalysis) -> Bool {
        let words = Set(strength.lowercased().split { !$0.isLetter }.map(String.init))
        func mentions(_ keys: Set<String>) -> Bool { !words.isDisjoint(with: keys) }
        let lightIssues = issues(for: .exposure, in: a) + issues(for: .light, in: a)
        if mentions(["light", "lighting", "lit", "bright", "brightness", "exposure", "exposed"]), !lightIssues.isEmpty {
            return true
        }
        if mentions(["sharp", "sharpness", "focus", "focused", "crisp", "clear"]), a.subjectSharpness < softThreshold {
            return true
        }
        if mentions(["level", "straight", "horizon"]), isTilted(a.tilt, alreadyShown: false) {
            return true
        }
        if mentions(["background", "clean", "simple", "uncluttered", "tidy"]),
           let busyness = a.backgroundBusyness, busyness >= plainBackgroundLimit * 2 {
            return true
        }
        return false
    }

    /// Whether a "next time" idea from the model blames a plain surface, like "avoid the glass doors".
    static func blamesPlainSurface(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let blames: Set<String> = ["remove", "avoid", "distract", "distracting", "distraction", "hide", "clutter", "cluttered"]
        return !words.isDisjoint(with: plainSurfaces) && !words.isDisjoint(with: blames)
    }

    /// Words the model and Vision use for the same kind of thing, so "the lamp post" matches
    /// Vision's "streetlight". Each set is one kind of thing.
    static let objectSynonyms: [Set<String>] = [
        ["post", "pole", "lamp", "lamppost", "streetlight", "light", "pillar", "column"],
        ["car", "cars", "vehicle", "automobile", "truck", "van", "bus"],
        ["plant", "tree", "bush", "shrub", "foliage", "leaf", "leaves", "hedge", "flower", "branch"],
        ["sign", "signboard", "billboard", "poster", "banner", "signage"],
        ["bin", "trash", "garbage", "can", "dumpster", "rubbish"],
        ["chair", "seat", "bench", "stool", "sofa", "couch"],
        ["table", "desk", "counter"],
        ["bottle", "cup", "mug", "glass", "drink", "drinkware", "beverage"],
        ["fence", "railing", "rail", "barrier", "gate"],
        ["wire", "cable", "cord", "wires", "cables"],
        ["bag", "backpack", "handbag", "luggage"],
        ["bike", "bicycle", "cycle"],
        ["screen", "monitor", "television", "tv", "computer", "laptop"],
    ]

    /// Whether the model's verdict fits what the camera measured. The model sometimes calls plain
    /// glass doors or a wall a distraction, so background verdicts must agree with the measurement.
    static func believes(_ issue: CoachIssue, detail: IssueDetail?, analysis: SceneAnalysis) -> Bool {
        guard issue == .clutteredBackground || issue == .distractingEdges else { return true }
        let busyness = analysis.backgroundBusyness
        let namesPlainSurface = detail?.thing.map { name in
            name.split(separator: " ").contains { plainSurfaces.contains(String($0)) }
        } ?? false
        if namesPlainSurface {
            // Only a clearly busy background lets a plain-surface name through.
            return (busyness ?? 0) >= plainBackgroundLimit * 2
        }
        if issue == .clutteredBackground, let busyness, busyness < plainBackgroundLimit {
            return false
        }
        return true
    }

    /// Topics where the model adds judgement the measurements can't give. Only Composition looks
    /// beyond the subject, at the background and other objects; every other topic is about the
    /// subject and the camera alone, so it is measured only.
    static func usesModel(_ topic: AdviceTopic) -> Bool {
        topic == .composition
    }

    /// Visual issues that make sense to report for a topic and the chosen composition styles.
    @MainActor
    static func allows(_ issue: VisualIssue, for topic: AdviceTopic, styles: Set<CompositionGuide> = []) -> Bool {
        guard !unusedModelIssues.contains(issue) else { return false }
        switch topic {
        case .composition:
            // Composition is about framing; rotating or angling the phone belongs to Angle & Perspective.
            guard ![.linesNotStraight, .notOverhead].contains(issue) else { return false }
            // Style issues only count when one of their styles is being practised.
            guard let owners = issue.styles else { return true }
            return !owners.isDisjoint(with: styles)
        default:
            // Only Composition judges the background and other objects.
            return false
        }
    }

    /// Whether the tilt is worth pointing out. Once shown, it stays until the phone is clearly level.
    static func isTilted(_ tilt: Double?, alreadyShown: Bool) -> Bool {
        guard let tilt else { return false }
        return abs(tilt) >= (alreadyShown ? tiltFixedThreshold : tiltThreshold)
    }

    /// Measured issues for a topic, most important first. `tiltShown` keeps a tilt warning on screen
    /// until the phone is clearly level.
    static func issues(
        for topic: AdviceTopic,
        in a: SceneAnalysis,
        tiltShown: Bool = false,
        styles: Set<CompositionGuide> = []
    ) -> [CoachIssue] {
        var found: [CoachIssue] = []
        let offset = a.readings.exposureOffset ?? 0
        let iso = a.readings.iso ?? 0
        switch topic {
        case .exposure:
            if offset < -0.7 || a.brightness < 0.22 {
                found.append(.underexposed)
            } else if offset > 0.7 || a.brightness > 0.8 {
                found.append(.overexposed)
            }
            // Once Exposure has been pulled down a full stop, what's still white is a lamp or the
            // sun, which no setting can fix, so the tip counts as done.
            if a.highlightClip > 0.04, !found.contains(.overexposed), a.readings.exposureBias > -1 {
                found.append(.highlightsClipped)
            }
            // Brightening lifts the background too, so the gap never closes. The fix is done
            // once the subject itself is bright enough.
            if a.isBacklit, (a.subjectBrightness ?? 0) < 0.4 { found.append(.backlitSubject) }
        case .light:
            // Night Mode and Flash mostly change the saved photo, not the preview, so turning
            // them on counts as following the tip.
            let addsLight = a.readings.isNightModeOn || a.readings.isFlashOn
            if a.brightness < 0.2 || iso > 1600, !addsLight { found.append(.tooDark) }
            if a.isBacklit { found.append(.backlitSubject) }
            if a.highlightClip > 0.04, a.shadowClip > 0.1 { found.append(.harshContrast) }
            if iso > 800, !found.contains(.tooDark), !addsLight { found.append(.highISO) }
        case .focus:
            // Shake blurs everything, so fix it before blaming the focus.
            if let shake = a.shake, shake >= shakeThreshold { found.append(.cameraShaking) }
            if a.subjectSharpness < softThreshold { found.append(.subjectSoft) }
            // A slow shutter is only a problem while the phone moves. The tip is to hold still,
            // and holding still is what clears it; the shutter speed itself can't be changed by hand.
            let isSteady = a.shake.map { $0 < shakeThreshold / 2 } ?? false
            if let seconds = a.readings.exposureSeconds, seconds > 1.0 / 30,
               !found.contains(.cameraShaking), !isSteady {
                found.append(.slowShutter)
            }
        case .anglePerspective:
            if isTilted(a.tilt, alreadyShown: tiltShown) { found.append(.phoneTilted) }
            if let pitch = a.pitch {
                // Wide limits, so holding the phone near one doesn't flick the tip on and off.
                if pitch < -35, a.personCount > 0 { found.append(.shootingDown) }
                if pitch > 25 { found.append(.pointingUp) }
            }
        case .composition:
            // Everyone counts: any head at the top edge is cut off, and headroom is
            // measured above the highest head, so it works for groups too.
            if a.headAtTopEdge {
                found.append(.headCutOff)
            } else if let topmost = a.faces.min(by: { $0.minY < $1.minY }), topmost.minY > 0.35 {
                found.append(.tooMuchHeadroom)
            }
            if let subject = a.subject, subject.width * subject.height < 0.02, !a.isWideScene { found.append(.subjectTooSmall) }
            // Negative Space wants a small subject in lots of empty space.
            if styles.contains(.negativeSpace), let subject = a.subject,
               Double(subject.width * subject.height) > negativeSpaceLimit {
                found.append(.subjectTooBig)
            }
        }
        return found
    }

    /// Things that are measurably good for a topic, each 2 to 4 words.
    static func strengths(for topic: AdviceTopic, in a: SceneAnalysis, tiltShown: Bool = false) -> [String] {
        let problems = issues(for: topic, in: a, tiltShown: tiltShown)
        var good: [String] = []
        switch topic {
        case .exposure:
            if !problems.contains(.underexposed), !problems.contains(.overexposed) { good.append("Balanced brightness") }
            if a.highlightClip < 0.01 { good.append("Highlights have detail") }
        case .light:
            if !a.isBacklit, a.brightness >= 0.2 { good.append("Light reaches the subject") }
            if a.highlightClip < 0.02, a.shadowClip < 0.05 { good.append("Soft, even light") }
        case .focus:
            if a.subjectSharpness >= softThreshold { good.append("Subject is sharp") }
            if let shake = a.shake, shake < shakeThreshold / 2 { good.append("Steady hands") }
        case .anglePerspective:
            if a.tilt != nil, !problems.contains(.phoneTilted) { good.append("Phone is level") }
        case .composition:
            // Other framing strengths come from the model and the target guide, not from how the phone is held.
            if !a.faces.isEmpty, !problems.contains(.headCutOff), !problems.contains(.tooMuchHeadroom) {
                good.append("Good headroom")
            }
        }
        return good
    }
}
