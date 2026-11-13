//
//  BehindTheScenes.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 13/11/26.
//

import Foundation
import FoundationModels
import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Keeps the newest camera frame so the coach can look at it every few seconds.
/// It has its own video output, so it doesn't compete with the histogram's.
nonisolated final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()

    /// Small enough for the model to read quickly and keep its context window free.
    private static let longestSide: CGFloat = 768
    private let queue = DispatchQueue(label: "FrameGrabber.video")
    private let lock = NSLock()
    private let context = CIContext()
    private var latest: CVPixelBuffer?
    private var tracksSubject = false
    private var subject: (box: CGRect, aspect: CGFloat)?
    private var lastDetection = Date.distantPast

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = buffer
        let tracking = tracksSubject
        lock.unlock()

        // Looking for the subject costs a little, so only do it when the green box is on.
        guard tracking, Date().timeIntervalSince(lastDetection) > 0.3 else { return }
        lastDetection = Date()
        // Frames arrive rotated by 90°, so the upright aspect is height over width.
        let aspect = CGFloat(CVPixelBufferGetHeight(buffer)) / CGFloat(CVPixelBufferGetWidth(buffer))
        guard let box = SubjectFinder.subject(in: buffer, orientation: .right) else { return }
        lock.lock()
        subject = (box, aspect)
        lock.unlock()
    }

    func setTracksSubject(_ on: Bool) {
        lock.lock()
        tracksSubject = on
        if !on { subject = nil }
        lock.unlock()
    }

    /// The main subject's box in a recent frame, while tracking is on.
    func latestSubject() -> (box: CGRect, aspect: CGFloat)? {
        lock.lock()
        defer { lock.unlock() }
        return subject
    }

    /// The newest frame, turned upright, cropped to the viewfinder's `portraitAspect` (width ÷ height)
    /// so the coach only judges what the person can see, and shrunk so the model can read it quickly.
    func latestImage(portraitAspect: CGFloat? = nil) -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }

        // The back camera delivers frames rotated by 90°, so turn them upright.
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        if let portraitAspect, portraitAspect > 0 {
            // The preview fills its frame, so it shows the centre of the sensor image.
            let extent = image.extent
            let crop: CGRect
            if extent.width / extent.height > portraitAspect {
                let width = extent.height * portraitAspect
                crop = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
            } else {
                let height = extent.width / portraitAspect
                crop = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
            }
            image = image.cropped(to: crop)
        }
        let scale = Self.longestSide / max(image.extent.width, image.extent.height)
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.createCGImage(image, from: image.extent)
    }
}

/// Plain measurements of a frame, so the coach doesn't have to guess brightness or sharpness.
struct FrameStats {
    /// Average brightness, 0 (black) to 1 (white).
    let brightness: Double
    /// How much fine detail there is. Low values mean blurry or flat.
    let sharpness: Double

    var brightnessLabel: String {
        switch brightness {
        case ..<0.2: "very dark"
        case ..<0.35: "dark"
        case ..<0.7: "well balanced"
        case ..<0.85: "bright"
        default: "very bright"
        }
    }

    var sharpnessLabel: String {
        switch sharpness {
        case ..<15: "very blurry"
        case ..<60: "a little soft"
        default: "sharp"
        }
    }

    /// True when the exposure is clearly wrong, whatever the model thinks.
    var isBadlyExposed: Bool { brightness < 0.2 || brightness > 0.85 }

    var summary: String {
        "the picture is \(brightnessLabel) overall and \(sharpnessLabel)"
    }

    /// Measures a small grayscale copy of the frame.
    static func measure(_ image: CGImage) -> FrameStats? {
        let width = 256
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

        let mean = pixels.reduce(0) { $0 + Double($1) } / Double(pixels.count) / 255

        // Variance of the Laplacian: a standard sharpness measure.
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(pixels[y * width + x])
                let laplacian = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                    + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
                sum += laplacian
                sumOfSquares += laplacian * laplacian
                count += 1
            }
        }
        let average = sum / count
        return FrameStats(brightness: mean, sharpness: sumOfSquares / count - average * average)
    }
}

