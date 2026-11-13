//
//  SubjectGuide.swift
//  Grp 6pm Photo App
//
//  The green box that shows where the subject should be in the frame.
//

import Foundation
import AVFoundation
import Vision
import CoreML
import SwiftUI

/// Finds the subject in a frame: the people if there are any, otherwise the most eye-catching thing.
nonisolated enum SubjectFinder {
    /// Everyone in the frame, and the subject box. All in 0...1 coordinates from the top left.
    struct Found {
        /// The whole group when there are people, so several people are one subject.
        var subject: CGRect?
        var people: [CGRect]
    }

    /// The main subject's box, in 0...1 coordinates with the origin at the top left.
    static func subject(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGRect? {
        find(with: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)).subject
    }

    static func subject(in image: CGImage) -> CGRect? {
        find(in: image).subject
    }

    static func find(in image: CGImage) -> Found {
        find(with: VNImageRequestHandler(cgImage: image))
    }

    private static func find(with handler: VNImageRequestHandler) -> Found {
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        // Whole bodies, so people facing away (with no visible face) still count.
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        saliency.runOnCPUInSimulator()
        humans.runOnCPUInSimulator()
        guard (try? handler.perform([saliency, humans])) != nil else { return Found(subject: nil, people: []) }

        let people = (humans.results ?? [])
            .filter { $0.confidence >= 0.5 }
            .map { topLeft($0.boundingBox) }
        // A group of people is one subject, so the box wraps them all.
        let group = people.reduce(nil as CGRect?) { box, person in box?.union(person) ?? person }
        let salient = saliency.results?.first?.salientObjects?.first.map { topLeft($0.boundingBox) }
        return Found(subject: group ?? salient, people: people)
    }

    /// Vision measures from the bottom left, the screen from the top left.
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

extension VNRequest {
    /// The Simulator can't run Vision on the Neural Engine, so requests use the CPU there.
    /// Does nothing on a device.
    nonisolated func runOnCPUInSimulator() {
        #if targetEnvironment(simulator)
        let cpu = MLComputeDevice.allComputeDevices.first {
            if case .cpu = $0 { true } else { false }
        }
        if let cpu {
            setComputeDevice(cpu, for: .main)
        }
        #endif
    }
}

/// Where a composition style wants the subject.
enum SubjectPlacement: Equatable {
    /// The nearest of the four points where the thirds lines cross.
    case thirdsPoint
    /// A vertical thirds line (x is 1/3 or 2/3), at whatever height the subject is.
    case thirdsLine(CGFloat)
    case centre
    /// The vertical middle line, at whatever height the subject is.
    case centreLine
}

/// Where the subject is now, and where the green box says it should be.
/// Both rectangles use 0...1 coordinates from the top left of the frame.
struct SubjectTarget: Equatable {
    let subject: CGRect
    let target: CGRect
    /// Close enough by hand. Decided when the target is made, so it can depend on the last result.
    let isAligned: Bool
    /// The point the subject is being guided to. Kept between updates so the box doesn't jump.
    let aimPoint: CGPoint

    /// How close the centres must be, as a fraction of the frame, to count as lined up.
    /// Hand-held framing is never exact, so close enough counts.
    static let tolerance: CGFloat = 0.10
    /// Once lined up, the subject stays lined up until it drifts this far, so the box doesn't flicker.
    static let holdTolerance: CGFloat = 0.15
    /// Smallest shift along one axis that is worth telling the person about.
    private static let axisThreshold: CGFloat = 0.06

    /// How close the subject is to the target box, 0...1. Reaches 1 once aligned.
    var progress: Double {
        guard !isAligned else { return 1 }
        return max(0.1, 1 - Double(hypot(dx, dy) - Self.tolerance) / 0.4)
    }

    /// How far the subject has to move inside the frame. Positive is right or down.
    private var dx: CGFloat { target.midX - subject.midX }
    private var dy: CGFloat { target.midY - subject.midY }

    /// Puts the target where the chosen composition style wants the subject.
    /// `wasAligned` is the last result, so a lined-up subject gets the looser `holdTolerance`.
    /// `previous` is the last target, so the coach doesn't flip between left and right:
    /// the same crossing is kept, and moving just past the box counts as lined up.
    static func make(
        subject: CGRect,
        placement: SubjectPlacement,
        wasAligned: Bool = false,
        previous: SubjectTarget? = nil
    ) -> SubjectTarget? {
        // A subject that fills the frame can't be placed anywhere else.
        guard subject.width < 0.75, subject.height < 0.75 else { return nil }

        let point: CGPoint
        switch placement {
        case .centre:
            point = CGPoint(x: 0.5, y: 0.5)
        case .centreLine:
            point = CGPoint(x: 0.5, y: subject.midY)
        case .thirdsLine(let x):
            point = CGPoint(x: x, y: subject.midY)
        case .thirdsPoint:
            let crossings = [
                CGPoint(x: 1.0 / 3, y: 1.0 / 3), CGPoint(x: 2.0 / 3, y: 1.0 / 3),
                CGPoint(x: 1.0 / 3, y: 2.0 / 3), CGPoint(x: 2.0 / 3, y: 2.0 / 3),
            ]
            // Keep aiming at the crossing already chosen. Otherwise the nearest one switches
            // sides as the subject passes the middle, and "move left" turns into "move right".
            if let kept = previous?.aimPoint, crossings.contains(kept) {
                point = kept
            } else if let nearest = crossings.min(by: { distance(from: subject, to: $0) < distance(from: subject, to: $1) }) {
                point = nearest
            } else {
                return nil
            }
        }

        let x = min(max(point.x - subject.width / 2, 0), 1 - subject.width)
        let y = min(max(point.y - subject.height / 2, 0), 1 - subject.height)
        let target = CGRect(x: x, y: y, width: subject.width, height: subject.height)
        let dx = target.midX - subject.midX
        let dy = target.midY - subject.midY
        // Moving just past the box isn't a reason to send the person back the other way.
        let overshot = previous.map { last in
            (last.dx * dx < 0 && abs(last.dx) > 0.01) || (last.dy * dy < 0 && abs(last.dy) > 0.01)
        } ?? false
        return SubjectTarget(
            subject: subject,
            target: target,
            isAligned: hypot(dx, dy) < (wasAligned || overshot ? holdTolerance : tolerance),
            aimPoint: point
        )
    }

    private static func distance(from subject: CGRect, to point: CGPoint) -> CGFloat {
        hypot(point.x - subject.midX, point.y - subject.midY)
    }

    /// Camera moves that bring the subject into the box. Moving the camera one way
    /// moves the subject the other way in the frame.
    var cameraAdvice: [String] {
        var steps: [String] = []
        if abs(dx) >= Self.axisThreshold {
            steps.append("Move the camera\(amount(dx)) \(dx > 0 ? "left" : "right")")
        }
        if abs(dy) >= Self.axisThreshold {
            steps.append("Move the camera\(amount(dy)) \(dy > 0 ? "up" : "down")")
        }
        return steps
    }

    private func amount(_ shift: CGFloat) -> String {
        abs(shift) < 0.12 ? " a little" : ""
    }
}

/// Keeps the green box up to date while the Subject Position or Composition topic is chosen.
@Observable
final class SubjectGuide {
    private(set) var target: SubjectTarget?
    /// Width divided by height of the frame that `target` is measured in.
    private(set) var frameAspect: CGFloat = 3.0 / 4.0

    private var smoothed: CGRect?

    /// Runs until the task is cancelled. Restart it when the topic or the guide style changes.
    /// Pass nil when the current topic or style has no box.
    func run(camera: CameraManager, placement: SubjectPlacement?) async {
        target = nil
        smoothed = nil
        camera.frameGrabber.setTracksSubject(placement != nil)
        guard let placement else { return }

        while !Task.isCancelled {
            if let found = latestSubject(from: camera) {
                frameAspect = found.aspect
                target = SubjectTarget.make(
                    subject: smooth(found.box),
                    placement: placement,
                    wasAligned: target?.isAligned ?? false,
                    previous: target
                )
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func latestSubject(from camera: CameraManager) -> (box: CGRect, aspect: CGFloat)? {
        if let live = camera.frameGrabber.latestSubject() {
            return live
        }
        #if targetEnvironment(simulator)
        return Self.simulatorSubject
        #else
        return nil
        #endif
    }

    /// The Simulator has no camera, so it finds the subject in the test photo instead.
    private static let simulatorSubject: (box: CGRect, aspect: CGFloat)? = {
        guard let photo = PhotoCoach.testPhoto(), let box = SubjectFinder.subject(in: photo) else { return nil }
        return (box, CGFloat(photo.width) / CGFloat(photo.height))
    }()

    /// Blends each new box with the last one so the green box doesn't jitter.
    private func smooth(_ box: CGRect) -> CGRect {
        guard let previous = smoothed else {
            smoothed = box
            return box
        }
        let blended = CGRect(
            x: previous.minX * 0.6 + box.minX * 0.4,
            y: previous.minY * 0.6 + box.minY * 0.4,
            width: previous.width * 0.6 + box.width * 0.4,
            height: previous.height * 0.6 + box.height * 0.4
        )
        smoothed = blended
        return blended
    }
}

/// Draws the green target box, and a faint outline of where the subject is now.
/// Put it on top of the preview, sized exactly like the preview.
struct SubjectTargetOverlay: View {
    let target: SubjectTarget
    let frameAspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let targetRect = viewRect(for: target.target, in: proxy.size)
            let subjectRect = viewRect(for: target.subject, in: proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .frame(width: subjectRect.width, height: subjectRect.height)
                    .offset(x: subjectRect.minX, y: subjectRect.minY)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.green.opacity(target.isAligned ? 0.3 : 0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.green, lineWidth: target.isAligned ? 4 : 3)
                    }
                    .frame(width: targetRect.width, height: targetRect.height)
                    .offset(x: targetRect.minX, y: targetRect.minY)
            }
            .animation(.snappy, value: target)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The preview fills its area and crops what doesn't fit, so map the frame the same way.
    private func viewRect(for box: CGRect, in size: CGSize) -> CGRect {
        let viewAspect = size.width / size.height
        let shown: CGSize
        if frameAspect > viewAspect {
            shown = CGSize(width: size.height * frameAspect, height: size.height)
        } else {
            shown = CGSize(width: size.width, height: size.width / frameAspect)
        }
        let originX = (size.width - shown.width) / 2
        let originY = (size.height - shown.height) / 2
        return CGRect(
            x: originX + box.minX * shown.width,
            y: originY + box.minY * shown.height,
            width: box.width * shown.width,
            height: box.height * shown.height
        )
    }
}
