//
//  PhotoAppTests.swift
//  PhotoAppTests
//
//  Checks that the coach's rules turn measurements into the right advice.
//

import Testing
import CoreGraphics
import ImageIO
import FoundationModels
import SwiftUI
import UIKit
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
        #expect(CoachRules.issues(for: .light, in: scene()).isEmpty)
        #expect(CoachRules.strengths(for: .light, in: scene()).contains("Balanced brightness"))
    }

    @Test func darkFrameIsUnderexposed() {
        // Dark enough to shoot badly is "too dark", which takes the place of "underexposed".
        #expect(CoachRules.issues(for: .light, in: scene(brightness: 0.1)).first == .tooDark)
        #expect(!CoachRules.issues(for: .light, in: scene(brightness: 0.1)).contains(.underexposed))
        // A little dark, with enough light around, is just underexposed.
        let dimmed = CameraReadings(exposureOffset: -1, exposureSeconds: 1.0 / 120, iso: 100)
        #expect(CoachRules.issues(for: .light, in: scene(brightness: 0.3, readings: dimmed)).contains(.underexposed))
    }

    @Test func cameraMeterOverridesAverageBrightness() {
        let readings = CameraReadings(exposureOffset: 1.2, exposureSeconds: 1.0 / 120, iso: 100)
        #expect(CoachRules.issues(for: .light, in: scene(readings: readings)).first == .overexposed)
    }

    @Test func blownSkyAsksToProtectHighlights() {
        #expect(CoachRules.issues(for: .light, in: scene(highlightClip: 0.1)).contains(.highlightsClipped))
    }

    @Test func darkSubjectOnBrightBackgroundIsBacklit() {
        let backlit = scene(highlightClip: 0.05, subjectBrightness: 0.2, backgroundBrightness: 0.8)
        #expect(backlit.isBacklit)
        #expect(CoachRules.issues(for: .light, in: backlit).contains(.backlitSubject))
        // The same problem gets topic-specific advice.
        #expect(CoachIssue.backlitSubject.advice(for: .light).action.contains("Tap the subject"))
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
        #expect(CoachRules.issues(for: .focus, in: scene(readings: readings, shake: 0.15)).contains(.slowShutter))
        // The tip is to hold still, so holding still clears it.
        #expect(!CoachRules.issues(for: .focus, in: scene(readings: readings, shake: 0.05)).contains(.slowShutter))
    }

    // Each tip must clear once the person does what it says, or the section never finishes.

    @Test func nightModeOrFlashClearsTheDarkTip() {
        var readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 15, iso: 3200)
        readings.isNightModeOn = true
        #expect(!CoachRules.issues(for: .light, in: scene(readings: readings)).contains(.tooDark))
        readings.isNightModeOn = false
        readings.isFlashOn = true
        let issues = CoachRules.issues(for: .light, in: scene(readings: readings))
        #expect(!issues.contains(.tooDark))
        #expect(!issues.contains(.highISO))
    }

    @Test func brighteningABacklitSubjectClearsTheExposureTip() {
        #expect(CoachRules.issues(for: .light, in: scene(highlightClip: 0.05, subjectBrightness: 0.2, backgroundBrightness: 0.8)).contains(.backlitSubject))
        // After dragging Exposure right the background is still brighter, but the subject is fine.
        #expect(!CoachRules.issues(for: .light, in: scene(subjectBrightness: 0.5, backgroundBrightness: 0.95)).contains(.backlitSubject))
    }

    @Test func lowerExposureClearsTheHighlightsTipEvenWithALampInFrame() {
        var readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 120, iso: 100)
        readings.exposureBias = -1
        #expect(!CoachRules.issues(for: .light, in: scene(highlightClip: 0.1, readings: readings)).contains(.highlightsClipped))
    }

    @Test func steppingCloserOrBackIsMeasuredBySubjectSize() {
        #expect(CoachIssue.subjectTooSmall.asksToMove == .closer)
        #expect(CoachIssue.subjectCutOff.asksToMove == .back)
        #expect(CoachIssue.clutteredBackground.asksToMove == nil)
        // Closer (or zoomed in): the subject fills half as much again.
        #expect(DistanceMove.closer.isDone(from: 0.1, to: 0.16))
        #expect(!DistanceMove.closer.isDone(from: 0.1, to: 0.12))
        // Back: the subject shrinks by a third.
        #expect(DistanceMove.back.isDone(from: 0.3, to: 0.19))
        #expect(!DistanceMove.back.isDone(from: 0.3, to: 0.25))
        // Without a subject box, the biggest face is used.
        let face = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.25)
        #expect(PhotoCoach.subjectSize(in: scene(subject: nil, faces: [face])) == Double(0.2 * 0.25))
    }

    @Test func personInALandscapeGetsBothKindsOfAdvice() {
        let face = CGRect(x: 0.45, y: 0.4, width: 0.05, height: 0.06)
        var portrait = scene(subject: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.1), faces: [face])
        portrait.scene = .people
        portrait.backdrop = .landscape
        #expect(portrait.scenes == [.people, .landscape])
        // The landscape's wording applies, though the main scene is people.
        #expect(CoachIssue.horizonThroughMiddle.advice(for: .composition, analysis: portrait).action.contains("bottom third"))
        // A small person in a big view is a fine shot, so no "get closer".
        #expect(!CoachRules.issues(for: .composition, in: portrait).contains(.subjectTooSmall))
        #expect(portrait.summary.contains("people photo with a landscape behind"))
    }

    @Test func wideScenesDontAskToGetCloser() {
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        var landscape = scene(subject: tiny)
        landscape.scene = .landscape
        #expect(!CoachRules.issues(for: .composition, in: landscape).contains(.subjectTooSmall))
        #expect(CoachRules.issues(for: .composition, in: scene(subject: tiny)).contains(.subjectTooSmall))
    }

    @Test func onlyBrightnessTipsAskForATapOnTheViewfinder() {
        // A single tap on the viewfinder sets focus and brightness there, so only brightness tips
        // ask for one. Picking the subject is a double tap, which tips never ask for.
        let brightness: Set<CoachIssue> = [.underexposed, .overexposed, .highlightsClipped, .backlitSubject]
        for issue in CoachIssue.allCases {
            for topic in AdviceTopic.allCases {
                for advice in [issue.advice(for: topic), issue.alternativeAdvice(for: topic)].compactMap(\.self) {
                    if advice.action.hasPrefix("Tap the") {
                        #expect(brightness.contains(issue), "\(issue) asks for a tap but isn't about brightness")
                    }
                    #expect(!advice.action.lowercased().contains("double-tap"), "\(issue) asks for a double tap")
                    #expect(!advice.action.contains("drag the sun"), "\(issue) mentions the sun handle")
                    #expect(!advice.action.contains("Depth"), "\(issue) relies on Depth, which the preview doesn't show")
                }
            }
        }
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
        #expect(CoachRules.issues(for: .composition, in: scene(faces: [cutOff])).first == .headCutOff)
        #expect(CoachRules.issues(for: .composition, in: scene(faces: [sunk])).first == .tooMuchHeadroom)
    }

    @Test func groupsAreCheckedForEveryone() {
        let fine = CGRect(x: 0.2, y: 0.15, width: 0.1, height: 0.12)
        let cutOff = CGRect(x: 0.6, y: 0.0, width: 0.1, height: 0.1)
        // Someone's head at the top edge is cut off, even if it isn't the biggest face.
        let bigFine = CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.2)
        #expect(CoachRules.issues(for: .composition, in: scene(faces: [bigFine, cutOff])).contains(.headCutOff))
        // Headroom is measured above the highest head, so it works with several people.
        let low1 = CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1)
        let low2 = CGRect(x: 0.6, y: 0.45, width: 0.1, height: 0.1)
        #expect(CoachRules.issues(for: .composition, in: scene(faces: [low1, low2])).contains(.tooMuchHeadroom))
        #expect(!CoachRules.issues(for: .composition, in: scene(faces: [fine, low2])).contains(.tooMuchHeadroom))
        // People facing away (bodies, no faces) still count.
        var backs = scene(faces: [])
        backs.people = [CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.6), CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.6)]
        #expect(backs.personCount == 2)
        #expect(backs.summary.contains("2 people"))
        #expect(SceneType.classify(labels: [], faces: backs.people) == .people)
    }

    @Test func unverifiableGetCloserTipsAreGone() {
        let all = Set(CompositionGuide.allCases)
        for topic in AdviceTopic.allCases {
            #expect(!CoachRules.allows(.noClearSubject, for: topic, styles: all))
            #expect(!CoachRules.allows(.tooMuchEmptySpace, for: topic, styles: all))
            #expect(!CoachRules.allows(.subjectTooBig, for: topic, styles: all))
        }
    }

    @Test func negativeSpaceSizeIsMeasured() {
        let big = scene(subject: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        #expect(CoachRules.issues(for: .composition, in: big, styles: [.negativeSpace]).contains(.subjectTooBig))
        #expect(!CoachRules.issues(for: .composition, in: big).contains(.subjectTooBig))
        let small = scene(subject: CGRect(x: 0.6, y: 0.6, width: 0.15, height: 0.15))
        #expect(!CoachRules.issues(for: .composition, in: small, styles: [.negativeSpace]).contains(.subjectTooBig))
    }

    @Test func reframingIsMeasuredFromTheLayout() {
        let view = (0..<64).map { Double($0 % 8) / 8 }
        #expect(SceneAnalysis.reframeAmount(from: view, to: view) == 0)
        let turned = view.map { 1 - $0 }
        #expect(SceneAnalysis.reframeAmount(from: view, to: turned) > CoachRules.reframeThreshold)
        let jitter = view.map { $0 + 0.02 }
        #expect(SceneAnalysis.reframeAmount(from: view, to: jitter) < CoachRules.reframeThreshold)
        #expect(CoachIssue.clutteredBackground.isModelOnly)
        #expect(!CoachIssue.phoneTilted.isModelOnly)
    }

    @Test func directionsDontFlipBetweenLeftAndRight() {
        // The subject sits left of the top-left crossing, so it's guided there.
        let start = SubjectTarget.make(subject: CGRect(x: 0.1, y: 0.25, width: 0.1, height: 0.1), placement: .thirdsPoint)
        #expect(start?.aimPoint == CGPoint(x: 1.0 / 3, y: 1.0 / 3))
        // Past the middle the nearest crossing is on the right, but the box keeps its place.
        let later = SubjectTarget.make(
            subject: CGRect(x: 0.47, y: 0.28, width: 0.1, height: 0.1), placement: .thirdsPoint, previous: start
        )
        #expect(later?.aimPoint == CGPoint(x: 1.0 / 3, y: 1.0 / 3))
        // Moving just past the box counts as lined up instead of "go back".
        let before = SubjectTarget.make(subject: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2), placement: .centre)
        let past = SubjectTarget.make(
            subject: CGRect(x: 0.52, y: 0.4, width: 0.2, height: 0.2), placement: .centre, previous: before
        )
        #expect(past?.isAligned == true)
        #expect(FrameRegion.left.opposite == .right)
    }

    @Test func phoneGuidePointsTheWayToMove() throws {
        // The subject is at the far left but belongs on the left third: it has to slide right,
        // so the phone moves left, and the words, the ring and the icon all say left.
        let slideRight = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.0, y: 0.45, width: 0.1, height: 0.1), placement: .thirdsLine(1.0 / 3)
        ))
        #expect(slideRight.cameraAdvice.first?.contains("left") == true)
        #expect(slideRight.moveSymbol == "arrow.left")
        #expect(slideRight.phoneAim.x < 0.5)

        let slideLeft = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.85, y: 0.45, width: 0.1, height: 0.1), placement: .thirdsLine(2.0 / 3)
        ))
        #expect(slideLeft.cameraAdvice.first?.contains("right") == true)
        #expect(slideLeft.moveSymbol == "arrow.right")
        #expect(slideLeft.phoneAim.x > 0.5)

        // The subject is high and has to come down to the centre, so the phone points up.
        let slideDown = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.45, y: 0.05, width: 0.1, height: 0.1), placement: .centre
        ))
        #expect(slideDown.cameraAdvice.first?.contains("up") == true)
        #expect(slideDown.moveSymbol == "arrow.up")
        #expect(slideDown.phoneAim.y < 0.5)
    }

    @Test func plainBackgroundsArentClutter() {
        var plain = scene()
        plain.backgroundBusyness = 0.02
        var busy = scene()
        busy.backgroundBusyness = 0.3

        let glassDoors = IssueDetail(region: .background, rawThing: "glass doors")
        let wall = IssueDetail(region: .background, rawThing: "the wall")
        let lampPost = IssueDetail(region: .background, rawThing: "the lamp post")
        #expect(!CoachRules.believes(.clutteredBackground, detail: glassDoors, analysis: plain))
        #expect(!CoachRules.believes(.clutteredBackground, detail: wall, analysis: plain))
        #expect(!CoachRules.believes(.distractingEdges, detail: wall, analysis: plain))
        // Even a real object isn't clutter when the background measures plain.
        #expect(!CoachRules.believes(.clutteredBackground, detail: lampPost, analysis: plain))
        #expect(CoachRules.believes(.clutteredBackground, detail: lampPost, analysis: busy))
        // A window onto a busy street is a real distraction.
        #expect(CoachRules.believes(.clutteredBackground, detail: IssueDetail(region: .background, rawThing: "window"), analysis: busy))
        // Other issues aren't touched.
        #expect(CoachRules.believes(.subjectCutOff, detail: wall, analysis: plain))
    }

    @Test func compositionChecksHeadroom() {
        let cutOff = CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.2)
        #expect(CoachRules.issues(for: .composition, in: scene(faces: [cutOff])).contains(.headCutOff))
        #expect(!AdviceTopic.allCases.map(\.rawValue).contains("subjectPosition"))
    }

    @Test func modelTipsKeepThePlacedSubjectInPlace() {
        let sign = IssueDetail(region: .right, rawThing: "the sign")
        let usual = CoachIssue.distractingEdges.advice(for: .composition, detail: sign)
        #expect(usual.action.contains("Move the camera"))

        let kept = CoachIssue.distractingEdges.advice(for: .composition, detail: sign, keepsPlacement: true)
        #expect(kept.action == "Step closer or zoom in a little to drop the sign")
        for direction in ["left", "right", " up", "down"] {
            #expect(!kept.action.contains(direction))
        }
        let cut = CoachIssue.subjectCutOff.advice(
            for: .composition, detail: IssueDetail(region: .top, rawThing: "the subject"), keepsPlacement: true
        )
        #expect(cut.action == "Step back so the subject fits")
        #expect(CoachIssue.vanishingPointOffCentre.undoesPlacement(.thirdsPoint))
    }

    @Test func horizonTipOnlyGivesWayWhenTheGuideFixesHeight() {
        #expect(CoachIssue.horizonThroughMiddle.undoesPlacement(.thirdsPoint))
        #expect(CoachIssue.horizonThroughMiddle.undoesPlacement(.centre))
        #expect(!CoachIssue.horizonThroughMiddle.undoesPlacement(.thirdsLine(1.0 / 3)))
        #expect(!CoachIssue.horizonThroughMiddle.undoesPlacement(.centreLine))
        #expect(CompositionGuide.guidePlacement(for: [.leadingLines]) == .thirdsPoint)
        #expect(CompositionGuide.guidePlacement(for: [.onePointPerspective]) == .centre)
        #expect(CompositionGuide.guidePlacement(for: [.ruleOfThirdsOne]) == .thirdsLine(1.0 / 3))
    }

    @Test func guideExplainsItsOwnPlacement() throws {
        let centred = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), placement: .centre
        ))
        #expect(centred.placement.why.contains("centred"))
        let thirds = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), placement: .thirdsPoint
        ))
        #expect(thirds.placement.why.contains("third line"))
    }

    @Test func selfieCameraSwapsLeftAndRight() throws {
        // The subject has to slide right. On the back camera the phone moves left;
        // in the mirrored selfie view the scene follows the phone, so it moves right.
        let subject = CGRect(x: 0.0, y: 0.45, width: 0.1, height: 0.1)
        let back = try #require(SubjectTarget.make(subject: subject, placement: .thirdsLine(1.0 / 3)))
        let selfie = try #require(SubjectTarget.make(subject: subject, placement: .thirdsLine(1.0 / 3), isMirrored: true))
        #expect(back.moveSymbol == "arrow.left")
        #expect(selfie.moveSymbol == "arrow.right")
        #expect(selfie.cameraAdvice.first?.contains("right") == true)
        #expect(selfie.phoneAim.x > 0.5)

        var sign = IssueDetail(region: .right, rawThing: "the sign")
        sign.isMirrored = true
        #expect(CoachIssue.distractingEdges.advice(for: .composition, detail: sign).action
            == "Move the camera slightly right to drop the sign")
        // Up and down aren't mirrored.
        var top = IssueDetail(region: .top, rawThing: "the subject")
        top.isMirrored = true
        #expect(CoachIssue.subjectCutOff.advice(for: .composition, detail: top).symbol == "arrow.up")

        // The person holding the phone is usually the subject, so no step side is given.
        var clutter = IssueDetail(region: .background, rawThing: "the lamp post")
        clutter.subjectBox = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        clutter.box = CGRect(x: 0.38, y: 0.1, width: 0.05, height: 0.6)
        #expect(clutter.stepSide == .left)
        clutter.isMirrored = true
        #expect(clutter.stepSide == nil)
    }

    @Test func tipsThatUndoEachOtherConflict() {
        let left = Advice(action: "a", why: "", symbol: "arrow.left")
        let right = Advice(action: "b", why: "", symbol: "arrow.right")
        let up = Advice(action: "c", why: "", symbol: "arrow.up")
        let upRight = Advice(action: "d", why: "", symbol: "arrow.up.right")
        let closer = Advice(action: "e", why: "", symbol: "arrow.up.left.and.arrow.down.right")
        let back = Advice(action: "f", why: "", symbol: "arrow.down.right.and.arrow.up.left")
        #expect(left.conflicts(with: right))
        #expect(left.conflicts(with: upRight))
        #expect(!left.conflicts(with: up))
        #expect(closer.conflicts(with: back))
        #expect(!closer.conflicts(with: left))
        #expect(!Advice(action: "g", why: "").conflicts(with: left))
    }

    @Test func modelNamesAreCheckedAgainstWhatVisionSees() {
        let sign = IssueDetail(region: .right, rawThing: "the sign")
        #expect(!sign.matches(labels: [("tree", 0.8)]))
        #expect(sign.matches(labels: [("signboard", 0.6)]))
        // Different words for the same thing.
        let post = IssueDetail(region: .background, rawThing: "the lamp post")
        #expect(post.matches(labels: [("streetlight", 0.7)]))
        #expect(IssueDetail(region: .left, rawThing: "cars").matches(labels: [("vehicle", 0.9)]))
        // When Vision isn't sure, the model gets the benefit of the doubt.
        #expect(IssueDetail(region: .left, rawThing: "the bench").matches(labels: [("tree", 0.2)]))
        #expect(IssueDetail(region: .left, rawThing: "the bench").matches(labels: []))
    }

    @Test func praiseMustMatchTheMeasurements() {
        #expect(CoachRules.contradicts(strength: "Bright, even light", analysis: scene(brightness: 0.1)))
        #expect(!CoachRules.contradicts(strength: "Bright, even light", analysis: scene()))
        #expect(CoachRules.contradicts(strength: "Sharp details", analysis: scene(sharpness: 10)))
        #expect(CoachRules.contradicts(strength: "Level horizon", analysis: scene(tilt: 6)))
        var busy = scene()
        busy.backgroundBusyness = 0.3
        #expect(CoachRules.contradicts(strength: "Clean background", analysis: busy))
        var plain = scene()
        plain.backgroundBusyness = 0.02
        #expect(!CoachRules.contradicts(strength: "Clean background", analysis: plain))
        #expect(!CoachRules.contradicts(strength: "Strong lines", analysis: busy))
        #expect(CoachRules.blamesPlainSurface("Avoid the glass doors behind them"))
        #expect(!CoachRules.blamesPlainSurface("Stand in front of a plain wall"))
    }

    @Test func distanceAdviceNamesAZoomButton() {
        let stops = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 120, iso: 100, zoom: 1, zoomStops: [0.5, 1, 2, 5])
        func tiny(_ side: CGFloat, zoom: Double = 1) -> SceneAnalysis {
            var readings = stops
            readings.zoom = zoom
            return scene(subject: CGRect(x: 0.4, y: 0.4, width: side, height: side), readings: readings)
        }
        // 1% of the frame needs about 2.4× to fill 6%, so the 5× button; 1.5% needs exactly 2×.
        #expect(CoachIssue.subjectTooSmall.distanceAction(tiny(0.1)) == "Zoom to 5×, or walk closer")
        #expect(CoachIssue.subjectTooSmall.distanceAction(tiny(0.1225)) == "Zoom to 2×, or walk closer")
        #expect(CoachIssue.subjectTooSmall.distanceAction(tiny(0.05, zoom: 5)) == "Walk a few steps closer")
        #expect(CoachIssue.subjectCutOff.distanceAction(tiny(0.5, zoom: 2)) == "Zoom out to 1×, or step back")
        #expect(CoachIssue.subjectCutOff.distanceAction(tiny(0.5, zoom: 0.5)) == nil)
        #expect(CoachIssue.subjectTooSmall.advice(for: .composition, analysis: tiny(0.1225)).action == "Zoom to 2×, or walk closer")
    }

    @Test func guideSaysHowFarToTurn() throws {
        // The subject must slide 0.17 of a 60° view: about 10°.
        let target = try #require(SubjectTarget.make(
            subject: CGRect(x: 0.1133, y: 0.45, width: 0.1, height: 0.1), placement: .thirdsLine(1.0 / 3),
            fieldOfView: FieldOfView(horizontal: 60, vertical: 75)
        ))
        #expect(target.cameraAdvice.first == "Turn the phone about 10° left until the dot is in the circle")
        #expect(FieldOfView.degrees(0.01, across: 60) == 5)
        // The view is narrower across the short side of the sensor.
        let readings = CameraReadings(fieldOfView: 70)
        let portrait = try #require(readings.viewSpan(isLandscape: false))
        #expect(portrait.horizontal < portrait.vertical)
    }

    @Test func scenesGetTheirOwnWording() {
        func kind(_ type: SceneType) -> SceneAnalysis {
            var analysis = scene()
            analysis.scene = type
            return analysis
        }
        #expect(CoachIssue.subjectCutOff.advice(for: .composition, analysis: kind(.people)).action.contains("joints"))
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, analysis: kind(.nature)).action.contains("plain area"))
        #expect(CoachIssue.linesDontLead.advice(for: .composition, analysis: kind(.city)).action.contains("street"))
        #expect(CoachIssue.distractingEdges.advice(for: .composition, analysis: kind(.food)).action.contains("cups"))
    }

    @Test func summaryStatesWhereTheSubjectIs() {
        let highLeft = scene(subject: CGRect(x: 0.28, y: 0.1, width: 0.1, height: 0.2))
        #expect(highLeft.positionPhrase == "the subject is on the left third, high up, filling under 5% of the frame")
        let centred = scene(subject: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
        #expect(centred.positionPhrase == "the subject is in the centre, filling about 10% of the frame")
        #expect(centred.summary.contains("in the centre"))
        // A head at the top edge is said, and is the same test the cut-off rule uses.
        let cutOff = scene(faces: [CGRect(x: 0.4, y: 0.01, width: 0.2, height: 0.2)])
        #expect(cutOff.summary.contains("a head touches the top edge"))
        #expect(CoachRules.issues(for: .composition, in: cutOff).contains(.headCutOff))
        #expect(scene(subject: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3)).summary.contains("runs off the edge"))
        #expect(scene(subject: nil).positionPhrase == nil)
    }

    @Test func modelHearsWhatTheRulesAreHandling() throws {
        let small = try #require(CoachRules.handledNote(issues: [.subjectTooSmall], keepsPlacement: false, placement: .thirdsPoint))
        #expect(small.contains("step closer or zoom"))
        let placed = try #require(CoachRules.handledNote(issues: [], keepsPlacement: true, placement: .thirdsPoint))
        #expect(placed.contains("on a thirds crossing"))
        #expect(placed.contains("don't suggest moving the camera"))
        #expect(CoachRules.handledNote(issues: [], keepsPlacement: false, placement: .centre) == nil)
        // Exposure tips the camera is giving are passed on, so the model doesn't report brightness.
        let sky = try #require(CoachRules.handledNote(issues: [.highlightsClipped, .highISO], keepsPlacement: false, placement: .centre))
        #expect(sky.contains("bright areas turning white and grain"))
        #expect(sky.contains("don't report brightness"))
    }

    @Test func everydayExposureTipsDontStopTheLightModel() {
        // A clipped sky or a high ISO indoors is common, and doesn't hide hard shadows or glare.
        for issue: CoachIssue in [.highlightsClipped, .highISO, .underexposed, .overexposed] {
            #expect(!issue.blocksModel(in: .light))
            #expect(issue.blocksModel(in: .composition))
        }
        // The big light problems still come first, before the model judges the light.
        for issue in CoachRules.bigLightIssues + [.harshContrast] {
            #expect(issue.blocksModel(in: .light))
        }
        #expect(!CoachIssue.subjectTooSmall.blocksModel(in: .composition))
    }

    /// A face-sized patch, with its left and right halves at the given brightness (0...1).
    private func faceImage(left: Double, right: Double) -> GrayImage? {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: left, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        context.setFillColor(gray: right, alpha: 1)
        context.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return context.makeImage().flatMap { GrayImage($0, width: size) }
    }

    @Test func halfAFaceInDeepShadowIsCalledOut() throws {
        let face = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        // Lit hard from one side, the far half nearly black: a problem, and no "even light" praise.
        let splitImage = try #require(faceImage(left: 0.8, right: 0.15))
        let split = try #require(SceneAnalysis.faceShadowRatio(of: face, in: splitImage))
        #expect(split < CoachRules.faceShadowLimit)
        var analysis = scene(faces: face)
        analysis.faceShadowRatio = split
        #expect(CoachRules.issues(for: .light, in: analysis).contains(.faceHalfInShadow))
        #expect(!CoachRules.strengths(for: .light, in: analysis).contains("Soft, even light"))
        // The model's "partial lighting is good" is thrown out while the shadow is measured.
        #expect(CoachRules.contradicts(strength: "Partial lighting", analysis: analysis))
        // Soft side light, with the far side only a little darker, is fine.
        let softImage = try #require(faceImage(left: 0.8, right: 0.55))
        let soft = try #require(SceneAnalysis.faceShadowRatio(of: face, in: softImage))
        analysis.faceShadowRatio = soft
        #expect(!CoachRules.issues(for: .light, in: analysis).contains(.faceHalfInShadow))
    }

    @Test func lightJudgesTheQualityOfLight() {
        // Light asks the model about the light itself, and only about that.
        #expect(CoachRules.usesModel(.light))
        #expect(CoachRules.allows(.hardShadowsOnSubject, for: .light))
        #expect(CoachRules.allows(.patchyLight, for: .light))
        #expect(!CoachRules.allows(.clutteredBackground, for: .light))
        // Composition doesn't judge the light, even with every style picked.
        #expect(!CoachRules.allows(.flatLight, for: .composition, styles: Set(CompositionGuide.allCases)))
        // Exposure, Focus and Angle & Perspective stay measured only.
        #expect(!CoachRules.usesModel(.focus) && !CoachRules.usesModel(.anglePerspective))
        // Light tips are model-only, but moving the camera doesn't change the light, so reframing
        // doesn't clear them the way it clears other model tips.
        #expect(CoachIssue.patchyLight.isModelOnly)
        #expect(CoachIssue.patchyLight.isLightQuality)
        #expect(!CoachIssue.clutteredBackground.isLightQuality)
        #expect(!CoachRules.showsSecondTip(for: .light))
        // Shadows need a subject to fall on.
        var empty = SceneAnalysis(brightness: 0.5, highlightClip: 0, shadowClip: 0, subject: nil, subjectBrightness: nil,
                                  backgroundBrightness: nil, subjectSharpness: 100, faces: [], readings: CameraReadings(),
                                  pitch: nil, tilt: nil, shake: nil, scene: .object, people: [], layout: [])
        #expect(!CoachRules.believes(.hardShadowsOnSubject, detail: nil, analysis: empty))
        empty.subject = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        empty.subjectContrast = 0.2
        #expect(CoachRules.believes(.hardShadowsOnSubject, detail: nil, analysis: empty))
        // A subject with no light and dark in it can't be patchy.
        empty.subjectContrast = 0.01
        #expect(!CoachRules.believes(.patchyLight, detail: nil, analysis: empty))
    }

    @Test func compositionShowsOneTip() {
        // Composition mixes rule and model tips, so it shows one; other topics' tips are all rules.
        #expect(!CoachRules.showsSecondTip(for: .composition))
        #expect(CoachRules.showsSecondTip(for: .focus))
    }

    @Test func coachSaysWhyAppleIntelligenceIsMissing() {
        #expect(CoachRules.modelNotice(for: .available) == nil)
        #expect(CoachRules.modelNotice(for: .unavailable(.appleIntelligenceNotEnabled))?.contains("Turn it on in Settings") == true)
        #expect(CoachRules.modelNotice(for: .unavailable(.deviceNotEligible))?.contains("doesn't support") == true)
        #expect(CoachRules.modelNotice(for: .unavailable(.modelNotReady))?.contains("downloading") == true)
        // Every case says what still works and what's missing, so the simpler tips aren't a surprise.
        for reason: SystemLanguageModel.Availability.UnavailableReason in [.appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady] {
            let notice = CoachRules.modelNotice(for: .unavailable(reason)) ?? ""
            #expect(notice.contains("framing, brightness and angle tips"))
            #expect(notice.contains("can't judge backgrounds"))
        }
    }

    @Test func alertSaysAdviceMayNotBeAsGood() {
        #expect(CoachRules.modelAlert(for: .available) == nil)
        let reasons: [SystemLanguageModel.Availability.UnavailableReason] = [.appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady]
        let alerts = reasons.compactMap { CoachRules.modelAlert(for: .unavailable($0)) }
        #expect(alerts.count == 3)
        // Each reason alerts on its own, and every alert says what it means for the advice.
        #expect(Set(alerts.map(\.key)).count == 3)
        for alert in alerts {
            #expect(alert.message.localizedCaseInsensitiveContains("advice may not be as good"))
            #expect(alert.message.contains("framing, brightness and angle tips"))
        }
        #expect(CoachRules.modelAlert(for: .unavailable(.appleIntelligenceNotEnabled))?.message.contains("Settings") == true)
    }

    @Test func stylesThatNeedAppleIntelligenceAreMarked() {
        #expect(CompositionGuide.leadingLines.needsAppleIntelligence)
        #expect(CompositionGuide.symmetry.needsAppleIntelligence)
        #expect(!CompositionGuide.ruleOfThirdsOne.needsAppleIntelligence)
        #expect(!CompositionGuide.centre.needsAppleIntelligence)
    }

    @Test func tapToFocusFindsTheSpotOnTheSensor() {
        // Held upright, the back sensor's frames are turned right: the top of the view is the sensor's left side.
        let topLeft = FrameMapping.sensorPoint(forUpright: CGPoint(x: 0.25, y: 0.1), orientation: .right)
        #expect(abs(topLeft.x - 0.1) < 0.001 && abs(topLeft.y - 0.75) < 0.001)
        // Held sideways the frame is already upright.
        #expect(FrameMapping.sensorPoint(forUpright: CGPoint(x: 0.3, y: 0.6), orientation: .up) == CGPoint(x: 0.3, y: 0.6))
        // The middle is the middle, whichever way the phone or camera faces.
        for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            #expect(FrameMapping.sensorPoint(forUpright: CGPoint(x: 0.5, y: 0.5), orientation: orientation) == CGPoint(x: 0.5, y: 0.5))
        }
    }

    @Test func portraitBlursTheSavedPhoto() {
        #expect(PhotoControl.depth.title == "Portrait")
        // Every iPhone gets Portrait: without depth hardware it blurs behind people instead.
        #expect(!CameraManager.unsupportedControls.contains(.depth))
        // Portrait alone is enough to edit the photo; a plain 4:3 standard shot is saved as taken.
        #expect(PhotoCaptureProcessor.needsEdit(ratio: .fourByThree, style: .standard, portrait: true))
        #expect(!PhotoCaptureProcessor.needsEdit(ratio: .fourByThree, style: .standard, portrait: false))
    }

    @Test func unsupportedCameraControlsAreHidden() {
        let model = PhotoControlsModel(topic: .composition, unsupported: [.lensAperture, .depth, .centerStage])
        #expect(!model.availableControls.contains(.lensAperture))
        #expect(!model.availableControls.contains(.depth))
        #expect(!model.availableControls.contains(.centerStage))
        #expect(model.availableControls.contains(.timer))
        // A topic's default that the phone can't offer is replaced, never shown.
        for topic in AdviceTopic.allCases {
            #expect(model.defaults(for: topic).allSatisfy(model.availableControls.contains))
        }
    }

    @Test func editedPhotosKeepTheirMetadata() {
        let original: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyPixelWidth as String: 4032,
            kCGImagePropertyPixelHeight as String: 3024,
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 1.29],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensModel as String: "iPhone back camera",
                kCGImagePropertyExifPixelXDimension as String: 4032,
            ],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6],
        ]
        let kept = PhotoCaptureProcessor.metadata(from: original)
        // The edited pixels are already upright and cropped, so those fields are reset or dropped.
        #expect(kept[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(kept[kCGImagePropertyPixelWidth as String] == nil)
        let exif = kept[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension as String] == nil)
        #expect(exif?[kCGImagePropertyExifLensModel as String] as? String == "iPhone back camera")
        let tiff = kept[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        #expect(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
        // Where it was taken is kept.
        #expect(kept[kCGImagePropertyGPSDictionary as String] != nil)
    }

    @Test func horizonTipNeedsAnOutdoorScene() {
        // A computer on a desk has no horizon, whatever the model says.
        #expect(!CoachRules.believes(.horizonThroughMiddle, detail: nil, analysis: scene()))
        var landscape = scene()
        landscape.scene = .landscape
        #expect(CoachRules.believes(.horizonThroughMiddle, detail: nil, analysis: landscape))
    }

    @Test func adviceOnlyFiresWhereItMakesSense() {
        // A dark laptop on a white desk is darker than the desk, but it isn't backlit.
        #expect(!scene(subjectBrightness: 0.15, backgroundBrightness: 0.8).isBacklit)
        #expect(scene(subjectBrightness: 0.15, backgroundBrightness: 0.9).isBacklit)

        // A plain mug can't be called soft: there's no detail to judge.
        var plainMug = scene(sharpness: 10)
        plainMug.subjectContrast = 0.02
        #expect(!CoachRules.issues(for: .focus, in: plainMug).contains(.subjectSoft))
        var blurryBook = scene(sharpness: 10)
        blurryBook.subjectContrast = 0.15
        #expect(CoachRules.issues(for: .focus, in: blurryBook).contains(.subjectSoft))

        // Pointing up only matters for buildings, not the sky or a tree.
        #expect(!CoachRules.issues(for: .anglePerspective, in: scene(pitch: 40)).contains(.pointingUp))
        var building = scene(pitch: 40)
        building.scene = .city
        #expect(CoachRules.issues(for: .anglePerspective, in: building).contains(.pointingUp))

        // A small, distant face is a full-body shot, not too much headroom.
        let farAway = CGRect(x: 0.45, y: 0.5, width: 0.03, height: 0.04)
        #expect(!CoachRules.issues(for: .composition, in: scene(faces: [farAway])).contains(.tooMuchHeadroom))

        // Negative Space wants the subject small.
        let tiny = scene(subject: CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1))
        #expect(CoachRules.issues(for: .composition, in: tiny).contains(.subjectTooSmall))
        #expect(!CoachRules.issues(for: .composition, in: tiny, styles: [.negativeSpace]).contains(.subjectTooSmall))

        // Joints belong to people.
        #expect(!CoachRules.believes(.jointsCropped, detail: nil, analysis: scene()))
        #expect(CoachRules.believes(.jointsCropped, detail: nil, analysis: scene(faces: [CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)])))

        // Desks and toy cars aren't city scenes.
        #expect(SceneType.classify(labels: [("structure", 0.8), ("car", 0.6)], faces: []) == .object)
    }

    @Test func subjectCutOffNeedsAnEdge() {
        #expect(scene(subject: CGRect(x: 0, y: 0.3, width: 0.4, height: 0.4)).subjectTouchesEdge)
        #expect(!scene(subject: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)).subjectTouchesEdge)
    }

    @Test func tinySubjectNeedsToFillTheFrame() {
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        #expect(CoachRules.issues(for: .composition, in: scene(subject: tiny)).contains(.subjectTooSmall))
    }

    @Test func modelIssuesAreFilteredByTopic() {
        #expect(CoachRules.allows(.clutteredBackground, for: .composition))
        // Only Composition looks at the background and other objects.
        #expect(!CoachRules.allows(.clutteredBackground, for: .anglePerspective))
        #expect(!CoachRules.usesModel(.anglePerspective))
        #expect(CoachRules.usesModel(.composition))
        #expect(!CoachRules.allows(.subjectCutOff, for: .focus))
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
        #expect(CoachRules.issues(for: .anglePerspective, in: scene(tilt: 5)).contains(.phoneTilted))
        // 3.5° is too small to start a warning, but not level enough to clear one.
        #expect(!CoachRules.issues(for: .anglePerspective, in: scene(tilt: 3.5)).contains(.phoneTilted))
        #expect(CoachRules.issues(for: .anglePerspective, in: scene(tilt: 3.5), tiltShown: true).contains(.phoneTilted))
        // Close enough by hand counts as level; it never asks for a perfect 1°.
        #expect(!CoachRules.issues(for: .anglePerspective, in: scene(tilt: 2.5), tiltShown: true).contains(.phoneTilted))
        #expect(!CoachRules.strengths(for: .anglePerspective, in: scene(tilt: 3.5), tiltShown: true).contains("Phone is level"))
    }

    @Test func compositionNeverAsksToRotateOrAngleThePhone() {
        let tilted = scene(pitch: 40, tilt: 10)
        #expect(!CoachRules.issues(for: .composition, in: tilted).contains(.phoneTilted))
        #expect(!CoachRules.strengths(for: .composition, in: scene(tilt: 0)).contains("Phone is level"))
        let allStyles = Set(CompositionGuide.allCases)
        for issue in [VisualIssue.linesNotStraight, .notOverhead] {
            #expect(!CoachRules.allows(issue, for: .composition, styles: allStyles))
        }
    }

    @Test func subjectBoxForgivesSmallOffsetsAndHoldsOnceAligned() {
        // Target is the centre; subjects are offset to the right of it.
        func target(offset: CGFloat, wasAligned: Bool) -> SubjectTarget? {
            SubjectTarget.make(
                subject: CGRect(x: 0.4 + offset, y: 0.4, width: 0.2, height: 0.2),
                placement: .centre,
                wasAligned: wasAligned
            )
        }
        #expect(target(offset: 0.08, wasAligned: false)?.isAligned == true)
        #expect(target(offset: 0.12, wasAligned: false)?.isAligned == false)
        #expect(target(offset: 0.12, wasAligned: true)?.isAligned == true)
        #expect(target(offset: 0.2, wasAligned: true)?.isAligned == false)
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
        #expect(edge.action == "Move the camera slightly left to drop the bright sign")
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

    @Test func clutterAdviceSaysWhichWayToStep() {
        let subject = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        var detail = IssueDetail(region: .background, rawThing: "the lamp post")
        detail.subjectBox = subject

        // Clutter just left of the subject: stepping left slides it out from behind.
        detail.box = CGRect(x: 0.38, y: 0.1, width: 0.05, height: 0.6)
        let left = CoachIssue.clutteredBackground.advice(for: .anglePerspective, detail: detail)
        #expect(left.action == "Step left so the lamp post isn't behind the subject")
        #expect(left.symbol == "arrow.left")

        detail.box = CGRect(x: 0.55, y: 0.1, width: 0.05, height: 0.6)
        #expect(CoachIssue.clutteredBackground.advice(for: .anglePerspective, detail: detail).symbol == "arrow.right")

        // Straight behind, or not found: either way works, and the advice says so.
        detail.box = nil
        #expect(CoachIssue.clutteredBackground.advice(for: .anglePerspective, detail: detail).action.hasPrefix("Step left or right"))
    }

    @Test func adviceNamesTheTappedSubject() {
        let detail = IssueDetail(region: .background, rawThing: "the sign", subjectName: "cup")
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, detail: detail).action.hasSuffix("behind the cup"))
        // Vague names read worse than "the subject".
        #expect(IssueDetail(region: .background, rawThing: "sign", subjectName: "object").subjectPhrase == "the subject")
        // The tapped thing itself is never called a distraction.
        #expect(IssueDetail(region: .background, rawThing: "the cup", subjectName: "cup").distraction == nil)
    }

    @Test func highlightPicksTheNamedThingNotTheSubject() {
        let subject = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let insideSubject = CGRect(x: 0.42, y: 0.35, width: 0.15, height: 0.3)
        let leftSign = CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.1)
        let behind = CGRect(x: 0.55, y: 0.1, width: 0.08, height: 0.5)
        let candidates = [insideSubject, leftSign, behind]

        #expect(CoachHighlight.bestCandidate(in: .left, subject: subject, among: candidates) == leftSign)
        #expect(CoachHighlight.bestCandidate(in: .background, subject: subject, among: candidates) == behind)
        // Nothing stands out on the right, so that side of the frame is shown instead.
        let right = CoachHighlight.locate(in: .right, subject: subject, among: candidates)
        #expect(right?.isArea == true)
        #expect(right.map { $0.box.minX >= 0.7 } == true)
        #expect(CoachHighlight.locate(in: .whole, subject: subject, among: candidates) == nil)
    }

    @Test func peopleAreAlwaysTheSubject() {
        #expect(IssueDetail.cleanedThing("the woman") == "the subject")
        #expect(IssueDetail.cleanedThing("two friends") == "the subjects")
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
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, analysis: food).action.contains("table"))
        var landscape = scene()
        landscape.scene = .landscape
        #expect(CoachIssue.horizonThroughMiddle.advice(for: .composition, analysis: landscape).action.contains("bottom third"))
        // Other scenes keep the usual wording.
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, analysis: scene()) == CoachIssue.clutteredBackground.advice(for: .composition))

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

    @Test func holdOrientationFollowsThePhone() {
        #expect(HoldOrientation(.portrait) == .portrait)
        #expect(HoldOrientation(.portraitUpsideDown) == .portrait)
        #expect(HoldOrientation(.landscapeLeft) == .landscapeLeft)
        #expect(HoldOrientation(.landscapeRight) == .landscapeRight)
        #expect(HoldOrientation(.faceUp) == nil)
    }

    @Test func landscapeTurnsIconsToFaceThePerson() {
        #expect(HoldOrientation.portrait.uiRotation == .zero)
        #expect(HoldOrientation.landscapeLeft.uiRotation == .degrees(90))
        #expect(HoldOrientation.landscapeRight.uiRotation == .degrees(-90))
        #expect(HoldOrientation.portrait.frameOrientation(isFrontCamera: false) == .right)
        #expect(HoldOrientation.landscapeLeft.frameOrientation(isFrontCamera: false) == .up)
        #expect(HoldOrientation.landscapeRight.frameOrientation(isFrontCamera: false) == .down)
    }
}