/// What the coach needs to know about each composition style in the picker.
extension CompositionGuide {
    /// Where the green box puts the subject, or nil when the style isn't about subject position.
    var subjectPlacement: SubjectPlacement? {
        switch self {
        case .ruleOfThirdsOne: .thirdsLine(1.0 / 3)
        case .ruleOfThirdsTwo: .thirdsLine(2.0 / 3)
        case .ruleOfThirdsCorner, .negativeSpace: .thirdsPoint
        case .centre: .centre
        case .symmetry: .centreLine
        default: nil
        }
    }

    /// What a good photo in this style looks like, for the model to judge against.
    var coachingFocus: String {
        let tools = "Tools: move the camera, step closer or back, tilt it up or down, or tap a zoom button"
        let judged: String
        switch self {
        case .ruleOfThirdsOne:
            judged = "the Thirds 1/3 style: the main subject should sit on the left vertical third line of the frame"
        case .ruleOfThirdsTwo:
            judged = "the Thirds 2/3 style: the main subject should sit on the right vertical third line of the frame"
        case .ruleOfThirdsCorner:
            judged = "the Thirds Corner style: the main subject should sit on one of the four points where the third lines cross"
        case .centre:
            judged = "the Centre style: the main subject should be in the middle of the frame with even space around it"
        case .onePointPerspective:
            judged = "the One-Point Perspective style: lines such as a road, hallway or railway should run toward a single vanishing point, ideally near the middle of the frame, with the camera level and square-on so both sides look balanced"
        case .tableTop45:
            judged = "the Table-Top 45 degree style: a tabletop scene shot from about 45 degrees above, with the whole arrangement in frame, the table edge level and nothing cropped awkwardly"
        case .tableTop90:
            judged = "the Table-Top 90 degree aerial style: shooting straight down onto a flat surface, with the camera parallel to the surface, items arranged neatly and the frame filled evenly"
        case .leadingLines:
            judged = "the Leading Lines style: lines such as paths, edges or rails should be visible, point toward the main subject and not be cut off, so they guide the eye to it"
        case .singleVertex:
            judged = "the Single Vertex style: one point where two lines meet should be a clear focal point, near a third position, with the lines leading away from it"
        case .doubleVertex:
            judged = "the Double Vertex style: two points where lines meet should both be visible and balanced across the frame, leading the eye between them"
        case .triangle:
            judged = "the Triangle style: three key elements, or the lines between them, should form a triangle, with all three in frame and well spaced"
        case .leadingLinesAligning:
            judged = "the Aligning Lines style: strong straight lines such as horizons, walls and edges should be perfectly level or perfectly vertical, and parallel lines should line up with the frame edges"
        case .symmetry:
            judged = "the Symmetry style: the subject should be centred so the left and right halves mirror each other, with the camera square-on and level"
        case .halfBodyPortrait:
            judged = "the Half-Body Portrait style: a person framed from about the waist up, with the head in the upper third, a little space above the head, and no joints cropped awkwardly"
        case .compression:
            judged = "the Compression style: the subject and background should look stacked close together, as with a long lens, which needs more zoom and standing farther back, with layered elements overlapping"
        case .negativeSpace:
            judged = "the Negative Space style: a small subject should sit off-centre, surrounded by plenty of empty, uncluttered space"
        }
        return "how well the photo follows \(judged). \(tools)"
    }
}

/// What the coach shows for the current frame.
struct PhotoFeedback: Equatable {
    /// Things that already work, each a few words.
    var good: [String]
    /// What to do now, most important first.
    var improve: [String]
    /// The photography idea behind the first improvement.
    var why: String?
    /// An arrow for the first improvement, when it has a direction.
    var symbol: String? = nil
    /// True when the shot is ready to take.
    var isGoodEnough: Bool
    /// What to practise next, shown once the current section is complete.
    var nextSection: String? = nil
}

