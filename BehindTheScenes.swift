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

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
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

/// The auto-rendering coach: every few seconds it looks at the camera and updates `tip`.
@Observable
final class PhotoCoach {
    /// The latest tip shown on screen, or nil while the coach has nothing to say yet.
    private(set) var tip: String?

    private static let interval: Duration = .seconds(4)

    func checkModel() -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "Model available"
        case .unavailable(let reason):
            return "Not available: \(reason)"
        }
    }

    /// Runs until the task is cancelled. Restart it (with a new topic) when the dropdown changes.
    func run(camera: CameraManager, topic: AdviceTopic) async {
        tip = nil
        if case .unavailable = SystemLanguageModel.default.availability {
            tip = "The coach needs Apple Intelligence"
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled, let frame = currentFrame(from: camera) else { continue }
            if let answer = await ask(about: topic, image: frame), !Task.isCancelled {
                tip = answer
            }
        }
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

    private static func testPhoto() -> CGImage? {
        guard let photo = UIImage(named: "test photo") else { return nil }
        let scale = min(1, 1024 / max(photo.size.width, photo.size.height))
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// What the coach should look at for each topic in the dropdown.
    private func focus(for topic: AdviceTopic) -> String {
        switch topic {
        case .composition:
            "how the scene is framed. Tools: move the camera, or tap one style button in the Composition row (Thirds, Leading Lines, Symmetry, Negative Space, Centre) to show its guide lines. Never drag it"
        case .subjectPosition:
            "where the main subject sits in the frame. Tools: move the camera or the subject left, right, up or down, step closer or back, or tap a zoom button"
        case .anglePerspective:
            "the camera angle and height. Tools: raise or lower the camera, tilt it up or down, step to the side, or tap a zoom button"
        case .focus:
            "how sharp the subject is. Tools: the Focus slider (drag left to focus nearer, right to focus farther), or move closer to or farther from the subject"
        case .light:
            "the lighting. Tools: the Flash button (tap to switch Auto, On, Off), the Night Mode button, the White Balance slider (drag left for cooler, right for warmer), or move toward or away from the light"
        case .exposure:
            "how bright the photo is. Tools: the Exposure slider (drag right to brighten, left to darken), or the Shutter slider (drag left for faster and darker, right for slower and brighter)"
        }
    }

    /// Asks the model for one short action. Returns nil if it couldn't answer.
    func ask(about topic: AdviceTopic, image: CGImage) async -> String? {
        let session = LanguageModelSession(
            instructions: """
            You are a photography coach looking at what the user's camera sees right now. \
            Reply with one instruction of 4 to 10 words that tells the user exactly what to do and \
            which way to do it. When one of the listed tools applies, use its exact name and say \
            which way to drag or tap. Otherwise say which way to move the camera and roughly how far. \
            Base it on what you actually see. \
            Never name or describe what is in the photo: if you must refer to it, say "the subject". \
            Do not write a full sentence. Do not explain why. \
            Only consider \(focus(for: topic)).
            """
        )
        do {
            let response = try await session.respond {
                "What is the one action to improve the \(topic.title.lowercased()) of this photo?"
                Attachment(image)
            }
            return response.content
        } catch {
            if !Task.isCancelled {
                print("Coach error: \(error)")
            }
            return nil
        }
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