/// Each photo's story, and grouping the gallery by the mode it was taken in.
struct GalleryStoryTests {
    private let record = ShotRecord(
        topicID: AdviceTopic.light.rawValue,
        styles: [],
        scene: "Food",
        wasReady: false,
        fixed: ["found better light"],
        praised: ["Soft side light"],
        suggestion: "Turn so the window is beside you",
        date: Date(timeIntervalSince1970: 1_000_000)
    )

    @Test func recordsSurviveSavingAndLoading() throws {
        let data = try JSONEncoder().encode([ "photo": record ])
        let loaded = try JSONDecoder().decode([String: ShotRecord].self, from: data)
        #expect(loaded["photo"] == record)
        #expect(loaded["photo"]?.topic == .light)
    }

    @Test func oldExposurePhotosJoinLightAndExposure() {
        var old = record
        old.topicID = "exposure"
        #expect(old.topic == .light)
        #expect(AdviceTopic.stored("exposure") == .light)
        #expect(AdviceTopic.allCases.map(\.title) == ["Light & Exposure", "Composition", "Angle & Perspective", "Focus"])
    }

    @Test func anUnknownModeIsTreatedAsAnEarlierPhoto() {
        var renamed = record
        renamed.topicID = "somethingRemoved"
        #expect(renamed.topic == nil)
    }