/// What the coach remembers between sections. Every model session starts empty, so this is
/// turned into one short sentence that keeps the coach from repeating itself.
struct CoachMemory: Equatable {
    /// Issues the person fixed, oldest first.
    private(set) var fixed: [CoachIssue] = []
    /// How many sections each unfixed issue has been shown in.
    private(set) var shownCounts: [CoachIssue: Int] = [:]
    /// Topics practised, oldest first. The current topic is last.
    private(set) var practised: [String] = []
    /// What the model praised in earlier sections, so it can find something new.
    private(set) var recentStrengths: [String] = []

    private static let length = 4
    /// Once an issue has been shown in this many sections without being fixed, the coach tries another way.
    static let repeatLimit = 2

    mutating func noteFixed(_ issue: CoachIssue) {
        fixed.removeAll { $0 == issue }
        fixed = Array((fixed + [issue]).suffix(Self.length))
        shownCounts[issue] = nil
    }

    mutating func noteShown(_ issue: CoachIssue) {
        shownCounts[issue, default: 0] += 1
    }

    func timesShown(_ issue: CoachIssue) -> Int {
        shownCounts[issue] ?? 0
    }

    mutating func notePractising(_ topic: AdviceTopic, styles: Set<CompositionGuide>) {
        var name = topic.title
        if topic == .composition {
            let titles = CompositionGuide.allCases.filter(styles.contains).map(\.title)
            if !titles.isEmpty { name += " (\(titles.formatted(.list(type: .and))))" }
        }
        practised.removeAll { $0 == name }
        practised = Array((practised + [name]).suffix(3))
    }

    mutating func noteStrength(_ strength: String) {
        recentStrengths.removeAll { $0 == strength }
        recentStrengths = Array((recentStrengths + [strength]).suffix(Self.length))
    }

    /// Issues shown often without being fixed go last, so another problem gets a turn.
    /// The issue already on screen keeps its place, so the card doesn't jump.
    func reordered(_ issues: [CoachIssue], keeping current: CoachIssue?) -> [CoachIssue] {
        let stale = issues.filter { $0 != current && timesShown($0) >= Self.repeatLimit }
        return issues.filter { !stale.contains($0) } + stale
    }

    /// One short sentence about what has been done so far, for the next model session.
    var sentence: String {
        var parts: [String] = []
        if practised.count > 1 {
            parts.append("Earlier the user practised \(Array(practised.dropLast()).formatted(.list(type: .and)))")
        }
        if !fixed.isEmpty {
            parts.append("They have already \(fixed.map(\.accomplishment).formatted(.list(type: .and)))")
        }
        let told = shownCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(3)
            .map(\.key.rawValue)
        if !told.isEmpty {
            parts.append("Already pointed out but not fixed yet: \(told.joined(separator: ", "))")
        }
        return parts.isEmpty ? "Nothing yet." : parts.joined(separator: ". ") + "."
    }
}

/// The auto-rendering coach. It measures the frame, asks the model only about what can't be
/// measured, and turns the result into advice from `AdviceLibrary`.
///
/// Advice is grouped into sections: a section is the time spent on one issue. When the issue is
/// fixed (or the topic changes, or a photo is taken) the section ends. Every model judgement uses a
/// fresh session, so no old context carries over; instead each session starts with one sentence
/// from `CoachMemory` about what has been done so far, so the coach doesn't repeat itself.
@Observable
final class PhotoCoach {
    /// The latest feedback shown on screen, or nil while the coach has nothing to say yet.
    private(set) var feedback: PhotoFeedback?
    /// Composition styles that don't suit the current scene, with the reason why.
    private(set) var unavailableCompositions: [CompositionGuide: String] = [:]
    /// The composition style the coach thinks suits the current scene best. Only a suggestion.
    private(set) var recommendedComposition: CompositionGuide?
    /// How much of the current section is done, 0...1, for the shutter's progress ring.
    private(set) var sectionProgress: Double = 0
    /// A message for when the coach can't run at all.
    private(set) var notice: String?
    /// Raw measurements and model output, for the hidden debug overlay.
    private(set) var debugText = ""
    /// What has been done so far, kept across topics and photos.
    private(set) var memory = CoachMemory()
    /// What kind of photo the camera is looking at, smoothed over the last few checks.
    private(set) var scene: SceneType?

