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
    case tooDark, harshContrast, highISO, faceHalfInShadow, sunInFrame
    case subjectInShadow, subjectTooBright
    case cameraShaking, subjectSoft, slowShutter
    case phoneTilted, shootingDown, pointingUp
    case headCutOff, tooMuchHeadroom, subjectTooSmall
    // Judged by the model, because they can't be measured.
    case clutteredBackground, distractingEdges, subjectCutOff, noClearSubject
    case tooMuchEmptySpace, horizonThroughMiddle
    // Judged by the model against a chosen composition style.
    case linesDontLead, notSymmetric, vanishingPointOffCentre, linesNotStraight
    case noTriangle, noClearVertex, notOverhead, layersNotStacked, subjectTooBig, jointsCropped
    // Judged by the model in Light: the quality of the light, which brightness can't show.
    case hardShadowsOnSubject, flatLight, patchyLight, sunGlare
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
    /// Who has to act for a light tip: the photographer, the subject, or a setting. Shown on the
    /// card and the viewfinder, so it's never unclear who should move.
    var mover: Mover? = nil
    /// Where the light comes from, as measured, for the light marker on the viewfinder.
    var lightSide: LightSide? = nil
    /// A setting that follows the tip in one tap.
    var quickFix: QuickFix? = nil

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