    @Test @MainActor func coachRecordsWhatWasFixedUntilTheNextShot() {
        let coach = PhotoCoach()
        let shot = coach.shotRecord(topic: .composition, styles: [.ruleOfThirdsOne, .centre])
        #expect(shot.topic == .composition)
        #expect(shot.styles == CompositionGuide.allCases.filter([.ruleOfThirdsOne, .centre].contains).map(\.title))
        #expect(coach.shotRecord(topic: .light, styles: [.ruleOfThirdsOne]).styles.isEmpty)
        #expect(shot.modes?.map(\.topicID) == [AdviceTopic.composition.rawValue])
        coach.noteShutter()
        #expect(coach.progressSinceShot.isEmpty)
    }

    @Test func photosSavedBeforeModesWereKeptLookTheSame() throws {
        // The JSON an older version saved, with no "modes".
        var old = record
        old.modes = nil
        let data = try JSONEncoder().encode(old)
        let loaded = try JSONDecoder().decode(ShotRecord.self, from: data)
        #expect(loaded.results == [ModeResult(topicID: "light", fixed: ["found better light"], praised: ["Soft side light"])])
        #expect(loaded.filedTopic == .light)
        #expect(loaded.topics == [.light])
    }

    @Test func eachModeKeepsItsOwnFixes() {
        var progress = ShotProgress()
        progress.noteFixed("found better light", in: .light, styles: [])
        progress.noteState(of: .light, styles: [], praised: ["Soft light"], wasReady: true)
        // Only looked at, nothing done: not kept.
        progress.noteState(of: .focus, styles: [], praised: [], wasReady: false)
        progress.noteFixed("cleared the edges", in: .composition, styles: ["Rule of Thirds"])
        let results = progress.results(current: .composition)
        #expect(results.map(\.topic) == [.light, .composition])
        #expect(results[0].fixed == ["found better light"])
        #expect(results[0].praised == ["Soft light"])
        #expect(results[1].fixed == ["cleared the edges"])
        #expect(results[1].styles == ["Rule of Thirds"])
        // The mode at the shutter is always there, even with nothing done in it yet.
        #expect(ShotProgress().results(current: .focus).map(\.topic) == [.focus])
    }