    var isReady: Bool { feedback?.isGoodEnough ?? false }

    /// How often the model looks at the frame.
    private static let modelInterval: Duration = .seconds(2)
    /// How often measured-only topics refresh. Measuring is cheap, so it can be quicker.
    private static let measureInterval: Duration = .seconds(1)
    /// How long the model gets to judge a frame before the request is cancelled.
    private static let modelTimeout: Duration = .seconds(8)

    /// Shared with the on-screen level, so the line and the tilt advice always agree.
    let attitude = PhoneAttitude()
    /// Raw scene labels from the last few checks, so one odd frame doesn't change the advice.
    private var recentScenes: [SceneType] = []
    private static let sceneHistory = 3

    /// A session made ahead of time so the first judgement is quick. Used once, then dropped.
    private var session: LanguageModelSession?

    // The current section.
    /// The issue being worked on, nil when the shot is good.
    private var shownIssue: CoachIssue?
    /// Where the model saw the issue, kept for the section so the wording doesn't change every pass.
    private var sectionDetail: IssueDetail?
    /// True when the section shows the issue's other tip, because the usual one was ignored before.
    private var usesAlternative = false
    /// What the model last praised, remembered when the section ends.
    private var sectionStrength: String?
    /// How many issues the section started with, so progress can be measured against it.
    private var sectionIssueCount = 1
    /// The suggestion for what to practise after the current section, kept while it's complete.
    private var sectionRecommendation: String?

    // Hysteresis: a new verdict must repeat before it replaces what's on screen.
    private var candidate: CoachIssue??
    private var candidateCount = 0

