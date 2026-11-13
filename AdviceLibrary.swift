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
}

/// Where in the frame the model saw the problem.
@Generable
enum FrameRegion: String {
    case left, right, top, bottom, centre, background, whole
}

/// What the model said about where the problem is and what causes it.
struct IssueDetail: Equatable {
    let region: FrameRegion
    /// A short, cleaned-up name like "the lamp post", or nil when the model's words weren't usable.
    let thing: String?

    init(region: FrameRegion, rawThing: String) {
        self.region = region
        self.thing = Self.cleanedThing(rawThing)
    }

    /// Words that describe a person. The coach never describes people, so these become "the subject".
    private static let personWords: Set<String> = [
        "man", "woman", "boy", "girl", "person", "people", "guy", "lady", "child", "kid", "baby",
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

    /// How to point the camera away from this side of the frame.
    nonisolated var turnAway: (text: String, symbol: String)? {
        switch self {
        case .left: FrameRegion.right.turnToward
        case .right: FrameRegion.left.turnToward
        case .top: FrameRegion.bottom.turnToward
        case .bottom: FrameRegion.top.turnToward
        default: nil
        }
    }
}

extension CoachIssue {
    /// Short, beginner-friendly advice that names the controls in the topic's top bar.
    /// With a `detail` from the model, the action names what to move away from and which way.
    func advice(for topic: AdviceTopic, analysis: SceneAnalysis? = nil, detail: IssueDetail? = nil) -> Advice {
        let general = sceneAdvice(for: analysis?.scene) ?? generalAdvice(for: topic, analysis: analysis)
        guard let detail, let specific = specificAction(detail) else { return general }
        return Advice(action: specific.text, why: general.why, symbol: specific.symbol ?? general.symbol)
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
            Advice(action: "Tilt down so the eyes sit near the top third", why: "Too much space above the head makes the subject look sunk.", symbol: "arrow.down")
        case .subjectTooSmall:
            Advice(action: "Step closer or tap a zoom button", why: "Filling the frame makes it clear what the photo is about.")
        case .clutteredBackground:
            Advice(action: "Step sideways for a cleaner background", why: "A busy background pulls the eye away from the subject.")
        case .distractingEdges:
            Advice(action: "Reframe to drop distractions at the edges", why: "Bright things near the edge drag the eye out of the photo.")
        case .subjectCutOff:
            Advice(action: "Step back so the whole subject fits", why: "Cropping through the subject looks accidental.")
        case .noClearSubject:
            Advice(action: "Pick one subject and move closer to it", why: "A photo needs one clear thing to look at.")
        case .tooMuchEmptySpace:
            Advice(action: "Step closer to fill the frame", why: "Empty space only helps when it gives the subject room to breathe.")
        case .horizonThroughMiddle:
            Advice(action: "Reframe so the horizon sits on a third line", why: "A horizon across the middle splits the photo in two.")
        case .linesDontLead:
            Advice(action: "Move so the lines run toward the subject", why: "Lines pull the eye along them, so they should end at what matters.")
        case .notSymmetric:
            Advice(action: "Step sideways until both halves mirror each other", why: "Symmetry works when both halves closely match.")
        case .vanishingPointOffCentre:
            Advice(action: "Move until the lines meet in the middle", why: "Lines meeting near the centre give the deepest look.")
        case .linesNotStraight:
            Advice(action: "Turn the phone until the lines match the grid", why: "Straight lines that lean make a photo look careless.")
        case .noTriangle:
            Advice(action: "Reframe so three key things form a triangle", why: "A triangle leads the eye around the photo and feels stable.")
        case .noClearVertex:
            Advice(action: "Put the point where lines meet on a third", why: "Where lines meet is a natural place for the eye to rest.")
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
            Advice(action: "Put the horizon on the bottom third for more sky", why: "Giving the sky or the land two thirds makes a clear choice.")
        case (.subjectTooSmall, .nature):
            Advice(action: "Step closer, or tap 2× to fill the frame", why: "Small details in nature only shine when they fill the photo.")
        case (.harshContrast, .people):
            Advice(action: "Move the subject into shade for soft light", why: "Shade stops squinting and harsh shadows on the face.")
        case (.tooDark, .food), (.highISO, .food):
            Advice(action: "Move the plate next to a window", why: "Soft window light shows the texture of food.")
        default:
            nil
        }
    }