    @Test func photoIsFiledUnderTheFinishedMode() {
        var shot = record
        shot.topicID = AdviceTopic.composition.rawValue
        let light = ModeResult(topicID: "light", fixed: ["found better light"], wasReady: true)
        let framing = ModeResult(topicID: "composition", fixed: ["cleared the edges"], wasReady: false)
        // Light was finished, framing only part done: filed under Light & Exposure.
        shot.modes = [light, framing]
        #expect(shot.filedTopic == .light)
        #expect(shot.filedWasReady)
        // Neither or both finished: filed under the mode it was taken in.
        var unfinished = light
        unfinished.wasReady = false
        shot.modes = [unfinished, framing]
        #expect(shot.filedTopic == .composition)
        var finished = framing
        finished.wasReady = true
        shot.modes = [light, finished]
        #expect(shot.filedTopic == .composition)
        #expect(shot.topics == [.light, .composition])
    }
}

extension GalleryStoryTests {
    @Test func galleryGroupsPhotosByModeNewestFirst() {
        // Newest first, as the gallery keeps them; "old" has no story.
        let photos = ["c2", "l1", "old", "c1"]
        let topics: [String: AdviceTopic] = ["c2": .composition, "c1": .composition, "l1": .light]
        let sections = GallerySection.grouped(photos, topicOf: { topics[$0] })
        // Sections follow the shooting order: Light & Exposure, then Composition.
        #expect(sections.map(\.topic) == [.light, .composition, nil])
        #expect(sections[1].items == ["c2", "c1"])
        #expect(sections.last?.items == ["old"])

        let lightOnly = GallerySection.grouped(photos, topicOf: { topics[$0] }, filter: .light)
        #expect(lightOnly.count == 1)
        #expect(lightOnly.first?.items == ["l1"])
    }