/// Who a light tip asks to act.
nonisolated enum Mover: String, Sendable, Equatable {
    case photographer, subject, settings

    var label: String {
        switch self {
        case .photographer: "You move"
        case .subject: "Subject moves"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .photographer: "figure.walk"
        case .subject: "person.fill"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// A setting a tip can change in one tap.
nonisolated enum QuickFix: Equatable, Sendable {
    case nightMode, flash, meterOnSubject, brighten, darken, raw

    var title: String {
        switch self {
        case .nightMode: "Turn on Night Mode"
        case .flash: "Turn on Flash"
        case .meterOnSubject: "Set brightness for the subject"
        case .brighten: "Brighten"
        case .darken: "Darken"
        case .raw: "Shoot RAW"
        }
    }

    var systemImage: String {
        switch self {
        case .nightMode: "moon.fill"
        case .flash: "bolt.fill"
        case .meterOnSubject: "viewfinder"
        case .brighten: "sun.max.fill"
        case .darken: "sun.min.fill"
        case .raw: "r.square"
        }
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
        if topic == .light, let analysis {
            // Light tips that move someone say who, and keep the subject and scenery in the shot.
            var light = lightAdvice(analysis, keepsFraming: keepsPlacement) ?? lightGeneral(for: analysis, detail: detail)
            light.quickFix = light.quickFix ?? quickFix(for: analysis)
            light.mover = light.mover ?? lightMover(for: analysis)
            return light
        }
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

    /// The light tip without a "who moves" rule: the scene's wording, or else the general one.
    private func lightGeneral(for analysis: SceneAnalysis, detail: IssueDetail?) -> Advice {
        let scene = analysis.scenes.lazy.compactMap { sceneAdvice(for: $0) }.first
        return scene ?? generalAdvice(for: .light, analysis: analysis)
    }

    /// Light tips that need someone to move, worked out so nobody is asked to do what they can't and
    /// what's being photographed stays in the shot: a setting balances the light when the scenery
    /// behind a person matters, the photographer walks around a subject with nothing important behind
    /// it, and a building or view gets a setting or a small turn, since neither it nor the sun can
    /// move. Light that only the weather or the time of day could change isn't raised at all (see
    /// `CoachRules.canFix`). A side is only named when the measurements agree on it.
    /// With `keepsFraming`, the framing is already lined up, so the camera never moves.
    /// Nil when the usual wording already fits.
    func lightAdvice(_ a: SceneAnalysis, keepsFraming: Bool) -> Advice? {
        let general = generalAdvice(for: .light, analysis: a)
        let side = a.lightSide?.sideWord
        let person = a.personCount > 0
        // Flash only reaches a few metres: a face this big in the frame is close enough.
        let faceIsClose = (a.faces.map(\.height).max() ?? 0) >= 0.2
        func tip(_ mover: Mover, _ action: String, fix: QuickFix? = nil) -> Advice {
            let why = keepsFraming && mover != .photographer ? "This keeps your framing. \(general.why)" : general.why
            return Advice(action: action, why: why, mover: mover, lightSide: a.lightSide, quickFix: fix)
        }

        switch self {
        case .faceHalfInShadow:
            // On the front camera the subject is the person holding the phone.
            if a.readings.isFrontCamera {
                return tip(.subject, side.map { "Turn your face toward the light on your \($0)" } ?? "Turn your face toward the light")
            }
            return tip(.subject, side.map { "Ask them to turn toward the light on your \($0)" } ?? "Ask them to turn their face toward the light")

        case .backlitSubject, .sunInFrame:
            if a.readings.isFrontCamera {
                // Turning around would lose what's behind you, like a landmark, or undo the framing.
                if a.sceneryMatters || keepsFraming {
                    return faceIsClose
                        ? tip(.settings, "Turn on Flash to light your face", fix: .flash)
                        : tip(.settings, "Tap your face so the camera brightens you", fix: .meterOnSubject)
                }
                return tip(.subject, "Turn around so the light falls on your face")
            }
            if a.isFixedScene {
                // Neither a building nor the sun can move. A sun right at the edge can be dropped
                // with a small turn; otherwise something nearby can hide it, or a setting saves the sky.
                guard self == .sunInFrame, let spot = a.sunSpot else {
                    return tip(.settings, "Tap the darker area so the camera brightens it", fix: .meterOnSubject)
                }
                if keepsFraming {
                    return tip(.settings, "Darken the photo a little to keep the sky", fix: .darken)
                }
                let atSide = spot.minX < 0.15 || spot.maxX > 0.85
                if atSide, let away = LightSide.of(spot).opposite.sideWord {
                    return tip(.photographer, "Turn slightly \(away) so the sun just leaves the frame")
                }
                return tip(.photographer, "Stand so a tree or roof hides the sun", fix: .darken)
            }
            if person, a.sceneryMatters || keepsFraming {
                // The scenery behind them matters, so the camera stays and the light is added or balanced.
                return faceIsClose
                    ? tip(.settings, "Turn on Flash to light their face", fix: .flash)
                    : tip(.settings, "Tap their face so the camera brightens them", fix: .meterOnSubject)
            }
            if keepsFraming {
                return tip(.settings, "Tap the subject so the camera brightens it", fix: .meterOnSubject)
            }
            // The light is in front of the camera. Walking around the subject toward its side
            // turns light from behind into light from the side, then the front.
            let them = person ? "them" : "the subject"
            // While walking, the subject must stay in the shot: if it's slipping off an edge, say so first.
            if a.subjectTouchesEdge {
                return tip(.photographer, "Keep \(them) in frame: turn back toward \(person ? "them" : "it")")
            }
            if let side {
                return tip(.photographer, "Walk around \(them) to your \(side), keeping \(person ? "them" : "it") centred")
            }
            return tip(.photographer, "Walk around \(them) until the light is beside you")

        case .hardShadowsOnSubject, .harshContrast:
            if a.readings.isFrontCamera {
                return a.sceneryMatters
                    ? tip(.subject, "Step into shade, keeping the view behind you")
                    : tip(.subject, "Step into shade, or face a window")
            }
            return nil

        case .patchyLight:
            if a.readings.isFrontCamera {
                return a.sceneryMatters
                    ? tip(.subject, "Step fully into shade, keeping the view behind you")
                    : tip(.subject, "Step fully into the shade")
            }
            return nil

        case .flatLight:
            if a.readings.isFrontCamera {
                // Turning a long way round would lose what's behind you; a small head turn is enough.
                return a.sceneryMatters
                    ? tip(.subject, "Turn your head slightly toward the light")
                    : tip(.subject, "Turn so the light comes from your side")
            }
            // The usual tip has the photographer walk round; with the framing kept, the subject
            // turns instead. A view, which only gets side light when the sun moves, never gets here.
            // When something else is in the shot, the camera stays and the person turns instead.
            if keepsFraming || (person && a.sceneryMatters) {
                return person
                    ? tip(.subject, "Ask them to turn so light falls from the side")
                    : tip(.subject, "Turn it so the light falls on its side")
            }
            return nil

        case .sunGlare:
            // Shading the lens fixes glare without moving the camera, so nothing leaves the shot.
            return keepsFraming || a.readings.isFrontCamera || a.sceneryMatters
                ? tip(.photographer, "Shade the lens with your hand")
                : nil

        case .subjectInShadow:
            if a.readings.isFrontCamera {
                return a.sceneryMatters || keepsFraming
                    ? tip(.settings, "Tap your face so the camera brightens you", fix: .meterOnSubject)
                    : tip(.subject, "Step into the light")
            }
            // A view can't move, and a kept framing mustn't: the camera brightens the subject instead.
            if !a.canMoveSubject || keepsFraming {
                return tip(.settings, "Tap the subject so the camera brightens it", fix: .meterOnSubject)
            }
            return person ? tip(.subject, "Ask them to step into the light") : tip(.subject, "Move the subject into the light")

        default:
            return nil
        }
    }

    /// Who acts on the other light tips.
    private func lightMover(for a: SceneAnalysis) -> Mover? {
        switch self {
        // Food in the dark is carried to a window rather than fixed with a setting.
        case .tooDark, .highISO: a.scene == .food ? .subject : .settings
        case .underexposed, .overexposed, .highlightsClipped, .subjectTooBright: .settings
        case .subjectInShadow: .subject
        case .harshContrast, .hardShadowsOnSubject, .patchyLight, .faceHalfInShadow: .subject
        case .flatLight, .backlitSubject, .sunInFrame, .sunGlare: .photographer
        default: nil
        }
    }

    /// The setting that follows a light tip in one tap, when there is one and it isn't on already.
    private func quickFix(for a: SceneAnalysis) -> QuickFix? {
        switch self {
        case .tooDark, .highISO:
            return a.readings.isNightModeOn ? nil : .nightMode
        case .underexposed:
            return .brighten
        case .overexposed, .highlightsClipped:
            return .darken
        case .subjectTooBright:
            return .meterOnSubject
        default:
            return nil
        }
    }

    private func generalAdvice(for topic: AdviceTopic, analysis: SceneAnalysis?) -> Advice {
        switch self {
        case .underexposed:
            Advice(action: "Tap the subject, then drag up to brighten", why: "A dark photo hides detail and looks muddy.", symbol: "arrow.up")
        case .overexposed:
            Advice(action: "Tap the subject, then drag down to darken", why: "Slightly dark beats too bright: lost highlights can't come back.", symbol: "arrow.down")
        case .highlightsClipped:
            Advice(action: "Tap the bright area to keep its detail", why: "Pure white areas have no detail left, even in editing.")
        case .backlitSubject:
            Advice(action: "Tap the subject so the camera brightens it", why: "Bright light behind the subject makes the camera darken it.")
        case .tooDark:
            Advice(action: "Tap Night Mode, or move nearer a light", why: "In dim light the camera adds grain and blur.")
        case .harshContrast:
            Advice(action: "Move into open shade or softer light", why: "Harsh light makes deep shadows and hot spots.")
        case .highISO:
            Advice(action: "Turn on Night Mode, or find brighter light", why: "Low light forces high ISO, which adds grainy noise.")
        case .faceHalfInShadow:
            Advice(action: "Turn the face toward the light to fill the shadow", why: "Half a face in deep shadow hides an eye and looks gloomy.")
        case .subjectInShadow:
            Advice(action: "Move the subject into the light", why: "The camera exposes for the whole scene, leaving the subject dark.")
        case .subjectTooBright:
            Advice(action: "Tap the subject so it isn't too bright", why: "A bright subject on a dark background loses its detail first.")
        case .sunInFrame:
            Advice(action: "Stand so a tree or roof hides the sun", why: "Shooting into the sun blows out the sky and darkens the subject.")
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
        case .hardShadowsOnSubject:
            Advice(action: "Move into open shade or next to a window", why: "Direct sun or a bare bulb casts hard, dark shadows on the subject.")
        case .flatLight:
            Advice(action: "Turn so the light comes from the side", why: "Side light shows shape and texture; light from straight ahead looks flat.")
        case .patchyLight:
            Advice(action: "Move so the subject is fully in light or shade", why: "Spots of sun and shadow across the subject look messy.")
        case .sunGlare:
            Advice(action: "Shade the lens with your hand, or turn slightly away", why: "Sun just outside the frame washes the photo out with haze and flare.")
        }
    }

    /// Wording for the kind of photo being taken, where the usual tip doesn't fit it well.
    private func sceneAdvice(for scene: SceneType?) -> Advice? {
        switch (self, scene) {
        case (.clutteredBackground, .food):
            Advice(action: "Move it so only the table is behind it", why: "A plain surface keeps the eye on the food.")
        case (.horizonThroughMiddle, .landscape):
            Advice(action: "Put the horizon on the bottom third for more sky", why: "Giving the sky or the land two thirds makes a clear choice.", thirdsLines: [.bottom])
        case (.subjectTooSmall, .nature):
            Advice(action: "Step closer, or tap 2× to fill the frame", why: "Small details in nature only shine when they fill the photo.")
        case (.harshContrast, .people):
            Advice(action: "Move the subject into shade for soft light", why: "Shade stops squinting and harsh shadows on the face.")
        case (.tooDark, .food), (.highISO, .food):
            Advice(action: "Move the food next to a window", why: "Soft window light shows the texture of food.")
        case (.distractingEdges, .food):
            Advice(action: "Move cups and phones out of the frame", why: "Only what belongs to the meal should share the plate's space.")
        case (.subjectCutOff, .people):
            Advice(action: "Step back so you don't crop at joints", why: "Cutting at the neck, elbows or knees looks like a mistake.")
        case (.clutteredBackground, .people):
            Advice(action: "Move them a few steps away from the background", why: "Distance softens the background and lifts the subject off it.")
        case (.distractingEdges, .city):
            Advice(action: "Step closer to drop cars and signs at the edges", why: "Busy streets crowd the edges and pull the eye out.")
        case (.linesDontLead, .city):
            Advice(action: "Stand so the street runs toward the subject", why: "Streets and kerbs are lines that lead the eye.")
        case (.hardShadowsOnSubject, .people):
            Advice(action: "Move them into shade, or face them toward a window", why: "Soft light stops squinting and dark shadows under the eyes.")
        case (.hardShadowsOnSubject, .food):
            Advice(action: "Move the food out of direct light, beside a window", why: "Soft window light shows texture without harsh shadows.")
        case (.flatLight, .food):
            Advice(action: "Put the window to the side of the plate", why: "Side light makes food look fresh, with shape and texture.")
        case (.clutteredBackground, .nature):
            Advice(action: "Change your angle so a plain area is behind it", why: "A plain background makes a flower or animal stand out.")
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
    /// In Light, with the scene known, it follows the same limits as the usual tip: nil when it would
    /// ask for a move that isn't possible, otherwise with who acts and its one-tap fix.
    func alternativeAdvice(for topic: AdviceTopic, analysis: SceneAnalysis? = nil, keepsPlacement: Bool = false) -> Advice? {
        guard var alternative = baseAlternative else { return nil }
        guard topic == .light, let a = analysis else { return alternative }
        switch self {
        case .backlitSubject:
            // "Turn so the light falls on the subject's front" moves the camera or the subject, which
            // a view, a kept framing, or a selfie in front of a landmark can't do.
            guard !a.isFixedScene, !keepsPlacement, !a.readings.isFrontCamera, !a.sceneryMatters else { return nil }
            alternative.mover = .photographer
            alternative.lightSide = a.lightSide
        case .sunInFrame:
            // Zooming in changes the framing.
            guard !keepsPlacement else { return nil }
        case .hardShadowsOnSubject, .patchyLight:
            // A sheet can't shade a building or a view.
            guard a.canMoveSubject else { return nil }
        case .underexposed, .overexposed, .highlightsClipped:
            // Moving toward a window or into shade isn't possible for a view.
            guard !a.isFixedScene else { return nil }
            alternative.mover = .subject
        case .tooDark, .highISO, .subjectInShadow:
            // Flash only reaches a close subject, never a view.
            guard !a.isFixedScene else { return nil }
            alternative.mover = .settings
            alternative.quickFix = a.readings.isFlashOn ? nil : .flash
        default:
            break
        }
        return alternative
    }

    /// The other way to fix each problem, before any scene is considered.
    private var baseAlternative: Advice? {
        switch self {
        case .underexposed:
            Advice(action: "Move toward a window or brighter light", why: "More light on the subject beats brightening a dark photo.")
        case .backlitSubject:
            Advice(action: "Turn so the light falls on the subject's front", why: "Light from behind leaves the subject in shadow.")
        case .overexposed, .highlightsClipped:
            Advice(action: "Move into shade, or wait for softer light", why: "Softer light keeps bright areas from turning pure white.")
        case .tooDark, .highISO, .subjectInShadow:
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
        case .hardShadowsOnSubject, .patchyLight:
            Advice(action: "Wait for a cloud, or hold up a white sheet to soften the light", why: "Anything that spreads the light out softens the shadows it makes.")
        case .faceHalfInShadow:
            Advice(action: "Hold something white on the dark side to bounce light", why: "A white surface reflects light back into the shadow and softens it.")
        case .sunInFrame:
            Advice(action: "Zoom in a little so the sun leaves the edge", why: "Cropping the sun out keeps the sky from blowing out.")
        default:
            nil
        }
    }

    /// "Light first" while framing, for the big light problems that need someone to move.
    var lightNudge: String? {
        switch self {
        case .sunInFrame: "Light first: the sun is in the shot. Fix where you stand, then frame."
        case .backlitSubject: "Light first: the light is behind the subject. Fix where you stand, then frame."
        case .faceHalfInShadow: "Light first: half the face is in shadow. Fix the light, then frame."
        case .tooDark: "Light first: it's too dark here. Fix the light, then frame."
        default: nil
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
        case .faceHalfInShadow: "lit both sides of the face"
        case .sunInFrame: "kept the sun out of the shot"
        case .subjectInShadow: "brought the subject into the light"
        case .subjectTooBright: "kept detail in the bright subject"
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
        case .hardShadowsOnSubject: "softened the shadows"
        case .flatLight: "found side light"
        case .patchyLight: "evened out the light"
        case .sunGlare: "blocked the glare"
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
             .layersNotStacked, .jointsCropped,
             .hardShadowsOnSubject, .flatLight, .patchyLight, .sunGlare:
            true
        default:
            false
        }
    }

    /// The quality of the light, judged by the model in Light. Moving the camera doesn't change
    /// the light, so unlike other model-only tips these don't clear when the view is reframed.
    var isLightQuality: Bool {
        switch self {
        case .hardShadowsOnSubject, .flatLight, .patchyLight, .sunGlare: true
        default: false
        }
    }

    /// Problems the model can't see past, so it isn't asked while they're on screen.
    /// In Light, everyday exposure tips like a clipped sky or high ISO don't hide the quality of
    /// the light, so the model still judges it; only the big light problems and hard contrast stop it.
    func blocksModel(in topic: AdviceTopic) -> Bool {
        switch self {
        case .subjectTooSmall:
            false
        case .highlightsClipped, .highISO, .underexposed, .overexposed:
            topic != .light
        default:
            true
        }
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
    case hardShadowsOnSubject
    case flatLight
    case patchyLight
    case sunGlare

    /// Light quality, which only Light judges.
    static let lightIssues: Set<VisualIssue> = [.hardShadowsOnSubject, .flatLight, .patchyLight, .sunGlare]

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
    /// Below this brightness spread (see `SceneAnalysis.subjectContrast`) the subject is too plain
    /// to tell whether it's in focus.
    static let flatContrast = 0.05
    /// Outdoors, below this light level (EV at ISO 100) the sun isn't shining directly: it's
    /// cloudy or raining. Kept below light cloud (12 to 13) so dappled sun under trees still counts.
    static let directSunLevel = 12.0
    /// Outdoors, below this light level it's night or deep dusk. Daylight, even in heavy rain,
    /// stays above about 9; a lit street at night is around 3 to 6.
    static let nightLevel = 8.0
    /// A selfie whose biggest face is shorter than this share of the frame shows the place around you.
    static let wideSelfieFace = 0.2
    /// The subject counts as in shadow below this brightness, while the frame around it is fine.
    static let subjectShadowLevel = 0.25
    /// The subject counts as too bright above this, against a background darker than `darkBackground`.
    static let subjectBrightLevel = 0.85
    static let darkBackground = 0.4
    /// A subject smaller than this share of the frame, with no face, is too far away to judge its light.
    static let tinySubjectShare = 0.02

    /// Whether the clock says it's daytime. Kept wide, so evening light in summer still counts;
    /// the light level catches the dark hours this lets through.
    static func isDaytime(hour: Int) -> Bool {
        (6..<20).contains(hour)
    }
    /// Faces smaller than this share of the frame's height are a full-body or distant shot, where
    /// the space above the head is part of the scene, not "too much headroom".
    static let portraitFaceHeight = 0.06
    /// Below this, a face's darker half is in deep shadow next to its lit half (see
    /// `SceneAnalysis.faceShadowRatio`): about three stops darker, where an eye gets lost.
    /// Window side light, the classic portrait look, usually measures 0.4 to 0.6 and stays above it.
    static let faceShadowLimit = 0.35

    /// Below this share of edges (see `SceneAnalysis.backgroundBusyness`) the background is
    /// measurably plain, so the model's "cluttered background" isn't believed.
    static let plainBackgroundLimit = 0.08
    /// Surfaces that make a clean background, not a distraction, whatever the model says,
    /// unless the background measures clearly busy (a window onto a busy street, say).
    static let plainSurfaces: Set<String> = [
        "wall", "walls", "door", "doors", "glass", "window", "windows", "floor", "ceiling",
        "sky", "curtain", "curtains", "blind", "blinds", "background", "panel", "panels",
    ]

    /// What the rules are already dealing with, told to the model so it neither repeats nor
    /// contradicts them. Nil when the rules aren't handling anything the model would see.
    static func handledNote(issues: [CoachIssue], keepsPlacement: Bool, placement: SubjectPlacement) -> String? {
        var handled: [String] = []
        if issues.contains(.subjectTooSmall) {
            handled.append("the camera is already asking them to step closer or zoom in, so don't report the subject being small or far away")
        }
        let exposure: [(CoachIssue, String)] = [
            (.highlightsClipped, "bright areas turning white"),
            (.overexposed, "the photo being too bright"),
            (.underexposed, "the photo being too dark"),
            (.highISO, "grain from dim light"),
        ]
        let exposureHandled = exposure.filter { issues.contains($0.0) }.map(\.1)
        if !exposureHandled.isEmpty {
            handled.append("the camera is already pointing out \(exposureHandled.joined(separator: " and ")), so don't report brightness")
        }
        if keepsPlacement {
            handled.append("the subject is already where the chosen style wants it (\(placement.name)), so don't suggest moving the camera left, right, up or down; only stepping closer or back, zooming, or none")
        }
        guard !handled.isEmpty else { return nil }
        return "Already handled by the camera: " + handled.joined(separator: "; ") + "."
    }

    /// What to tell the person when Apple Intelligence can't help, so they know why the tips are simpler.
    /// Nil when it's available.
    static func modelNotice(for availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off. \(stillWorks) Turn it on in Settings for the full coach."
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence. \(stillWorks)"
        case .unavailable(.modelNotReady):
            // The model downloads in the background; the coach switches over once it's ready.
            return "Apple Intelligence is still downloading to this iPhone. Until it's ready, you'll get framing, brightness and angle tips, but the coach can't judge backgrounds, edges, lines or how soft the light is."
        case .unavailable:
            return "Apple Intelligence isn't available right now. \(stillWorks)"
        }
    }

    /// The one-time alert for when Apple Intelligence can't help, saying up front that Composition
    /// advice may not be as good. `key` names the reason, so a new reason (it's switched off after
    /// downloading, say) alerts again. Nil when it's available.
    static func modelAlert(for availability: SystemLanguageModel.Availability) -> (key: String, title: String, message: String)? {
        let effect = "Composition and Light & Exposure advice may not be as good"
        let detail = "You'll still get framing, brightness and angle tips, but the coach can't judge backgrounds, edges, lines or how soft the light is. All other modes work as usual."
        switch availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return ("notEnabled", "Apple Intelligence Is Off",
                    "\(effect) until you turn on Apple Intelligence in Settings. \(detail)")
        case .unavailable(.deviceNotEligible):
            return ("deviceNotEligible", "Apple Intelligence Isn't Available",
                    "This iPhone doesn't support Apple Intelligence, so \(effect.prefix(1).lowercased() + effect.dropFirst()). \(detail)")
        case .unavailable(.modelNotReady):
            return ("modelNotReady", "Apple Intelligence Is Downloading",
                    "\(effect) until it finishes downloading. The coach switches over by itself once it's ready. \(detail)")
        case .unavailable:
            return ("unavailable", "Apple Intelligence Isn't Available",
                    "\(effect) right now. \(detail)")
        }
    }

    /// What the coach can and can't do without Apple Intelligence, so the notice sets expectations.
    private static var stillWorks: String {
        "You'll still get framing, brightness and angle tips, but the coach can't judge backgrounds, edges, lines or how soft the light is."
    }

    /// Composition and Light show one tip, because their tips can come from the rules or the model
    /// and two from different sources can pull opposite ways. Other topics' tips all come from the rules.
    static func showsSecondTip(for topic: AdviceTopic) -> Bool {
        !usesModel(topic)
    }

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
        let lightIssues = issues(for: .light, in: a)
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

    /// Whether praise still holds once the model has found a problem with the light, so the card
    /// never praises soft light while pointing out hard shadows.
    static func praise(_ praise: String, survives issue: CoachIssue) -> Bool {
        let words = Set(praise.lowercased().split { !$0.isLetter }.map(String.init))
        switch issue {
        case .hardShadowsOnSubject, .patchyLight:
            return words.isDisjoint(with: ["light", "lit", "lighting", "soft", "shadow", "shadows", "even"])
        case .flatLight:
            return words.isDisjoint(with: ["side", "shape", "depth", "texture"])
        case .sunGlare:
            return words.isDisjoint(with: ["highlights", "clear", "contrast", "crisp"])
        default:
            return true
        }
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
        // Cloud and rain spread the light out, so there are no hard shadows, patches of sun or glare.
        // Raindrops and wet, shiny surfaces can look patchy to the model, so the light level decides.
        if [.hardShadowsOnSubject, .patchyLight, .sunGlare].contains(issue), analysis.isSoftDaylight {
            return false
        }
        // A horizon only exists outdoors, where land or sea meets the sky. The model sometimes
        // imagines one in a desk or room, so it's only believed when Vision sees a wide outdoor scene.
        if issue == .horizonThroughMiddle {
            return analysis.isWideScene
        }
        // Elbows and knees belong to people: a cup can't be "cropped at the joints".
        if issue == .jointsCropped {
            return analysis.personCount > 0
        }
        // Glare from the sun needs the sun: outdoors, in daylight. At night it's a street lamp.
        if issue == .sunGlare {
            return analysis.isOutdoors && !analysis.isOutdoorsAtNight
        }
        // Side light measured on a face, with detail kept on the shadow side, is the look to learn,
        // not hard shadows. The card praises it as "Soft side light", so the two would disagree.
        if issue == .hardShadowsOnSubject, analysis.hasGoodSideLight {
            return false
        }
        // Light on the subject needs a subject to fall on.
        // and big enough in the frame for the light on it to show.
        if [.hardShadowsOnSubject, .flatLight, .patchyLight].contains(issue), analysis.faces.isEmpty,
           (analysis.subjectShare ?? 0) < tinySubjectShare {
            return false
        }
        // Light that's measured coming from one side isn't flat, and neither is light from a lamp,
        // window or the sun in the shot: flat light comes from straight behind the camera.
        if issue == .flatLight, analysis.faceLitSide != nil || analysis.lightSide?.sideWord != nil || analysis.lightSpot != nil {
            return false
        }
        // A subject with almost no light and dark in it can't have hard shadows or patches on it.
        if issue == .hardShadowsOnSubject || issue == .patchyLight, let contrast = analysis.subjectContrast, contrast < flatContrast {
            return false
        }
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

    /// Light problems big enough that fixing them means moving, which would undo framing done first.
    static let bigLightIssues: [CoachIssue] = [.sunInFrame, .backlitSubject, .faceHalfInShadow, .tooDark]

    /// Told to the model in Light & Exposure, so its tips never lose what's being photographed.
    static func lightKeepNote(keepsFraming: Bool) -> String {
        keepsFraming
            ? "The framing is already lined up and must not change: only suggest asking the person to turn or step, or a camera setting."
            : "Keep the subject and what's behind it in the shot: suggest walking around the subject, asking the person to turn or step, a small step, or a setting. Never suggest pointing the camera somewhere else."
    }

    /// A hint about the light at this time of day, for the model when outdoors. Nil at times
    /// when the light could be anything. Uses only the clock, so no location is needed.
    static func timeOfDayHint(hour: Int, outdoors: Bool) -> String? {
        guard outdoors else { return nil }
        switch hour {
        case 6..<9, 17..<20: return "It is early morning or evening, when sunlight is soft, warm and low."
        case 11..<15: return "It is around midday, when the sun is high and harsh; open shade gives softer light."
        default: return nil
        }
    }

    /// Topics where the model adds judgement the measurements can't give. Composition looks beyond
    /// the subject, at the background and other objects. Light adds the quality of the light, like
    /// hard shadows or patchy sun, which brightness can't show. Angle & Focus
    /// is exact measurements, so it stays measured only.
    static func usesModel(_ topic: AdviceTopic) -> Bool {
        topic == .composition || topic == .light
    }

    /// Visual issues that make sense to report for a topic and the chosen composition styles.
    @MainActor
    static func allows(_ issue: VisualIssue, for topic: AdviceTopic, styles: Set<CompositionGuide> = []) -> Bool {
        guard !unusedModelIssues.contains(issue) else { return false }
        switch topic {
        case .composition:
            // Composition is about framing; rotating or angling the phone belongs to Angle & Focus,
            // and the quality of the light to Light.
            guard ![.linesNotStraight, .notOverhead].contains(issue), !VisualIssue.lightIssues.contains(issue) else { return false }
            // Style issues only count when one of their styles is being practised.
            guard let owners = issue.styles else { return true }
            return !owners.isDisjoint(with: styles)
        case .light:
            // Light judges only the light; brightness itself is measured.
            return VisualIssue.lightIssues.contains(issue)
        default:
            return false
        }
    }

    /// Whether someone can fix this light problem now. A building, a view or a plant can't step into
    /// shade, and a view can't turn to the sun, so hard, patchy or flat light on them would only be
    /// "wait for the light". Those aren't raised; the coach only asks for what can be done.
    /// With `keepsFraming`, the camera can't walk round either.
    static func canFix(_ issue: CoachIssue, in a: SceneAnalysis, keepsFraming: Bool = false) -> Bool {
        switch issue {
        case .harshContrast, .hardShadowsOnSubject, .patchyLight:
            a.canMoveSubject
        case .flatLight:
            a.readings.isFrontCamera || !(a.isFixedScene || (keepsFraming && !a.canMoveSubject))
        default:
            true
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
        case .light:
            // Light and exposure together, biggest first: where the light is, then how bright
            // the photo is, then the quality of the light, then noise.
            // Night Mode and Flash mostly change the saved photo, not the preview, so turning
            // them on counts as following the tip.
            // Flash only counts where it reaches, so it can't hide a dark view or building.
            let addsLight = a.readings.isNightModeOn || (a.readings.isFlashOn && a.flashCanReach)
            // The sun in the shot comes first: it blows out the sky and darkens everything else.
            if a.sunSpot != nil { found.append(.sunInFrame) }
            // Brightening lifts the background too, so the gap never closes. The fix is done
            // once the subject itself is bright enough.
            if a.isBacklit, (a.subjectBrightness ?? 0) < 0.4 { found.append(.backlitSubject) }
            // A subject in shadow while the frame around it is fine: someone under a tree in a sunny park.
            // Brightness is measured for the whole frame, so only the subject's own measure shows it.
            if !a.isBacklit, a.brightness >= subjectShadowLevel, iso <= 1600, !addsLight,
               let subject = a.subjectBrightness, subject < subjectShadowLevel {
                found.append(.subjectInShadow)
            }
            // Too dark to shoot well says more than "underexposed", so it takes its place.
            if a.brightness < 0.2 || iso > 1600, !addsLight {
                found.append(.tooDark)
            } else if offset < -0.7 || a.brightness < 0.22, !addsLight {
                found.append(.underexposed)
            } else if offset > 0.7 || a.brightness > 0.8 {
                found.append(.overexposed)
            }
            // A spotlit subject on a dark background: the camera brightens for the dark, so the
            // subject turns white first.
            if !found.contains(.overexposed), let subject = a.subjectBrightness, subject > subjectBrightLevel,
               let background = a.backgroundBrightness, background < darkBackground {
                found.append(.subjectTooBright)
            }
            // Once Exposure has been pulled down a full stop, what's still white is a lamp or the
            // sun, which no setting can fix, so the tip counts as done.
            // A lamp or window indoors that's the only white area should stay white: darkening the
            // photo for it makes everything else dark.
            let onlyALamp = !a.isOutdoors && a.lightSpot != nil && a.highlightClip <= LightSpotFinder.maxShare
            // With people in the shot, the face matters more than the sky: darkening for the sky
            // would darken them, so a white sky isn't pointed out while they're well lit.
            let skyBehindPeople = a.personCount > 0 && !found.contains(.subjectTooBright)
            if a.highlightClip > 0.04, !found.contains(.overexposed), !found.contains(.sunInFrame), a.readings.exposureBias > -1,
               !onlyALamp, !skyBehindPeople {
                found.append(.highlightsClipped)
            }
            if a.highlightClip > 0.04, a.shadowClip > 0.1, !found.contains(.highlightsClipped), !onlyALamp,
               canFix(.harshContrast, in: a) {
                found.append(.harshContrast)
            }
            // Side light gives a face shape, but one half lost in deep shadow hides an eye.
            if let ratio = a.faceShadowRatio, ratio < faceShadowLimit, !a.isBacklit { found.append(.faceHalfInShadow) }
            if iso > 800, !found.contains(.tooDark), !addsLight { found.append(.highISO) }
        case .focus:
            // Shake blurs everything and throws off the level, so fix it first.
            if let shake = a.shake, shake >= shakeThreshold { found.append(.cameraShaking) }
            // Then the angle, because moving the phone changes what's in focus.
            if isTilted(a.tilt, alreadyShown: tiltShown) { found.append(.phoneTilted) }
            if let pitch = a.pitch {
                // Wide limits, so holding the phone near one doesn't flick the tip on and off.
                if pitch < -35, a.personCount > 0 { found.append(.shootingDown) }
                // Tilting up only bends straight lines like walls and buildings. Shooting up at
                // the sky, a tree or a bird is fine.
                if pitch > 25, a.scenes.contains(.city) { found.append(.pointingUp) }
            }
            // A plain subject has little detail even when it's in focus, so it can't be called soft.
            if a.subjectSharpness < softThreshold, !a.subjectIsFlat { found.append(.subjectSoft) }
            // A slow shutter is only a problem while the phone moves. The tip is to hold still,
            // and holding still is what clears it; the shutter speed itself can't be changed by hand.
            let isSteady = a.shake.map { $0 < shakeThreshold / 2 } ?? false
            if let seconds = a.readings.exposureSeconds, seconds > 1.0 / 30,
               !found.contains(.cameraShaking), !isSteady {
                found.append(.slowShutter)
            }
        case .composition:
            // Everyone counts: any head at the top edge is cut off, and headroom is
            // measured above the highest head, so it works for groups too.
            if a.headAtTopEdge {
                found.append(.headCutOff)
            } else if let topmost = a.faces.min(by: { $0.minY < $1.minY }), topmost.minY > 0.35,
                      // Small faces are a full-body or distant shot: the space above is the scene.
                      topmost.height >= portraitFaceHeight, !a.isWideScene {
                found.append(.tooMuchHeadroom)
            }
            // Negative Space wants a small subject, so "get closer" would undo the style.
            if let subject = a.subject, subject.width * subject.height < 0.02, !a.isWideScene,
               !styles.contains(.negativeSpace) {
                found.append(.subjectTooSmall)
            }
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
        case .light:
            // A subject much darker or brighter than the rest isn't balanced, whatever the average says.
            let subjectOff = problems.contains(.subjectInShadow) || problems.contains(.subjectTooBright)
            if !problems.contains(.underexposed), !problems.contains(.overexposed), !problems.contains(.tooDark), !subjectOff {
                good.append("Balanced brightness")
            }
            if a.highlightClip < 0.01 { good.append("Highlights have detail") }
            let halfInShadow = problems.contains(.faceHalfInShadow)
            // Side light that still shows both halves of the face: the look to learn.
            if a.faceLitSide != nil, !halfInShadow, !a.isBacklit { good.append("Soft side light") }
            if !a.isBacklit, a.brightness >= 0.2, !halfInShadow, !problems.contains(.subjectInShadow) {
                good.append("Light reaches the subject")
            }
            if a.highlightClip < 0.02, a.shadowClip < 0.05, !halfInShadow { good.append("Soft, even light") }
        case .focus:
            if a.subjectSharpness >= softThreshold { good.append("Subject is sharp") }
            if let shake = a.shake, shake < shakeThreshold / 2 { good.append("Steady hands") }
            if a.tilt != nil, !problems.contains(.phoneTilted) { good.append("Phone is level") }
        case .composition:
            // Other framing strengths come from the model and the target guide, not from how the phone is held.
            let isPortrait = a.faces.contains { $0.height >= portraitFaceHeight } && !a.isWideScene
            if isPortrait, !problems.contains(.headCutOff), !problems.contains(.tooMuchHeadroom) {
                good.append("Good headroom")
            }
        }
        return good
    }
}
