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
    case subjectSoft, slowShutter
    case phoneTilted, shootingDown, pointingUp
    case headCutOff, tooMuchHeadroom, subjectTooSmall
    // Judged by the model, because they can't be measured.
    case clutteredBackground, distractingEdges, subjectCutOff, noClearSubject
    case tooMuchEmptySpace, horizonThroughMiddle, flatAngle
}

/// What to do now, and the photography idea behind it.
nonisolated struct Advice: Equatable, Sendable {
    let action: String
    let why: String
}

extension CoachIssue {
    /// Short, beginner-friendly advice that names the controls in the topic's top bar.
    func advice(for topic: AdviceTopic, analysis: SceneAnalysis? = nil) -> Advice {
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
        case .subjectSoft:
            Advice(action: "Drag the Focus slider until the subject is crisp", why: "The eye goes to the sharpest part of a photo first.")
        case .slowShutter:
            Advice(action: "Tuck your elbows in and hold very still", why: "A slow shutter turns small shakes into blur.")
        case .phoneTilted:
            Advice(action: tiltAction(analysis?.tilt), why: "A tilted horizon makes the whole photo feel off balance.")
        case .shootingDown:
            Advice(action: "Crouch to the subject's eye level", why: "Shooting down makes people and pets look small.")
        case .pointingUp:
            Advice(action: "Hold the phone upright to keep lines straight", why: "Tilting up makes buildings look like they're falling back.")
        case .headCutOff:
            Advice(action: "Tilt the camera up to show the whole head", why: "Cutting off the top of a head looks like a mistake.")
        case .tooMuchHeadroom:
            Advice(action: "Tilt down so the eyes sit near the top third", why: "Too much space above the head makes the subject look sunk.")
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
            Advice(action: "Tilt so the horizon sits on a third line", why: "A horizon across the middle splits the photo in two.")
        case .flatAngle:
            Advice(action: "Try crouching low or holding the phone higher", why: "A new height makes everyday scenes look fresh.")
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
        case .subjectSoft: "got the subject sharp"
        case .slowShutter: "held the camera steady"
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
        case .flatAngle: "tried a fresh angle"
        }
    }

    private func tiltAction(_ tilt: Double?) -> String {
        guard let tilt else { return "Level the phone" }
        // A positive tilt means the phone is turned clockwise.
        return tilt > 0 ? "Rotate the phone slightly left to level it" : "Rotate the phone slightly right to level it"
    }
}

/// Issues the model picks from. Only things that can't be measured.
@Generable
enum VisualIssue: String {
    case none
    case clutteredBackground
    case distractingEdges
    case subjectCutOff
    case noClearSubject
    case tooMuchEmptySpace
    case horizonThroughMiddle
    case flatAngle

    nonisolated var coachIssue: CoachIssue? {
        switch self {
        case .none: nil
        case .clutteredBackground: .clutteredBackground
        case .distractingEdges: .distractingEdges
        case .subjectCutOff: .subjectCutOff
        case .noClearSubject: .noClearSubject
        case .tooMuchEmptySpace: .tooMuchEmptySpace
        case .horizonThroughMiddle: .horizonThroughMiddle
        case .flatAngle: .flatAngle
        }
    }
}

/// What the model returns for a live frame.
@Generable
struct CoachJudgement {
    @Guide(description: "The single biggest problem a beginner should fix for the chosen topic, or none if it already works")
    var issue: VisualIssue

    @Guide(description: "One thing that already works in the photo, 2 to 5 words. Call any person the subject. Empty if nothing stands out")
    var strength: String
}

/// Turns measurements into issues for each topic. Pure functions, so they're easy to test.
nonisolated enum CoachRules {
    /// Below this the subject counts as soft. Measured on a 256-pixel-wide copy of the frame.
    static let softThreshold = 40.0
    /// Degrees of tilt worth pointing out.
    static let tiltThreshold = 2.0

    /// Topics where the model adds judgement the measurements can't give.
    static func usesModel(_ topic: AdviceTopic) -> Bool {
        topic == .composition || topic == .anglePerspective
    }

    /// Visual issues that make sense to report for a topic.
    static func allows(_ issue: VisualIssue, for topic: AdviceTopic) -> Bool {
        switch topic {
        case .composition: issue != .flatAngle
        case .anglePerspective: issue == .flatAngle || issue == .clutteredBackground || issue == .none
        default: false
        }
    }

    /// Measured issues for a topic, most important first.
    static func issues(for topic: AdviceTopic, in a: SceneAnalysis) -> [CoachIssue] {
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
            if a.highlightClip > 0.04, !found.contains(.overexposed) { found.append(.highlightsClipped) }
            if a.isBacklit { found.append(.backlitSubject) }
        case .light:
            if a.brightness < 0.2 || iso > 1600 { found.append(.tooDark) }
            if a.isBacklit { found.append(.backlitSubject) }
            if a.highlightClip > 0.04, a.shadowClip > 0.1 { found.append(.harshContrast) }
            if iso > 800, !found.contains(.tooDark) { found.append(.highISO) }
        case .focus:
            if a.subjectSharpness < softThreshold { found.append(.subjectSoft) }
            if let seconds = a.readings.exposureSeconds, seconds > 1.0 / 30 { found.append(.slowShutter) }
        case .anglePerspective:
            if let tilt = a.tilt, abs(tilt) >= tiltThreshold { found.append(.phoneTilted) }
            if let pitch = a.pitch {
                if pitch < -30, !a.faces.isEmpty { found.append(.shootingDown) }
                if pitch > 20 { found.append(.pointingUp) }
            }
        case .composition:
            if let tilt = a.tilt, abs(tilt) >= tiltThreshold { found.append(.phoneTilted) }
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
    static func strengths(for topic: AdviceTopic, in a: SceneAnalysis) -> [String] {
        let problems = issues(for: topic, in: a)
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
        case .anglePerspective, .composition:
            if let tilt = a.tilt, abs(tilt) < tiltThreshold { good.append("Phone is level") }
        case .subjectPosition:
            if !a.faces.isEmpty, !problems.contains(.headCutOff), !problems.contains(.tooMuchHeadroom) {
                good.append("Good headroom")
            }
        }
        return good
    }
}