    @Test func aPhotoImprovedInTwoModesIsFiledOnceButFoundByBoth() {
        let photos = ["both", "c1"]
        let filed: [String: AdviceTopic] = ["both": .composition, "c1": .composition]
        let all: [String: [AdviceTopic]] = ["both": [.light, .composition], "c1": [.composition]]
        let sections = GallerySection.grouped(photos, topicOf: { filed[$0] }, topicsOf: { all[$0] ?? [] })
        #expect(sections.map(\.topic) == [.composition])
        #expect(sections[0].items == ["both", "c1"])
        let light = GallerySection.grouped(photos, topicOf: { filed[$0] }, topicsOf: { all[$0] ?? [] }, filter: .light)
        #expect(light.first?.items == ["both"])
    }
}

/// Names on screen wrap whole, never as "Per-spective".
struct TextWrappingTests {
    @Test func namesAreKeptTogetherButReadTheSame() {
        let shown = "Angle & Perspective".keptTogether
        #expect(!shown.contains(" "))
        #expect(shown.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ") == "Angle & Perspective")
        #expect(AdviceTopic.anglePerspective.title == "Angle & Perspective")
    }

    @Test func unhyphenatedTextCanStillWrapBetweenWords() {
        let shown = "One Point Perspective".unhyphenated
        #expect(shown.components(separatedBy: " ").count == 3)
        #expect(shown.contains("P\u{2060}e"))
    }
}

