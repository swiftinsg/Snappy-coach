//
//  PhotoAppTests.swift
//  PhotoAppTests
//
//  Checks that the coach's rules turn measurements into the right advice.
//

import Testing
import CoreGraphics
@testable import Grp_6pm_Photo_App

/// A frame with sensible defaults, so each test only states what matters to it.
private func scene(
    brightness: Double = 0.5,
    highlightClip: Double = 0,
    shadowClip: Double = 0,
    subject: CGRect? = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
    subjectBrightness: Double? = 0.5,
    backgroundBrightness: Double? = 0.5,
    sharpness: Double = 120,
    faces: [CGRect] = [],
    readings: CameraReadings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 120, iso: 100),
    pitch: Double? = 0,
    tilt: Double? = 0,
    shake: Double? = 0
) -> SceneAnalysis {
    SceneAnalysis(
        brightness: brightness, highlightClip: highlightClip, shadowClip: shadowClip,
        subject: subject, subjectBrightness: subjectBrightness, backgroundBrightness: backgroundBrightness,
        subjectSharpness: sharpness, faces: faces, readings: readings, pitch: pitch, tilt: tilt,
        shake: shake
    )
}

@MainActor
struct CoachRulesTests {
    @Test func wellExposedFrameHasNoExposureIssues() {
        #expect(CoachRules.issues(for: .exposure, in: scene()).isEmpty)
        #expect(CoachRules.strengths(for: .exposure, in: scene()).contains("Balanced brightness"))
    }

    @Test func darkFrameIsUnderexposed() {
        #expect(CoachRules.issues(for: .exposure, in: scene(brightness: 0.1)).first == .underexposed)
    }

    @Test func cameraMeterOverridesAverageBrightness() {
        let readings = CameraReadings(exposureOffset: 1.2, exposureSeconds: 1.0 / 120, iso: 100)
        #expect(CoachRules.issues(for: .exposure, in: scene(readings: readings)).first == .overexposed)
    }

    @Test func blownSkyAsksToProtectHighlights() {
        #expect(CoachRules.issues(for: .exposure, in: scene(highlightClip: 0.1)).contains(.highlightsClipped))
    }

    @Test func darkSubjectOnBrightBackgroundIsBacklit() {
        let backlit = scene(subjectBrightness: 0.2, backgroundBrightness: 0.8)
        #expect(backlit.isBacklit)
        #expect(CoachRules.issues(for: .light, in: backlit).contains(.backlitSubject))
        // The same problem gets topic-specific advice.
        #expect(CoachIssue.backlitSubject.advice(for: .exposure).action.contains("Exposure"))
        #expect(!CoachIssue.backlitSubject.advice(for: .light).action.contains("Exposure"))
    }

