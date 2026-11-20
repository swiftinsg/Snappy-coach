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

    /// The thing at `point` in an upright frame, and what it looks like, for when the person taps it.
    /// Prefers the outline of the object there, then a person there, then a box around the tap.
    static func object(at point: CGPoint, in image: CGImage) -> (box: CGRect, name: String) {
        let handler = VNImageRequestHandler(cgImage: image)
        let instances = VNGenerateForegroundInstanceMaskRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        instances.runOnCPUInSimulator()
        humans.runOnCPUInSimulator()
        try? handler.perform([instances, humans])

        let person = (humans.results ?? [])
            .filter { $0.confidence >= 0.5 }
            .map { topLeft($0.boundingBox) }
            .first { $0.contains(point) }
        let outline = instances.results?.first.flatMap { box(of: $0.instanceMask, at: point) }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let side = 0.3
        let box = (outline ?? person ?? CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
            .intersection(unit)
        // People are never described, only called a person.
        return (box, person != nil ? "person" : name(of: box, in: image))
    }

    /// The bounds of the mask instance under `point`, or nil when the point is on the background.
    private static func box(of mask: CVPixelBuffer, at point: CGPoint) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        let instance = pixels[y * rowBytes + x]
        guard instance != 0 else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * rowBytes + column] == instance {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    /// Vision's best label for what's in `box`, like "cup", or "object" when it isn't sure.
    private static func name(of box: CGRect, in image: CGImage) -> String {
        let request = VNClassifyImageRequest()
        request.regionOfInterest = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        request.runOnCPUInSimulator()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let label = request.results?.first(where: { $0.confidence >= 0.2 })?.identifier else { return "object" }
        if personLabels.contains(label) { return "person" }
        if vagueLabels.contains(label) { return "object" }
        return label.replacingOccurrences(of: "_", with: " ")
    }

    /// Vision labels that mean people, who are never described.
    private static let personLabels: Set<String> = ["people", "person", "adult", "child", "baby", "teen", "portrait", "selfie", "crowd"]
    /// Vision labels too broad to call something by, like "structure".
    private static let vagueLabels: Set<String> = ["structure", "material", "container", "object", "textile", "wood_processed", "liquid", "indoor", "outdoor", "consumer_electronics", "furniture", "machine", "art", "document"]

    /// Vision measures from the bottom left, the screen from the top left.
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

/// The object the person tapped to photograph.
nonisolated struct SelectedObject: Equatable, Sendable {
    /// In 0...1 coordinates of the whole upright frame, from the top left.
    var box: CGRect
    /// Width divided by height of the frame `box` is measured in.
    var frameAspect: CGFloat
    /// What it looks like in a word or two, like "cup". "person" for people.
    var name: String
}

/// Maps between the whole upright camera frame and the viewfinder, which fills its area and crops the rest.
nonisolated enum FrameMapping {
    /// Where the whole frame sits in a view of `size`. Parts of it run past the view's edges.
    static func shownFrame(frameAspect: CGFloat, in size: CGSize) -> CGRect {
        let viewAspect = size.width / size.height
        let shown = frameAspect > viewAspect
            ? CGSize(width: size.height * frameAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / frameAspect)
        return CGRect(
            x: (size.width - shown.width) / 2,
            y: (size.height - shown.height) / 2,
            width: shown.width,
            height: shown.height
        )
    }

    /// A frame box, in the view's points.
    static func viewRect(for box: CGRect, frameAspect: CGFloat, in size: CGSize) -> CGRect {
        let frame = shownFrame(frameAspect: frameAspect, in: size)
        return CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + box.minY * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
    }

    /// A point in the view, in 0...1 frame coordinates.
    static func framePoint(for point: CGPoint, frameAspect: CGFloat, in size: CGSize) -> CGPoint {
        let frame = shownFrame(frameAspect: frameAspect, in: size)
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    /// A frame box in 0...1 coordinates of only the part the viewfinder shows, which is what the coach judges.
    static func visibleBox(_ box: CGRect, frameAspect: CGFloat, viewAspect: CGFloat) -> CGRect {
        let rect = viewRect(for: box, frameAspect: frameAspect, in: CGSize(width: viewAspect, height: 1))
        return CGRect(x: rect.minX / viewAspect, y: rect.minY, width: rect.width / viewAspect, height: rect.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// The four corners of a rectangle, like a camera's focus frame.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.25
        var path = Path()
        // Top left, top right, bottom right, bottom left: each corner and its two arms.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, xSign, ySign) in corners {
            path.move(to: CGPoint(x: corner.x + arm * xSign, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * ySign))
        }
        return path
    }
}

/// Follows the object the person tapped, for its outline and the advice card.
@Observable
final class ObjectSelection {
    private(set) var object: SelectedObject?
    /// A tap is waiting for the next frame to find what's there.
    private(set) var isFinding = false
    /// The object went out of view and couldn't be followed any more.
    private(set) var isLost = false

    /// `point` is in 0...1 coordinates of the whole upright frame.
    func select(at point: CGPoint, camera: CameraManager) {
        camera.frameGrabber.selectObject(at: point)
        isFinding = true
        isLost = false
    }

    func clear(camera: CameraManager) {
        camera.frameGrabber.clearSelection()
        object = nil
        isFinding = false
        isLost = false
    }

    /// Runs until the task is cancelled, copying what the frame grabber is following.
    func run(camera: CameraManager) async {
        while !Task.isCancelled {
            let latest = camera.frameGrabber.selection()
            if latest.object != object { object = latest.object }
            if latest.isPending != isFinding { isFinding = latest.isPending }
            if latest.isLost != isLost { isLost = latest.isLost }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

/// Outlines the object the person tapped, with its name. Put it on top of the preview, sized like the preview.
struct SelectedObjectOverlay: View {
    let object: SelectedObject

    var body: some View {
        GeometryReader { proxy in
            let rect = FrameMapping.viewRect(for: object.box, frameAspect: object.frameAspect, in: proxy.size)
            // At the top edge the tag would be cut off above the box, so it goes underneath instead.
            let tagBelow = rect.minY < 24
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.yellow, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: tagBelow ? .bottomLeading : .topLeading) {
                    Text(object.name.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow, in: .capsule)
                        .alignmentGuide(.top) { $0[.bottom] + 4 }
                        .alignmentGuide(.bottom) { $0[.top] - 4 }
                }
                .offset(x: rect.minX, y: rect.minY)
                .animation(.snappy, value: object)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        // The goal goes on the last step only, so it isn't repeated.
        if let last = steps.popLast() {
            steps.append(last + " until the dot is in the circle")
        }
        return steps
    }

    private func amount(_ shift: CGFloat) -> String {
        abs(shift) < 0.12 ? " a little" : ""
    }
}

/// Stepping towards or away from the subject, shown as a badge on the viewfinder.
/// Moves across the frame are shown by the dot and circle instead.
enum CameraMove: Equatable {
    case closer, back

    var symbol: String {
        switch self {
        case .closer: "arrow.up.left.and.arrow.down.right"
        case .back: "arrow.down.right.and.arrow.up.left"
        }
    }

    var label: String {
        switch self {
        case .closer: "Step closer"
        case .back: "Step back"
        }
    }
}

/// A pulsing badge at the top of the viewfinder for stepping closer or back, clear of the subject.
/// Put it inside an `UprightOverlay`, so it sits at the top as the phone is held.
struct CameraMoveArrow: View {
    let move: CameraMove

    var body: some View {
        Label(move.label, systemImage: move.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: .capsule)
            .phaseAnimator([false, true]) { badge, isOut in
                badge.scaleEffect(isOut ? 1.08 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
            // Clears the top bar, so the badge never sits under the controls.
            .padding(.top, 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(move)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                // Turning the phone changes the frame's shape, and the old box no longer lines up.
                if (found.aspect > 1) != (frameAspect > 1) {
                    smoothed = nil
                    target = nil
                }
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

/// Shows where the subject should go, like Samsung's shot suggestions: corner brackets frame the
/// target, a ring marks its centre, and a dot marks the subject's centre now. Line the dot up
/// in the ring and everything turns green. Put it on top of the preview, sized exactly like the preview.
struct SubjectTargetOverlay: View {
    let target: SubjectTarget
    let frameAspect: CGFloat

    private let ringSize: CGFloat = 56
    private let dotSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let targetRect = viewRect(for: target.target, in: proxy.size)
            let subjectRect = viewRect(for: target.subject, in: proxy.size)
            let aim = CGPoint(x: targetRect.midX, y: targetRect.midY)
            let dot = CGPoint(x: subjectRect.midX, y: subjectRect.midY)
            let tint: Color = target.isAligned ? .green : .white

            ZStack(alignment: .topLeading) {
                CornerBrackets()
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: targetRect.width, height: targetRect.height)
                    .offset(x: targetRect.minX, y: targetRect.minY)

                // A dashed line from the subject to where it should be, until they meet.
                if !target.isAligned {
                    Path { path in
                        path.move(to: dot)
                        path.addLine(to: aim)
                    }
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                    // Chevrons along the line show which way the dot has to travel.
                    let angle = Angle(radians: atan2(aim.y - dot.y, aim.x - dot.x))
                    ForEach([0.3, 0.5, 0.7], id: \.self) { fraction in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(angle)
                            .position(x: dot.x + (aim.x - dot.x) * fraction, y: dot.y + (aim.y - dot.y) * fraction)
                    }
                    .opacity(hypot(aim.x - dot.x, aim.y - dot.y) > ringSize ? 1 : 0)
                }

                Circle()
                    .fill(tint.opacity(target.isAligned ? 0.3 : 0))
                    .strokeBorder(tint, lineWidth: 3)
                    .frame(width: ringSize, height: ringSize)
                    .position(aim)

                Circle()
                    .fill(target.isAligned ? .green : .yellow)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: dotSize, height: dotSize)
                    .position(dot)
            }
            .shadow(color: .black.opacity(0.4), radius: 2)
            .animation(.snappy, value: target)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The preview fills its area and crops what doesn't fit, so map the frame the same way.
    private func viewRect(for box: CGRect, in size: CGSize) -> CGRect {
        FrameMapping.viewRect(for: box, frameAspect: frameAspect, in: size)
    }
}
