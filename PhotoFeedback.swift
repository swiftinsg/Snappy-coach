//
//  PhotoFeedback.swift
//  Grp 6pm Photo App
//
//  Asks Apple's on-device model for feedback on a photo the person just took.
//

import Foundation
import FoundationModels
import Observation
import UIKit

/// The steps the review screen goes through when the person asks for AI feedback.
enum FeedbackState: Equatable {
    case idle
    case thinking
    case finished(String)
    case failed(String)
}

/// The model's review of a finished photo.
@Generable
struct Critique {
    @Guide(description: "One specific thing that works well in the photo, under 12 words. Call any person the subject")
    var strength: String

    @Guide(description: "The biggest visual problem, or none")
    var issue: VisualIssue

    @Guide(description: "Where in the frame the problem is. Use whole if it is everywhere or the issue is none")
    var region: FrameRegion

    @Guide(description: "The thing causing the problem, 1 to 3 plain words like \"the lamp post\". Call any person the subject. Empty if the issue is none")
    var thing: String

    @Guide(description: "One concrete thing to try on the next shot, under 15 words")
    var nextTime: String
}

/// Generates a short critique of a single photo with the Apple Foundation Models
/// system model. Everything runs on device. The photo is measured first, so the
/// critique is grounded in facts, and the topic the user was practising decides what matters.
@Observable
final class PhotoCritique {
    private(set) var state: FeedbackState = .idle

    /// True while the model is reading the photo.
    var isThinking: Bool { state == .thinking }

    /// Measures `image`, asks the model about it, and publishes the answer in `state`.
    /// `memory` is the live coach's sentence about what was already done, so the review doesn't repeat it.
    func requestFeedback(for image: UIImage, topic: AdviceTopic, memory: String? = nil) async {
        guard state != .thinking else { return }
        state = .thinking

        guard let attachment = Self.smallImage(from: image),
              let analysis = await SceneAnalysis.analyze(attachment) else {
            state = .failed("The photo couldn't be read. Please try again.")
            return
        }
        let measured = CoachRules.issues(for: topic, in: analysis)

        // Without Apple Intelligence the measurements still give useful feedback.
        guard SystemLanguageModel.default.isAvailable else {
            state = .finished(Self.text(strength: CoachRules.strengths(for: topic, in: analysis).first,
                                        issue: measured.first, detail: nil, nextTime: nil, topic: topic, analysis: analysis))
            return
        }

        let session = LanguageModelSession(
            instructions: """
            You are a friendly photography teacher reviewing a photo a beginner just took. \
            They were practising \(topic.title.lowercased()). \
            Be specific to what is actually visible. Never name or describe people; say "the subject". \
            The camera's measurements are always correct, so don't contradict them.
            \(memory.map { "While shooting: \($0) Build on that rather than repeating it." } ?? "")
            """
        )

        do {
            // Give up on a request that hangs, so the person isn't left waiting forever.
            let critique = try await withTimeout(.seconds(20)) {
                try await session.respond(
                    generating: Critique.self,
                    options: GenerationOptions(samplingMode: .greedy)
                ) {
                    "Measured by the camera: \(analysis.summary)."
                    "Review this photo."
                    Attachment(attachment)
                }.content
            }
            guard !Task.isCancelled else { return }
            // A measured problem beats the model's guess.
            let issue = measured.first ?? critique.issue.coachIssue
            // Where the model saw the problem only applies to its own issue.
            let detail = measured.isEmpty ? IssueDetail(region: critique.region, rawThing: critique.thing) : nil
            state = .finished(Self.text(strength: critique.strength, issue: issue, detail: detail,
                                        nextTime: critique.nextTime, topic: topic, analysis: analysis))
        } catch {
            guard !Task.isCancelled else { return }
            print("Photo feedback error: \(error)")
            state = .failed(error is ModelTimeoutError
                ? "Feedback took too long, so it was cancelled. Please try again."
                : "Feedback couldn't be generated right now. Please try again.")
        }
    }

    /// Returns to the offer so the person can ask again.
    func reset() {
        state = .idle
    }

    /// One thing that works, one fix with the reason behind it, and one idea for next time.
    private static func text(
        strength: String?,
        issue: CoachIssue?,
        detail: IssueDetail?,
        nextTime: String?,
        topic: AdviceTopic,
        analysis: SceneAnalysis
    ) -> String {
        var parts: [String] = []
        if let strength, !strength.isEmpty {
            parts.append("What works: \(strength.trimmingCharacters(in: .punctuationCharacters)).")
        }
        if let issue {
            let advice = issue.advice(for: topic, analysis: analysis, detail: detail)
            parts.append("To improve: \(advice.action). \(advice.why)")
        } else {
            parts.append("Nothing to fix for \(topic.title.lowercased()). Nice shot!")
        }
        if let nextTime, !nextTime.isEmpty {
            parts.append("Next time: \(nextTime.trimmingCharacters(in: .punctuationCharacters)).")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Shrinks the photo so the model can read it quickly, keeping the whole frame.
    private static func smallImage(from image: UIImage) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let longestSide: CGFloat = 1024
        let scale = min(1, longestSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
