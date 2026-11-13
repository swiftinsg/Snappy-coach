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

/// Generates a short critique of a single photo with the Apple Foundation Models
/// system model. Everything runs on device.
@Observable
final class PhotoCritique {
    private(set) var state: FeedbackState = .idle

    /// True while the model is reading the photo.
    var isThinking: Bool { state == .thinking }

    /// Sends `image` to the model and publishes the answer in `state`.
    func requestFeedback(for image: UIImage) async {
        guard state != .thinking else { return }
        state = .thinking

        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            state = .failed("Photo feedback needs Apple Intelligence. \(reason)")
            return
        }
        guard let attachment = Self.smallImage(from: image) else {
            state = .failed("The photo couldn't be read. Please try again.")
            return
        }

        let session = LanguageModelSession(
            instructions: """
            You are a friendly photography teacher reviewing a photo the user just took. \
            Write 2 to 4 short sentences of specific, practical feedback. \
            Start with one thing that works well, then give one or two concrete suggestions \
            for improving the photo next time, such as framing, angle, light or focus. \
            Only mention what is actually visible and relevant. \
            Never name or describe the people in the photo; if you must refer to one, say "the subject". \
            Use plain prose without headings, bullet points or markdown. \
            Keep the whole answer under 90 words.
            """
        )

        do {
            let response = try await session.respond {
                "What feedback do you have on this photo?"
                Attachment(attachment)
            }
            guard !Task.isCancelled else { return }
            state = .finished(response.content)
        } catch {
            guard !Task.isCancelled else { return }
            print("Photo feedback error: \(error)")
            state = .failed("Feedback couldn't be generated right now. Please try again.")
        }
    }

    /// Returns to the offer so the person can ask again.
    func reset() {
        state = .idle
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