    /// Runs until the task is cancelled. Restart it (with a new topic or selection) when the pickers change.
    func run(camera: CameraManager, topic: AdviceTopic, styles: Set<CompositionGuide>, guide: SubjectGuide) async {
        feedback = nil
        notice = nil
        candidate = nil
        candidateCount = 0
        sectionProgress = 0
        sectionRecommendation = nil
        // A new topic is a new section; the memory sentence carries what was done before.
        endSection()
        memory.notePractising(topic, styles: styles)
        // Counted, so the task being replaced can't switch motion off for this one.
        attitude.start()
        defer { attitude.stop() }

        let usesModel = CoachRules.usesModel(topic) && SystemLanguageModel.default.isAvailable
        if usesModel {
            session = makeSession(for: topic, styles: styles)
            session?.prewarm()
        }

        var isFirstPass = true
        while !Task.isCancelled {
            if !isFirstPass {
                try? await Task.sleep(for: usesModel ? Self.modelInterval : Self.measureInterval)
            }
            isFirstPass = false
            guard !Task.isCancelled, let frame = currentFrame(from: camera) else { continue }

            let readings = CameraReadings.read(from: camera)
            guard var analysis = await SceneAnalysis.analyze(
                frame, readings: readings, pitch: attitude.pitch, tilt: attitude.tilt, shake: attitude.shake
            ), !Task.isCancelled else { continue }
            recentScenes = Array((recentScenes + [analysis.scene]).suffix(Self.sceneHistory))
            if let smoothed = SceneType.smoothed(recentScenes) {
                analysis.scene = smoothed
                scene = smoothed
            }

            // Tell the picker which styles don't suit the scene.
            unavailableCompositions = CompositionGuide.unavailableStyles(in: analysis)
            // The model's suggestion: the best style for this scene that still fits what's picked.
            recommendedComposition = Self.recommendation(
                for: analysis,
                unavailable: unavailableCompositions,
                selected: styles
            )

            // Where the subject sits is geometry, so the green box decides while it's off target.
            let usesBox = topic == .subjectPosition
                || (topic == .composition && styles.contains { $0.subjectPlacement != nil })
            if usesBox, let target = guide.target, !target.isAligned {
                feedback = Self.positionFeedback(for: target)
                sectionProgress = target.progress
                continue
            }

            let tiltShown = shownIssue == .phoneTilted
            var issues = CoachRules.issues(for: topic, in: analysis, tiltShown: tiltShown)
            var good = CoachRules.strengths(for: topic, in: analysis, tiltShown: tiltShown)
            if usesBox, guide.target?.isAligned == true {
                good.insert("Subject in the green box", at: 0)
            }

            // The model is only asked when nothing it can't see past was measured, which saves
            // battery and keeps it to what it's good at: judging the look of the scene.
            var details: [CoachIssue: IssueDetail] = [:]
            var modelNote = "model: not asked"
            if usesModel, !issues.contains(where: \.blocksModel),
               let judgement = await judge(frame, topic: topic, styles: styles, analysis: analysis) {
                guard !Task.isCancelled else { break }
                modelNote = "model: \(judgement.issue.rawValue) @ \(judgement.region.rawValue) \"\(judgement.thing)\" / \(judgement.strength)"
                if CoachRules.allows(judgement.issue, for: topic, styles: styles), let issue = judgement.issue.coachIssue {
                    // What the model saw is more specific than a minor measurement, so it leads.
                    issues.removeAll { $0 == issue }
                    issues.insert(issue, at: 0)
                    details[issue] = IssueDetail(region: judgement.region, rawThing: judgement.thing)
                }
                if let strength = Self.cleanedStrength(judgement.strength) {
                    sectionStrength = strength
                    if !good.contains(strength) { good.append(strength) }
                }
            }
            issues = memory.reordered(issues, keeping: shownIssue)

            debugText = analysis.debugDescription + "\n" + modelNote + "\ndone: " + memory.sentence
            publish(
                top: issues.first,
                next: issues.dropFirst().first,
                remaining: issues.count,
                good: good,
                details: details,
                topic: topic,
                styles: styles,
                analysis: analysis
            )
        }
    }

    /// Call when a photo is taken: that finishes the current section.
    func noteShutter() {
        endSection()
    }

    // MARK: - Sections and memory

    /// Ends the current section: remembers what was done, so the next session starts from there.
    private func endSection(fixed issue: CoachIssue? = nil) {
        if let issue {
            memory.noteFixed(issue)
        }
        if let sectionStrength {
            memory.noteStrength(sectionStrength)
        }
        session = nil
        shownIssue = nil
        sectionDetail = nil
        usesAlternative = false
        sectionStrength = nil
        sectionProgress = 0
        sectionIssueCount = 1
    }

    /// Shows a verdict once it has been seen twice in a row, so the card doesn't flicker.
    private func publish(
        top: CoachIssue?,
        next: CoachIssue?,
        remaining: Int,
        good: [String],
        details: [CoachIssue: IssueDetail],
        topic: AdviceTopic,
        styles: Set<CompositionGuide>,
        analysis: SceneAnalysis
    ) {
        if candidate == .some(top) {
            candidateCount += 1
        } else {
            candidate = .some(top)
            candidateCount = 1
        }
        let isFirstVerdict = feedback == nil
        guard candidateCount >= 2 || isFirstVerdict else { return }

        let isNewSection = shownIssue != top
        // The issue being worked on has gone: that section is done.
        if let shownIssue, shownIssue != top {
            endSection(fixed: shownIssue)
        }
        shownIssue = top

        guard let top else {
            sectionProgress = 1
            if sectionRecommendation == nil {
                sectionRecommendation = nextSectionSuggestion(topic: topic, styles: styles, analysis: analysis)
            }
            feedback = PhotoFeedback(
                good: Array(good.prefix(2)),
                improve: [],
                why: nil,
                isGoodEnough: true,
                nextSection: sectionRecommendation
            )
            return
        }

        sectionRecommendation = nil
        if isNewSection {
            sectionIssueCount = max(remaining, 1)
            // The usual tip didn't work in earlier sections, so try a different one.
            usesAlternative = memory.timesShown(top) >= CoachMemory.repeatLimit
                && top.alternativeAdvice(for: topic) != nil
            memory.noteShown(top)
            sectionDetail = details[top]
        } else if let detail = details[top], detail.region != sectionDetail?.region {
            // The problem has moved, so the direction has to change too.
            sectionDetail = detail
        }
        // The ring fills as the issues in the section are cleared.
        sectionProgress = max(
            0.1,
            1 - Double(remaining) / Double(max(sectionIssueCount, remaining, 1))
        )

        let usual = top.advice(for: topic, analysis: analysis, detail: sectionDetail)
        let advice = usesAlternative ? (top.alternativeAdvice(for: topic) ?? usual) : usual
        var improve = [advice.action]
        if let next {
            improve.append(next.advice(for: topic, analysis: analysis, detail: details[next]).action)
        }
        feedback = PhotoFeedback(
            good: Array(good.prefix(2)),
            improve: improve,
            why: advice.why,
            symbol: advice.symbol,
            isGoodEnough: false
        )
    }