    /// Advice that uses what the model saw, or nil when the detail doesn't help for this issue.
    private func specificAction(_ detail: IssueDetail) -> (text: String, symbol: String?)? {
        // "The subject" can't be a distraction in the background or at the edge.
        let object = detail.thing == "the subject" ? nil : detail.thing
        switch self {
        case .clutteredBackground:
            return object.map { ("Step sideways so \($0) isn't behind the subject", "arrow.left.and.right") }
        case .distractingEdges:
            guard let move = detail.region.turnAway, let edge = detail.region.edgeName else { return nil }
            return (object.map { "\(move.text) to drop \($0)" } ?? "\(move.text) to clear the \(edge)", move.symbol)
        case .subjectCutOff:
            guard let move = detail.region.turnToward else { return nil }
            return ("\(move.text), or step back, so \(detail.thing ?? "the subject") fits", move.symbol)
        case .tooMuchEmptySpace:
            return object.map { ("Step closer to \($0) to fill the frame", "arrow.up.forward") }
        case .linesDontLead:
            return object.map { ("Move until \($0) points at the subject", nil) }
        case .vanishingPointOffCentre:
            return detail.region.turnToward.map { ("\($0.text) so the lines meet in the middle", $0.symbol) }
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
        case .noClearVertex: [.singleVertex, .doubleVertex]
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

    @Guide(description: "The thing causing the problem, 1 to 3 plain words like \"the lamp post\". Call any person the subject. Empty if the issue is none")
    var thing: String

    @Guide(description: "One thing that already works in the photo, 2 to 5 words. Call any person the subject. Empty if nothing stands out")
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

    /// Topics where the model adds judgement the measurements can't give.
    static func usesModel(_ topic: AdviceTopic) -> Bool {
        topic == .composition || topic == .anglePerspective
    }

    /// Visual issues that make sense to report for a topic and the chosen composition styles.
    @MainActor
    static func allows(_ issue: VisualIssue, for topic: AdviceTopic, styles: Set<CompositionGuide> = []) -> Bool {
        switch topic {
        case .composition:
            // Composition is about framing; rotating or angling the phone belongs to Angle & Perspective.
            guard ![.linesNotStraight, .notOverhead].contains(issue) else { return false }
            // Style issues only count when one of their styles is being practised.
            guard let owners = issue.styles else { return true }
            return !owners.isDisjoint(with: styles)
        case .anglePerspective:
            return issue == .clutteredBackground || issue == .none
        default:
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
    static func issues(for topic: AdviceTopic, in a: SceneAnalysis, tiltShown: Bool = false) -> [CoachIssue] {
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
                if pitch < -35, !a.faces.isEmpty { found.append(.shootingDown) }
                if pitch > 25 { found.append(.pointingUp) }
            }
        case .composition:
            if let subject = a.subject, subject.width * subject.height < 0.02 { found.append(.subjectTooSmall) }
        case .subjectPosition:
            if let face = a.faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                if face.minY < 0.02 {
                    found.append(.headCutOff)
                } else if a.faces.count == 1, face.minY > 0.35 {
                    found.append(.tooMuchHeadroom)
                }
            }
            if let subject = a.subject, subject.width * subject.height < 0.02 { found.append(.subjectTooSmall) }
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
            // Framing strengths come from the model and the green box, not from how the phone is held.
            break
        case .subjectPosition:
            if !a.faces.isEmpty, !problems.contains(.headCutOff), !problems.contains(.tooMuchHeadroom) {
                good.append("Good headroom")
            }
        }
        return good
    }
}
