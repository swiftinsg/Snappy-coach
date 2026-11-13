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

/// What the coach says about the current frame.
@Generable
struct PhotoFeedback: Equatable {
    @Guide(description: "Things that are already good for the chosen topic, each 2 to 5 words", .maximumCount(2))
    var good: [String]

    @Guide(description: "Exact actions that would improve the photo, each 4 to 10 words. Empty when the photo is good enough", .maximumCount(3))
    var improve: [String]

    @Guide(description: "True only when the photo is already good enough for the chosen topic that the user should take it now")
    var isGoodEnough: Bool
}

/// The auto-rendering coach: every few seconds it looks at the camera and updates `feedback`.
@Observable
final class PhotoCoach {
    /// The latest feedback shown on screen, or nil while the coach has nothing to say yet.
    private(set) var feedback: PhotoFeedback?
    /// A message for when the coach can't run at all, such as no Apple Intelligence.
    private(set) var notice: String?

    var isReady: Bool { feedback?.isGoodEnough ?? false }

    /// Seconds to wait between questions to the model.
    private static let interval: TimeInterval = 4

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
    func run(camera: CameraManager, topic: AdviceTopic, style: CompositionGuide, guide: SubjectGuide) async {
        feedback = nil
        notice = nil

        // Where the subject sits is geometry, so the green box decides and the coach reads it out.
        let usesBox = topic == .subjectPosition || (topic == .composition && style.subjectPlacement != nil)
        var modelIsAvailable = true
        if case .unavailable = SystemLanguageModel.default.availability {
            modelIsAvailable = false
            if !usesBox {
                notice = "The coach needs Apple Intelligence"
                return
            }
        }

        // Checks twice a second, so the coach reacts as soon as the green box has a subject.
        var lastAsk = Date()
        while !Task.isCancelled {
            if usesBox, let target = guide.target {
                feedback = Self.positionFeedback(for: target)
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            // Subject Position has no box to read yet, and the model can't judge it alone.
            if topic == .subjectPosition || !modelIsAvailable {
                feedback = nil
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            guard Date().timeIntervalSince(lastAsk) >= Self.interval,
                  let frame = currentFrame(from: camera) else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            lastAsk = Date()
            if let answer = await ask(about: topic, style: style, image: frame), !Task.isCancelled {
                feedback = answer
            }
        }
    }

    private static func positionFeedback(for placement: SubjectTarget) -> PhotoFeedback {
        if placement.isAligned {
            return PhotoFeedback(good: ["Subject in the green box"], improve: [], isGoodEnough: true)
        }
        return PhotoFeedback(good: [], improve: placement.cameraAdvice, isGoodEnough: false)
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

    /// What the coach should look at for each topic in the dropdown.
    private func focus(for topic: AdviceTopic, style: CompositionGuide) -> String {
        switch topic {
        case .composition:
            style.coachingFocus
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

    /// Removes repeats, and never says "take it" when the exposure is clearly wrong.
    private func cleaned(_ feedback: PhotoFeedback, stats: FrameStats?, topic: AdviceTopic, style: CompositionGuide) -> PhotoFeedback {
        var result = feedback
        // The model can't verify abstract styles like Leading Lines from one photo, so it only
        // gives hints for them and never tells the user the shot is ready.
        if topic == .composition {
            result.isGoodEnough = false
        }
        // The model sometimes quotes numbers or slider percentages, which mean nothing on screen.
        result.good = unique(result.good.filter { !$0.contains(where: \.isNumber) })
        result.improve = unique(result.improve.map {
            $0.replacingOccurrences(of: #"\s*\d+\s*%"#, with: "", options: .regularExpression)
        })
        if stats?.isBadlyExposed == true {
            result.isGoodEnough = false
        }
        // Brightness is measured, so for the Exposure topic the measurement decides.
        if topic == .exposure, let stats {
            if stats.brightness < 0.3 {
                result.isGoodEnough = false
                result.good = []
                result.improve = ["Drag the Exposure slider right"]
            } else if stats.brightness > 0.75 {
                result.isGoodEnough = false
                result.good = []
                result.improve = ["Drag the Exposure slider left"]
            } else {
                result.isGoodEnough = true
                result.good = ["Balanced brightness"]
            }
        }
        // A clearly dark or bright frame has an obvious lighting fix.
        if topic == .light, let stats {
            if stats.brightness < 0.3 {
                result.isGoodEnough = false
                result.good = []
                result.improve = ["Tap Night Mode", "Move toward the light"]
            } else if stats.brightness > 0.75 {
                result.isGoodEnough = false
                result.good = []
                result.improve = ["Move away from the light"]
            }
        }
        // Sharpness is measured too, so for the Focus topic the measurement decides.
        if topic == .focus, let stats {
            let isSharp = stats.sharpness >= 60
            result.isGoodEnough = isSharp
            result.good = isSharp ? ["Sharp focus"] : []
            if !isSharp {
                result.improve = ["Drag the Focus slider until sharp", "Hold the phone steady"]
            }
        }
        if result.isGoodEnough {
            result.improve = []
        }
        return result
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Asks the model what is good and what to improve. Returns nil if it couldn't answer.
    func ask(about topic: AdviceTopic, style: CompositionGuide, image: CGImage) async -> PhotoFeedback? {
        let session = LanguageModelSession(
            instructions: """
            You are a photography coach looking at what the user's camera sees right now. \
            Judge only \(focus(for: topic, style: style)). \
            List up to 2 things that are already good. \
            List up to 3 improvements. Each improvement tells the user exactly what to do and \
            which way to do it: when one of the listed tools applies, use its exact name and say \
            which way to drag or tap, otherwise say which way to move the camera and roughly how far. \
            Set isGoodEnough to true only when every requirement of the topic or style is clearly \
            visible and the user should take it now, and then list no improvements. \
            If the scene does not suit the chosen style at all, set isGoodEnough to false and tell \
            the user what kind of scene to point the camera at. \
            Each improvement is one single movement: pan left or right, tilt up or down, step closer \
            or back, or tap a zoom button. Never combine movements in one item, and never say drag \
            for moving the camera. \
            Base everything on what you actually see. \
            Only list something as good if it is clearly true. An empty list is fine. \
            Never repeat an item. Never quote the measured values or any numbers about the picture. \
            Only sliders are dragged, and buttons are tapped. Never give numbers for how far to move a slider. \
            Never name or describe what is in the photo: if you must refer to it, say "the subject". \
            Do not write full sentences. Do not explain why.
            """
        )
        let stats = FrameStats.measure(image)
        do {
            let response = try await session.respond(generating: PhotoFeedback.self) {
                "Review this photo for \(topic.title.lowercased())."
                if let stats {
                    "Measured by the camera, and always correct, so trust it over your own impression: \(stats.summary)."
                }
                Attachment(image)
            }
            return cleaned(response.content, stats: stats, topic: topic, style: style)
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