    /// Suggests what to practise once the current section is complete.
    private func nextSectionSuggestion(
        topic: AdviceTopic,
        styles: Set<CompositionGuide>,
        analysis: SceneAnalysis
    ) -> String? {
        if topic == .composition {
            let unavailable = CompositionGuide.unavailableStyles(in: analysis)
            let candidates = CompositionGuide.allCases.filter {
                !styles.contains($0) && unavailable[$0] == nil
            }
            if let next = Self.preferredNextStyle(for: analysis, from: candidates) {
                return "Section complete. Try the \(next.title) style next."
            }
            return "Section complete. Try another topic from the menu."
        }

        let topics = AdviceTopic.allCases
        guard topics.count > 1, let index = topics.firstIndex(of: topic) else { return nil }
        let next = topics[(index + 1) % topics.count]
        return "Section complete. Try the \(next.title) topic next."
    }

    /// Picks the style that best matches the scene, falling back to the first available one.
    private static func preferredNextStyle(
        for analysis: SceneAnalysis,
        from candidates: [CompositionGuide]
    ) -> CompositionGuide? {
        guard !candidates.isEmpty else { return nil }
        // Styles that suit this kind of scene come first.
        var preferred = analysis.scene.suitedStyles
        if !analysis.faces.isEmpty { preferred.append(.halfBodyPortrait) }
        if let pitch = analysis.pitch {
            if pitch < -55 { preferred.append(.tableTop90) }
            if pitch < -20 { preferred.append(.tableTop45) }
        }
        if analysis.subject != nil { preferred.append(.negativeSpace) }
        preferred += [
            .ruleOfThirdsCorner, .symmetry, .leadingLines, .centre,
            .leadingLinesAligning, .triangle, .onePointPerspective,
            .singleVertex, .doubleVertex, .compression,
            .ruleOfThirdsTwo, .ruleOfThirdsOne,
        ]
        return preferred.first(where: candidates.contains)
    }

    /// The style to point the person at: the best fit for the scene that also fits the
    /// styles already selected, so the suggestion is always something they can tap.
    private static func recommendation(
        for analysis: SceneAnalysis,
        unavailable: [CompositionGuide: String],
        selected: Set<CompositionGuide>
    ) -> CompositionGuide? {
        let candidates = CompositionGuide.allCases.filter { guide in
            unavailable[guide] == nil && !selected.contains(where: { $0.conflicts(with: guide) })
        }
        return preferredNextStyle(for: analysis, from: candidates)
    }

    // MARK: - The model

