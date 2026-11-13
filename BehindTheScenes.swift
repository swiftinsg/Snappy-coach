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

    private static let longestSide: CGFloat = 1024
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

    /// The newest frame, turned upright and shrunk so the model can read it quickly.
    func latestImage() -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }

        // The back camera delivers frames rotated by 90°, so turn them upright.
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
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
    /// True when the shot is ready to take.
    var isGoodEnough: Bool
}

/// The auto-rendering coach. It measures the frame, asks the model only about what can't be
/// measured, and turns the result into advice from `AdviceLibrary`.
///
/// Advice is grouped into sections: a section is the time spent on one issue. When the issue is
/// fixed (or the topic changes, or a photo is taken) the section ends, the model's context is
/// thrown away, and the next session starts with one sentence about what has been done so far,
/// so the coach doesn't repeat itself.
@Observable
final class PhotoCoach {
    /// The latest feedback shown on screen, or nil while the coach has nothing to say yet.
    private(set) var feedback: PhotoFeedback?
    /// A message for when the coach can't run at all.
    private(set) var notice: String?
    /// Raw measurements and model output, for the hidden debug overlay.
    private(set) var debugText = ""

    var isReady: Bool { feedback?.isGoodEnough ?? false }

    /// How often the model looks at the frame.
    private static let modelInterval: Duration = .seconds(2)
    /// How often measured-only topics refresh. Measuring is cheap, so it can be quicker.
    private static let measureInterval: Duration = .seconds(1)
    /// Each turn carries an image, which fills the on-device model's small context window fast,
    /// so a session is renewed after a few turns even within one section.
    private static let maxTurnsPerSession = 3
    /// How many accomplishments the one-line memory keeps.
    private static let memoryLength = 4

    private let attitude = PhoneAttitude()

    // Section memory.
    private var session: LanguageModelSession?
    private var sessionTurns = 0
    private var accomplished: [String] = []
    /// The issue being worked on in the current section, nil when the shot is good.
    private var shownIssue: CoachIssue?

    // Hysteresis: a new verdict must repeat before it replaces what's on screen.
    private var candidate: CoachIssue??
    private var candidateCount = 0

