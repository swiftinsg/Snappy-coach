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
        #expect(CoachRules.issues(for: .exposure, in: scene(subjectBrightness: 0.2, backgroundBrightness: 0.8)).contains(.backlitSubject))
        // After dragging Exposure right the background is still brighter, but the subject is fine.
        #expect(!CoachRules.issues(for: .exposure, in: scene(subjectBrightness: 0.5, backgroundBrightness: 0.95)).contains(.backlitSubject))
    }

    @Test func lowerExposureClearsTheHighlightsTipEvenWithALampInFrame() {
        var readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 120, iso: 100)
        readings.exposureBias = -1
        #expect(!CoachRules.issues(for: .exposure, in: scene(highlightClip: 0.1, readings: readings)).contains(.highlightsClipped))
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

    @Test func noTipAsksForATapOnTheViewfinder() {
        // The viewfinder has no tap-to-focus, so tips can only name controls that exist.
        for issue in CoachIssue.allCases {
            for topic in AdviceTopic.allCases {
                for advice in [issue.advice(for: topic), issue.alternativeAdvice(for: topic)].compactMap(\.self) {
                    #expect(!advice.action.contains("Tap the subject"), "\(issue) asks for a tap")
                    #expect(!advice.action.contains("sun"), "\(issue) mentions a sun handle")
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
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [cutOff])).first == .headCutOff)
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [sunk])).first == .tooMuchHeadroom)
    }

    @Test func groupsAreCheckedForEveryone() {
        let fine = CGRect(x: 0.2, y: 0.15, width: 0.1, height: 0.12)
        let cutOff = CGRect(x: 0.6, y: 0.0, width: 0.1, height: 0.1)
        // Someone's head at the top edge is cut off, even if it isn't the biggest face.
        let bigFine = CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.2)
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [bigFine, cutOff])).contains(.headCutOff))
        // Headroom is measured above the highest head, so it works with several people.
        let low1 = CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1)
        let low2 = CGRect(x: 0.6, y: 0.45, width: 0.1, height: 0.1)
        #expect(CoachRules.issues(for: .subjectPosition, in: scene(faces: [low1, low2])).contains(.tooMuchHeadroom))
        #expect(!CoachRules.issues(for: .subjectPosition, in: scene(faces: [fine, low2])).contains(.tooMuchHeadroom))
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
        #expect(CoachRules.allows(.clutteredBackground, for: .anglePerspective))
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
        #expect(CoachIssue.clutteredBackground.advice(for: .composition, analysis: food).action.contains("plate"))
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
}