/// Light & Exposure: finding the light, who moves, and keeping what's being photographed in the shot.
@MainActor
struct LightCoachTests {
    /// A 16×16 grid with blown-out cells where `isHot` says, `around` brightness elsewhere.
    private func grids(around: Double = 0.4, isHot: (Int, Int) -> Bool) -> (hot: [[Double]], brightness: [[Double]]) {
        let hot = (0..<16).map { r in (0..<16).map { c in isHot(r, c) ? 1.0 : 0 } }
        let brightness = (0..<16).map { r in (0..<16).map { c in isHot(r, c) ? 1.0 : around } }
        return (hot, brightness)
    }

    @Test func findsASmallLightSourceButNotABrightSky() throws {
        // The sun: a 2×2 blown-out spot in the top left, darker around it.
        let sun = grids { r, c in r < 2 && c < 2 }
        let spot = try #require(LightSpotFinder.find(hot: sun.hot, brightness: sun.brightness))
        #expect(spot.minX == 0 && spot.minY == 0)
        #expect(LightSide.of(spot) == .left)
        // A whole bright sky across the top isn't one light source.
        let sky = grids { r, _ in r < 4 }
        #expect(LightSpotFinder.find(hot: sky.hot, brightness: sky.brightness) == nil)
        // A bright patch with bright surroundings is the scene, not a source.
        let glare = grids(around: 0.92) { r, c in r < 2 && c < 2 }
        #expect(LightSpotFinder.find(hot: glare.hot, brightness: glare.brightness) == nil)
    }

