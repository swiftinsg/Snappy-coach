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
    tilt: Double? = 0
) -> SceneAnalysis {
    SceneAnalysis(
        brightness: brightness, highlightClip: highlightClip, shadowClip: shadowClip,
        subject: subject, subjectBrightness: subjectBrightness, backgroundBrightness: backgroundBrightness,
        subjectSharpness: sharpness, faces: faces, readings: readings, pitch: pitch, tilt: tilt
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
}