    /// Runs until the task is cancelled. Restart it (with a new topic) when the dropdown changes.
    func run(camera: CameraManager, topic: AdviceTopic, style: CompositionGuide, guide: SubjectGuide) async {
        feedback = nil
        notice = nil
        candidate = nil
        candidateCount = 0
        // A new topic is a new section.
        endSection()
        attitude.start()
        defer { attitude.stop() }

        if CoachRules.usesModel(topic), SystemLanguageModel.default.isAvailable {
            session = makeSession(for: topic)
            session?.prewarm()
        }

        // Checks twice a second, so the coach reacts as soon as the green box has a subject.
        while !Task.isCancelled {
            // Where the subject sits is geometry, so the green box decides while it's off target.
            let usesBox = topic == .subjectPosition || (topic == .composition && style.subjectPlacement != nil)
            if usesBox, let target = guide.target, !target.isAligned {
                feedback = Self.positionFeedback(for: target)
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            let usesModel = CoachRules.usesModel(topic) && SystemLanguageModel.default.isAvailable
            try? await Task.sleep(for: usesModel ? Self.modelInterval : Self.measureInterval)
            guard !Task.isCancelled, let frame = currentFrame(from: camera) else { continue }

            let readings = CameraReadings.read(from: camera)
            guard let analysis = await SceneAnalysis.analyze(
                frame, readings: readings, pitch: attitude.pitch, tilt: attitude.tilt
            ), !Task.isCancelled else { continue }

            var issues = CoachRules.issues(for: topic, in: analysis)
            var good = CoachRules.strengths(for: topic, in: analysis)
            if usesBox, guide.target?.isAligned == true {
                good.insert("Subject in the green box", at: 0)
            }

            // The model is only asked when the measurements found nothing, which saves battery
            // and keeps it to what it's good at: judging the look of the scene.
            var modelNote = "model: not asked"
            if usesModel, issues.isEmpty, let judgement = await judge(frame, topic: topic, analysis: analysis) {
                guard !Task.isCancelled else { break }
                modelNote = "model: \(judgement.issue.rawValue) / \(judgement.strength)"
                if CoachRules.allows(judgement.issue, for: topic), let issue = judgement.issue.coachIssue {
                    issues.append(issue)
                }
                if let strength = Self.cleanedStrength(judgement.strength), !good.contains(strength) {
                    good.append(strength)
                }
            }

            debugText = analysis.debugDescription + "\n" + modelNote + "\ndone: " + memorySentence
            publish(top: issues.first, next: issues.dropFirst().first, good: good, topic: topic, analysis: analysis)
        }
    }

    /// Call when a photo is taken: that finishes the current section.
    func noteShutter() {
        endSection()
    }

    // MARK: - Sections and memory

    /// One short sentence about what the user has already fixed.
    private var memorySentence: String {
        guard !accomplished.isEmpty else { return "nothing yet" }
        return "the user has already " + accomplished.formatted(.list(type: .and))
    }

    /// Ends the current section: remembers what was fixed and throws the model's context away.
    private func endSection(fixed issue: CoachIssue? = nil) {
        if let issue {
            accomplished.removeAll { $0 == issue.accomplishment }
            accomplished.append(issue.accomplishment)
            accomplished = Array(accomplished.suffix(Self.memoryLength))
        }
        session = nil
        sessionTurns = 0
        shownIssue = nil
    }

    /// Shows a verdict once it has been seen twice in a row, so the card doesn't flicker.
    private func publish(top: CoachIssue?, next: CoachIssue?, good: [String], topic: AdviceTopic, analysis: SceneAnalysis) {
        if candidate == .some(top) {
            candidateCount += 1
        } else {
            candidate = .some(top)
            candidateCount = 1
        }
        let isFirstVerdict = feedback == nil
        guard candidateCount >= 2 || isFirstVerdict else { return }

        // The issue being worked on has gone: that section is done.
        if let shownIssue, shownIssue != top {
            endSection(fixed: shownIssue)
        }
        shownIssue = top

        guard let top else {
            feedback = PhotoFeedback(good: Array(good.prefix(2)), improve: [], why: nil, isGoodEnough: true)
            return
        }
        let advice = top.advice(for: topic, analysis: analysis)
        var improve = [advice.action]
        if let next {
            improve.append(next.advice(for: topic, analysis: analysis).action)
        }
        feedback = PhotoFeedback(good: Array(good.prefix(2)), improve: improve, why: advice.why, isGoodEnough: false)
    }

    // MARK: - The model

    private func makeSession(for topic: AdviceTopic) -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You are a photography teacher looking at a beginner's live camera view. \
            Judge only \(focus(for: topic)). \
            Pick the single biggest problem from the list, or none if this part of the photo already works. \
            Also name one thing that already works, in 2 to 5 words. \
            The camera's measurements are given with each photo and are always correct.
            Examples:
            A person in front of a busy street: issue clutteredBackground, strength "Clear subject".
            A tree cut off at the top edge: issue subjectCutOff, strength "Nice soft light".
            A small boat in a huge empty sea: issue tooMuchEmptySpace, strength "Calm colours".
            A tidy portrait against a plain wall: issue none, strength "Clean background".
            Progress so far: \(memorySentence). Don't bring those up again unless they are clearly wrong now.
            """)
    }

    /// What the model should look at for each topic it judges.
    private func focus(for topic: AdviceTopic) -> String {
        switch topic {
        case .anglePerspective:
            "the camera angle: whether the height and viewpoint make the scene interesting"
        default:
            "the framing: the background, the edges, whether the subject is cut off, and empty space"
        }
    }

    /// Asks the model about the frame. Returns nil if it couldn't answer.
    private func judge(_ frame: CGImage, topic: AdviceTopic, analysis: SceneAnalysis) async -> CoachJudgement? {
        if session == nil || sessionTurns >= Self.maxTurnsPerSession {
            session = makeSession(for: topic)
            sessionTurns = 0
        }
        guard let session else { return nil }
        do {
            let response = try await session.respond(
                generating: CoachJudgement.self,
                // Greedy sampling gives the same answer for the same scene, so the verdict doesn't flip.
                options: GenerationOptions(samplingMode: .greedy)
            ) {
                "Topic: \(topic.title). Measured by the camera: \(analysis.summary)."
                Attachment(frame)
            }
            sessionTurns += 1
            return response.content
        } catch {
            // Most often the context window is full; start a fresh session next time.
            self.session = nil
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

    /// The newest live camera frame. The Simulator has no camera, so it uses the test photo instead.
    private func currentFrame(from camera: CameraManager) -> CGImage? {
        if let live = camera.frameGrabber.latestImage() {
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

/// Glass capsule showing the coach's latest tip over the viewfinder.
struct CoachTipView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lightbulb.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            // Two lines at most, so a long tip doesn't cover more of the viewfinder.
            .lineLimit(2)
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

            if !feedback.isGoodEnough, !feedback.improve.isEmpty {
                section(title: "Improve", items: feedback.improve, systemImage: "arrow.right", tint: .yellow)
            }

            // The photography idea behind the advice, so the user learns as they shoot.
            if !feedback.isGoodEnough, let why = feedback.why {
                Label(why, systemImage: "graduationcap.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
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