    /// Worked answers for the model. Only those whose issue is allowed for the topic are shown,
    /// so it isn't nudged toward an issue it can't use.
    private static let examples: [(issue: VisualIssue, text: String)] = [
        (.clutteredBackground, #"A person with a lamp post right behind their head: issue clutteredBackground, region background, thing "the lamp post", strength "Soft, even light"."#),
        (.distractingEdges, #"A bright sign at the right edge: issue distractingEdges, region right, thing "the sign", strength "Clear subject"."#),
        (.linesDontLead, #"A road running off the left side instead of toward the house: issue linesDontLead, region left, thing "the road", strength "Strong lines"."#),
        (.subjectCutOff, #"A tree cut off at the top: issue subjectCutOff, region top, thing "the tree", strength "Rich colours"."#),
        (.flatAngle, #"A flower shot from standing height: issue flatAngle, region whole, thing "the flower", strength "Bright colours"."#),
    ]
    private static let noneExample = """
        A tidy portrait against a plain wall: issue none, region whole, thing "", strength "Clean background".
        A cup slightly off the third line with a small plant at the edge: issue none, region whole, thing "", strength "Nice framing".
        """

    private func makeSession(for topic: AdviceTopic, styles: Set<CompositionGuide>) -> LanguageModelSession {
        let allowed = VisualIssue.allCases.filter { $0 != .none && CoachRules.allows($0, for: topic, styles: styles) }
        let examples = Self.examples.filter { allowed.contains($0.issue) }.prefix(3).map(\.text) + [Self.noneExample]
        let praised = memory.recentStrengths.isEmpty
            ? ""
            : " Already praised: \(memory.recentStrengths.joined(separator: ", ")); praise something else if you can."
        return LanguageModelSession(instructions: """
            You are a photography teacher looking at a beginner's live camera view. \
            Judge only \(focus(for: topic, styles: styles)).
            A beginner holding a phone can't be perfect, so small imperfections are fine. \
            Only report a problem a viewer would clearly notice in the finished photo, \
            using only these issues: \(allowed.map(\.rawValue).joined(separator: ", ")). \
            If the photo is close to right, pick none.
            Say where in the frame the problem is, and name the thing causing it in 1 to 3 plain words.
            Also name one thing that already works, in 2 to 5 words.\(praised)
            Brightness, sharpness and tilt are measured by the camera and handled separately, so never report them. \
            The measurements given with each photo are always correct.
            Examples:
            \(examples.joined(separator: "\n"))
            So far: \(memory.sentence) Don't pick what was already fixed or pointed out unless it is clearly the biggest problem now.
            """)
    }

    /// What the model should look at for each topic it judges.
    private func focus(for topic: AdviceTopic, styles: Set<CompositionGuide>) -> String {
        switch topic {
        case .composition:
            let selected = CompositionGuide.allCases.filter(styles.contains)
            guard !selected.isEmpty else {
                return "the framing: the background, the edges, whether the subject is cut off, and empty space"
            }
            let criteria = selected
                .map { "- \($0.title): \($0.coachingFocus)" }
                .joined(separator: "\n")
            return """
                how well the photo follows the selected composition styles. If several are picked, \
                judge the biggest problem that applies to any of them:
                \(criteria)
                """
        case .anglePerspective:
            return "the camera angle: whether the height and viewpoint make the scene interesting"
        default:
            return "the framing: the background, the edges, whether the subject is cut off, and empty space"
        }
    }

    /// Asks the model about the frame. Returns nil if it couldn't answer.
    private func judge(
        _ frame: CGImage,
        topic: AdviceTopic,
        styles: Set<CompositionGuide>,
        analysis: SceneAnalysis
    ) async -> CoachJudgement? {
        // A fresh session every time: earlier images would only fill the small context window,
        // and the memory sentence in the instructions carries forward what matters.
        let session = self.session ?? makeSession(for: topic, styles: styles)
        self.session = nil
        do {
            // A stuck request is dropped, and this pass falls back to the measurements.
            return try await withTimeout(Self.modelTimeout) {
                try await session.respond(
                    generating: CoachJudgement.self,
                    // Greedy sampling gives the same answer for the same scene, so the verdict doesn't flip.
                    options: GenerationOptions(samplingMode: .greedy)
                ) {
                    "Topic: \(topic.title). Measured by the camera: \(analysis.summary)."
                    if analysis.scene != .object {
                        analysis.scene.coachingHint
                    }
                    Attachment(frame)
                }.content
            }
        } catch {
            if !Task.isCancelled {
                print("Coach error: \(error)")
            }
            return nil
        }
    }

    /// Keeps the model's "what works" short and free of numbers.
    private static func cleanedStrength(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = trimmed.split(separator: " ").count
        guard (1...6).contains(words), !trimmed.contains(where: \.isNumber) else { return nil }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    // MARK: - Frames

    private static func positionFeedback(for placement: SubjectTarget) -> PhotoFeedback {
        PhotoFeedback(
            good: [],
            improve: placement.cameraAdvice,
            why: "A subject on a third line feels more natural than one dead centre.",
            isGoodEnough: false
        )
    }

    /// The newest live camera frame, cropped to the viewfinder. The Simulator has no camera,
    /// so it uses the test photo instead.
    private func currentFrame(from camera: CameraManager) -> CGImage? {
        if let live = camera.frameGrabber.latestImage(portraitAspect: camera.aspectRatio.portraitAspect) {
            return live
        }
        #if targetEnvironment(simulator)
        return Self.testPhoto()
        #else
        return nil
        #endif
    }

    static func testPhoto() -> CGImage? {
        guard let photo = UIImage(named: "test photo") else { return nil }
        let scale = min(1, 1024 / max(photo.size.width, photo.size.height))
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

/// A model request that took longer than allowed and was cancelled.
struct ModelTimeoutError: Error {}

/// Runs a model request, cancelling it if it takes longer than `limit`, so a stuck request
/// can't hold up the coach. Throws `ModelTimeoutError` when it was cut short.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ operation: sending @escaping () async throws -> T
) async throws -> T {
    let request = Task { try await operation() }
    let timer = Task {
        try await Task.sleep(for: limit)
        request.cancel()
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        do {
            return try await request.value
        } catch {
            // Cancelled by the timer rather than by the caller: report it as a timeout.
            if request.isCancelled, !Task.isCancelled { throw ModelTimeoutError() }
            throw error
        }
    } onCancel: {
        request.cancel()
    }
}

/// Glass capsule showing the coach's latest tip over the viewfinder.
struct CoachTipView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lightbulb.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            // A long tip wraps onto more lines at full size instead of being cut off.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 18))
            .accessibilityLabel("Tip: \(text)")
    }
}

/// Glass card listing what is good and what to improve, or telling the user to take the shot.
struct CoachFeedbackView: View {
    let feedback: PhotoFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feedback.isGoodEnough {
                Label("Looks good, take it!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }

            if !feedback.good.isEmpty {
                section(title: "Good", items: feedback.good, systemImage: "checkmark", tint: .green)
            }

            // One thing to do at a time, so a beginner isn't juggling instructions.
            if !feedback.isGoodEnough, let action = feedback.improve.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Do this now")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .textCase(.uppercase)

                    Label {
                        Text(action)
                            .foregroundStyle(.white)
                    } icon: {
                        Image(systemName: feedback.symbol ?? "arrow.right")
                            .foregroundStyle(.yellow)
                    }
                    .font(.headline)

                    if feedback.improve.count > 1 {
                        Text("Then: \(feedback.improve[1])")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            // The photography idea behind the advice, so the user learns as they shoot.
            if !feedback.isGoodEnough, let why = feedback.why {
                Label(why, systemImage: "graduationcap.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }

            // Once the section is done, point at what to practise next.
            if feedback.isGoodEnough, let nextSection = feedback.nextSection {
                Label(nextSection, systemImage: "arrow.forward.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
            }
        }
        // Long advice wraps onto more lines at full size, and the card grows, instead of ending in "…".
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private func section(title: String, items: [String], systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .textCase(.uppercase)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item)
                        .foregroundStyle(.white)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}