    @Test func dimSceneSuggestsNightModeOrLight() {
        let readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 15, iso: 3200)
        #expect(CoachRules.issues(for: .light, in: scene(readings: readings)).first == .tooDark)
    }

    @Test func softSubjectNeedsFocus() {
        #expect(CoachRules.issues(for: .focus, in: scene(sharpness: 10)).first == .subjectSoft)
        #expect(CoachRules.issues(for: .focus, in: scene(sharpness: 200)).isEmpty)
    }

    @Test func slowShutterWarnsAboutShake() {
        let readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 10, iso: 400)
        #expect(CoachRules.issues(for: .focus, in: scene(readings: readings)).contains(.slowShutter))
    }

    @Test func tiltedPhoneIsReportedWithDirection() {
        let tilted = scene(tilt: 5)
        #expect(CoachRules.issues(for: .anglePerspective, in: tilted).first == .phoneTilted)
        #expect(CoachIssue.phoneTilted.advice(for: .anglePerspective, analysis: tilted).action.contains("left"))
        #expect(CoachIssue.phoneTilted.advice(for: .anglePerspective, analysis: scene(tilt: -5)).action.contains("right"))
        #expect(CoachRules.issues(for: .anglePerspective, in: scene(tilt: 1)).isEmpty)
    }

    @Test func shootingDownAtPeopleSuggestsEyeLevel() {
        let face = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)
        #expect(CoachRules.issues(for: .anglePerspective, in: scene(faces: [face], pitch: -45)).contains(.shootingDown))
    }

    @Test func headroomRules() {
        let cutOff = CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.2)
        let sunk = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2)
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [cutOff])).first == .headCutOff)
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [sunk])).first == .tooMuchHeadroom)
    }

    @Test func tinySubjectNeedsToFillTheFrame() {
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        #expect(CoachRules.issues(for: .composition, in: scene(subject: tiny)).contains(.subjectTooSmall))
    }

    @Test func modelIssuesAreFilteredByTopic() {
        #expect(CoachRules.allows(.clutteredBackground, for: .composition))
        #expect(!CoachRules.allows(.flatAngle, for: .composition))
        #expect(CoachRules.allows(.flatAngle, for: .anglePerspective))
        #expect(!CoachRules.allows(.subjectCutOff, for: .exposure))
    }

    @Test func everyIssueHasShortAdviceAndAReason() {
        for issue in CoachIssue.allCases {
            let advice = issue.advice(for: .composition)
            #expect(advice.action.split(separator: " ").count <= 10, "\(issue) action is too long")
            #expect(!advice.why.isEmpty, "\(issue) has no reason")
            #expect(!issue.accomplishment.isEmpty)
        }
    }

    @Test func tiltWarningStaysUntilClearlyLevel() {
        #expect(CoachRules.issues(for: .composition, in: scene(tilt: 3)).contains(.phoneTilted))
        // 1.5° is too small to start a warning, but not level enough to clear one.
        #expect(!CoachRules.issues(for: .composition, in: scene(tilt: 1.5)).contains(.phoneTilted))
        #expect(CoachRules.issues(for: .composition, in: scene(tilt: 1.5), tiltShown: true).contains(.phoneTilted))
        #expect(!CoachRules.issues(for: .composition, in: scene(tilt: 0.5), tiltShown: true).contains(.phoneTilted))
        #expect(!CoachRules.strengths(for: .composition, in: scene(tilt: 1.5), tiltShown: true).contains("Phone is level"))
    }

    @Test func tiltAdviceGivesDegrees() {
        #expect(CoachIssue.phoneTilted.advice(for: .composition, analysis: scene(tilt: 4.2)).action.contains("4°"))
    }

    @Test func motionReadingsFromGravity() {
        // Upright portrait: level and pointing at the horizon.
        #expect(PhoneAttitude.tilt(x: 0, y: -1, z: 0) == 0)
        #expect(PhoneAttitude.pitch(gravityZ: 0) == 0)
        // Flat on its back the camera points straight down and there is no level.
        #expect(PhoneAttitude.pitch(gravityZ: -1) == -90)
        #expect(PhoneAttitude.tilt(x: 0, y: 0, z: -1) == nil)
        // Turned clockwise is positive, and landscape counts as level.
        let clockwise = PhoneAttitude.tilt(x: sin(.pi / 36), y: -cos(.pi / 36), z: 0) ?? 0
        #expect(abs(clockwise - 5) < 0.01)
        #expect(abs(PhoneAttitude.tilt(x: 1, y: 0, z: 0) ?? 99) < 0.01)
    }

    @Test func shakingPhoneComesBeforeFocus() {
        let issues = CoachRules.issues(for: .focus, in: scene(sharpness: 10, shake: 0.6))
        #expect(issues.first == .cameraShaking)
        #expect(CoachRules.issues(for: .focus, in: scene(shake: 0.05)).isEmpty)
    }

    @Test func styleIssuesOnlyForTheirStyles() {
        #expect(CoachRules.allows(.notSymmetric, for: .composition, styles: [.symmetry]))
        #expect(!CoachRules.allows(.notSymmetric, for: .composition, styles: [.ruleOfThirdsOne]))
        #expect(CoachRules.allows(.clutteredBackground, for: .composition, styles: [.symmetry]))
        #expect(!CoachRules.allows(.linesDontLead, for: .anglePerspective, styles: [.leadingLines]))
        // Every visual issue except none maps to a coach issue.
        for issue in VisualIssue.allCases where issue != .none {
            #expect(issue.coachIssue != nil, "\(issue) has no advice")
        }
    }

    @Test func modelDetailMakesAdviceSpecific() {
        let edge = CoachIssue.distractingEdges.advice(
            for: .composition, detail: IssueDetail(region: .right, rawThing: "Bright sign.")
        )
        #expect(edge.action == "Turn slightly left to drop the bright sign")
        #expect(edge.symbol == "arrow.left")

        let background = CoachIssue.clutteredBackground.advice(
            for: .composition, detail: IssueDetail(region: .background, rawThing: "the lamp post")
        )
        #expect(background.action.contains("the lamp post"))

        // Unusable words fall back to the general advice.
        let general = CoachIssue.clutteredBackground.advice(for: .composition)
        let junk = IssueDetail(region: .background, rawThing: "3 cars parked along the busy road")
        #expect(junk.thing == nil)
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, detail: junk) == general)
    }

    @Test func peopleAreAlwaysTheSubject() {
        #expect(IssueDetail.cleanedThing("the woman") == "the subject")
        #expect(IssueDetail.cleanedThing("none") == nil)
        #expect(IssueDetail.cleanedThing("") == nil)
    }

    @Test func memoryStaysShortAndRemembersWhatWasDone() {
        var memory = CoachMemory()
        #expect(memory.sentence == "Nothing yet.")
        memory.notePractising(.light, styles: [])
        memory.noteFixed(.tooDark)
        memory.noteShown(.clutteredBackground)
        memory.notePractising(.composition, styles: [.symmetry])
        let sentence = memory.sentence
        #expect(sentence.contains("Light"))
        #expect(!sentence.contains("Composition"))
        #expect(sentence.contains("found better light"))
        #expect(sentence.contains("clutteredBackground"))
        #expect(sentence.split(separator: " ").count <= 40)

        // Fixing an issue takes it off the "not fixed yet" list.
        memory.noteFixed(.clutteredBackground)
        #expect(!memory.sentence.contains("clutteredBackground"))
    }

    @Test func ignoredAdviceStepsAside() {
        var memory = CoachMemory()
        memory.noteShown(.clutteredBackground)
        memory.noteShown(.clutteredBackground)
        let issues: [CoachIssue] = [.clutteredBackground, .distractingEdges]
        #expect(memory.reordered(issues, keeping: nil) == [.distractingEdges, .clutteredBackground])
        // The issue already on screen keeps its place so the card doesn't jump.
        #expect(memory.reordered(issues, keeping: .clutteredBackground) == issues)
        #expect(CoachIssue.clutteredBackground.alternativeAdvice(for: .composition) != nil)
    }

    @Test func sceneTypeFromVisionLabels() {
        let face = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)
        // A visible face always means people, whatever the labels say.
        #expect(SceneType.classify(labels: [("food", 0.9)], faces: [face]) == .people)
        #expect(SceneType.classify(labels: [("food", 0.6), ("dessert", 0.4)], faces: []) == .food)
        #expect(SceneType.classify(labels: [("cityscape", 0.7), ("sky", 0.4)], faces: []) == .city)
        #expect(SceneType.classify(labels: [("mountain", 0.6), ("sky", 0.5), ("building", 0.3)], faces: []) == .landscape)
        // "skyscraper" is a city word, not a sky word.
        #expect(SceneType.classify(labels: [("skyscraper", 0.5)], faces: []) == .city)
        // Unsure or unknown labels fall back to a plain object.
        #expect(SceneType.classify(labels: [("food", 0.1)], faces: []) == .object)
        #expect(SceneType.classify(labels: [("teapot", 0.9)], faces: []) == .object)
    }

    @Test func sceneIsSmoothedOverRecentFrames() {
        #expect(SceneType.smoothed([.food, .food, .city]) == .food)
        #expect(SceneType.smoothed([.food, .city]) == .city)
        #expect(SceneType.smoothed([]) == nil)
    }

    @Test func adviceFitsTheScene() {
        var food = scene()
        food.scene = .food
        #expect(CoachIssue.flatAngle.advice(for: .anglePerspective, analysis: food).action.contains("45°"))
        var landscape = scene()
        landscape.scene = .landscape
        #expect(CoachIssue.horizonThroughMiddle.advice(for: .composition, analysis: landscape).action.contains("bottom third"))
        // Other scenes keep the usual wording.
        #expect(CoachIssue.flatAngle.advice(for: .anglePerspective, analysis: scene()) == CoachIssue.flatAngle.advice(for: .anglePerspective))

        for type in SceneType.allCases {
            var analysis = scene()
            analysis.scene = type
            for issue in CoachIssue.allCases {
                let advice = issue.advice(for: .composition, analysis: analysis)
                #expect(advice.action.split(separator: " ").count <= 10, "\(issue) for \(type) is too long")
                #expect(!advice.why.isEmpty)
            }
            #expect(!type.coachingHint.isEmpty)
            #expect(!type.suitedStyles.isEmpty)
        }
        #expect(SceneType.food.suitedStyles.first == .tableTop45)
    }
}