    /// A frame for the light rules: a subject in the middle, nothing else.
    private func light(
        scene sceneType: SceneType = .object,
        backdrop: SceneType? = nil,
        faces: [CGRect] = [],
        outdoors: Bool = false,
        spot: CGRect? = nil,
        litSide: LightSide? = nil,
        shadowRatio: Double? = nil,
        backlit: Bool = false,
        subject: CGRect? = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
        frontCamera: Bool = false
    ) -> SceneAnalysis {
        var a = scene(subject: subject, subjectBrightness: backlit ? 0.2 : 0.5, backgroundBrightness: backlit ? 0.9 : 0.5, faces: faces)
        a.scene = sceneType
        a.backdrop = backdrop
        a.isOutdoors = outdoors
        a.lightSpot = spot
        a.faceLitSide = litSide
        a.faceShadowRatio = shadowRatio
        a.readings.isFrontCamera = frontCamera
        return a
    }

    private let sunTopLeft = CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1)
    private let sunTopMiddle = CGRect(x: 0.45, y: 0.05, width: 0.1, height: 0.1)
    private let smallFace = [CGRect(x: 0.45, y: 0.3, width: 0.08, height: 0.1)]
    private let bigFace = [CGRect(x: 0.35, y: 0.2, width: 0.25, height: 0.3)]

    @Test func lightSideNeedsTheMeasurementsToAgree() {
        #expect(light(outdoors: true, spot: sunTopLeft).lightSide == .left)
        // A lamp alone indoors isn't enough to name a side.
        #expect(light(spot: sunTopLeft).lightSide == nil)
        // A lamp and a face lit on the same side agree.
        #expect(light(faces: smallFace, spot: sunTopLeft, litSide: .left, shadowRatio: 0.6).lightSide == .left)
        // They disagree, so no side is named.
        #expect(light(faces: smallFace, spot: sunTopLeft, litSide: .right, shadowRatio: 0.6).lightSide == nil)
        // A face in deep shadow on one side is enough by itself.
        #expect(light(faces: smallFace, litSide: .right, shadowRatio: 0.3).lightSide == .right)
    }

    /// The tip for a scene, checked against the rules every light tip follows.
    private func tip(_ issue: CoachIssue, _ a: SceneAnalysis, keepsFraming: Bool = false) -> Advice {
        let advice = issue.advice(for: .light, analysis: a, keepsPlacement: keepsFraming)
        let words = advice.action.split(separator: " ").count
        #expect(words <= 10, "\(advice.action) is too long")
        for banned in ["point the camera", "turn away", "Turn away"] {
            #expect(!advice.action.contains(banned), "\(advice.action) loses the subject")
        }
        return advice
    }

    @Test func personWithSceneryBehindStaysAndTheLightIsBalanced() {
        // Sun behind a person with a landscape behind them: the camera stays, the face is brightened.
        let far = tip(.sunInFrame, light(scene: .people, backdrop: .landscape, faces: smallFace, outdoors: true, spot: sunTopLeft, backlit: true))
        #expect(far.mover == .settings)
        #expect(far.action == "Tap their face so the camera brightens them")
        #expect(far.quickFix == .meterOnSubject)
        // Close enough for flash to reach.
        let close = tip(.backlitSubject, light(scene: .people, backdrop: .city, faces: bigFace, outdoors: true, backlit: true))
        #expect(close.action == "Turn on Flash to light their face")
        #expect(close.quickFix == .flash)
    }

    @Test func aSubjectWithNothingBehindItGetsWalkedAround() {
        // The sun at the top left, in front of the camera: walk round to the left to put it beside you.
        let walk = tip(.sunInFrame, light(outdoors: true, spot: sunTopLeft, backlit: true))
        #expect(walk.mover == .photographer)
        #expect(walk.action == "Walk around the subject to your left, keeping it centred")
        #expect(walk.lightSide == .left)
        // No sure side: the general way, which is never wrong.
        let unsure = tip(.backlitSubject, light(spot: sunTopLeft, backlit: true))
        #expect(unsure.action == "Walk around the subject until the light is beside you")
        // Slipping off the edge while walking: keep it in the shot first.
        let slipping = tip(.backlitSubject, light(backlit: true, subject: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3)))
        #expect(slipping.action == "Keep the subject in frame: turn back toward it")
    }

    @Test func aBuildingStaysAndOnlyTheSunIsDealtWith() {
        // The sun at the left edge of a city view: a small turn right drops it out of the frame.
        let edge = tip(.sunInFrame, light(scene: .city, outdoors: true, spot: sunTopLeft))
        #expect(edge.mover == .photographer)
        #expect(edge.action == "Turn slightly right so the sun just leaves the frame")
        // The sun in the middle: something nearby hides it, the building stays.
        let middle = tip(.sunInFrame, light(scene: .city, outdoors: true, spot: sunTopMiddle))
        #expect(middle.action == "Stand so a tree or roof hides the sun")
        // A lined-up frame never moves: a setting keeps the sky instead.
        let framed = tip(.sunInFrame, light(scene: .city, outdoors: true, spot: sunTopLeft), keepsFraming: true)
        #expect(framed.mover == .settings)
        #expect(framed.quickFix == .darken)
    }

    @Test func aLinedUpFrameIsNeverMoved() {
        let kept = tip(.backlitSubject, light(backlit: true), keepsFraming: true)
        #expect(kept.mover == .settings)
        #expect(kept.why.hasPrefix("This keeps your framing."))
    }

    @Test func halfAFaceInShadowAsksTheSubjectToTurn() {
        let back = tip(.faceHalfInShadow, light(scene: .people, faces: smallFace, litSide: .left, shadowRatio: 0.3))
        #expect(back.mover == .subject)
        #expect(back.action == "Ask them to turn toward the light on your left")
        // On the front camera the subject is the person holding the phone.
        let selfie = tip(.faceHalfInShadow, light(scene: .people, faces: smallFace, litSide: .left, shadowRatio: 0.3, frontCamera: true))
        #expect(selfie.action == "Turn your face toward the light on your left")
    }

    @Test func settingsTipsComeWithAOneTapFix() {
        var dim = light()
        dim.brightness = 0.1
        let dark = tip(.tooDark, dim)
        #expect(dark.mover == .settings)
        #expect(dark.quickFix == .nightMode)
        dim.readings.isNightModeOn = true
        #expect(tip(.tooDark, dim).quickFix == nil)
    }

    @Test func theSunComesFirstAndReplacesHighlights() {
        var a = light(outdoors: true, spot: sunTopLeft)
        a.highlightClip = 0.08
        let issues = CoachRules.issues(for: .light, in: a)
        #expect(issues.first == .sunInFrame)
        #expect(!issues.contains(.highlightsClipped))
    }

    @Test func lightFirstThenFraming() {
        for issue in CoachRules.bigLightIssues {
            #expect(issue.lightNudge?.hasPrefix("Light first") == true)
        }
        #expect(CoachRules.lightKeepNote(keepsFraming: false).contains("Never suggest pointing the camera"))
        #expect(CoachRules.lightKeepNote(keepsFraming: true).contains("must not change"))
        #expect(AdviceTopic.allCases.first == .light)
    }

    @Test func timeOfDayOnlyOutdoors() {
        #expect(CoachRules.timeOfDayHint(hour: 7, outdoors: true)?.contains("soft") == true)
        #expect(CoachRules.timeOfDayHint(hour: 12, outdoors: true)?.contains("harsh") == true)
        #expect(CoachRules.timeOfDayHint(hour: 12, outdoors: false) == nil)
        #expect(CoachRules.timeOfDayHint(hour: 22, outdoors: true) == nil)
    }
}

/// The first-launch tour teaches tap and drag before the double tap, and shows the light signals.
struct TourTests {
    @Test func brightnessIsTaughtRightBeforePickingTheSubject() throws {
        let steps = OnboardingStep.allCases
        let brightness = try #require(steps.firstIndex(of: .brightness))
        #expect(steps[brightness + 1] == .selectObject)
        #expect(OnboardingStep.brightness.placesCardOnControls)
        #expect(OnboardingStep.brightness.instruction.contains("drag up or down"))
        #expect(OnboardingStep.selectObject.instruction.hasPrefix("Now double-tap"))
    }

    @Test func theLightPreviewTravelsWithTheFeedback() {
        let feedback = OnboardingFeedback(text: "Light & Exposure", isComplete: false, preview: .lightSignals)
        #expect(feedback.preview == .lightSignals)
        #expect(OnboardingFeedback(text: "Composition", isComplete: true).preview == nil)
    }
}
