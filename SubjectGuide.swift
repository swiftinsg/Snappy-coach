//
//  SubjectGuide.swift
//  Grp 6pm Photo App
//
//  The target guide that shows which way to move the phone to place the subject.
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
        /// Other things that stand out, apart from the people, so tips know something else is in the shot.
        var others: [CGRect] = []
    }

    /// Smaller than this share of the frame, a thing that stands out is too small to be meant for the shot.
    static let otherThingShare = 0.02

    /// Boxes that aren't mostly inside one of the people, and are big enough to be meant for the shot.
    static func otherThings(_ boxes: [CGRect], apartFrom people: [CGRect]) -> [CGRect] {
        boxes.filter { box in
            let area = box.width * box.height
            guard area >= otherThingShare else { return false }
            return !people.contains { person in
                let overlap = box.intersection(person)
                return !overlap.isNull && overlap.width * overlap.height >= area * 0.5
            }
        }
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
        // Every object that stands out, so a statue or a cake beside a person is known to be in the shot.
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        saliency.runOnCPUInSimulator()
        humans.runOnCPUInSimulator()
        objectness.runOnCPUInSimulator()
        guard (try? handler.perform([saliency, humans, objectness])) != nil else { return Found(subject: nil, people: []) }

        let people = (humans.results ?? [])
            .filter { $0.confidence >= 0.5 }
            .map { topLeft($0.boundingBox) }
        // A group of people is one subject, so the box wraps them all.
        let group = people.reduce(nil as CGRect?) { box, person in box?.union(person) ?? person }
        let salient = saliency.results?.first?.salientObjects?.first.map { topLeft($0.boundingBox) }
        let objects = (objectness.results?.first?.salientObjects ?? []).map { topLeft($0.boundingBox) }
        return Found(subject: group ?? salient, people: people, others: otherThings(objects, apartFrom: people))
    }

    /// Every object that stands out in the frame, from the top left, for pointing at what the coach names.
    static func salientObjects(in image: CGImage) -> [CGRect] {
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        objectness.runOnCPUInSimulator()
        guard (try? VNImageRequestHandler(cgImage: image).perform([objectness])) != nil else { return [] }
        return (objectness.results?.first?.salientObjects ?? []).map { topLeft($0.boundingBox) }
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

    /// What Vision sees in `box` (0...1 from the top left), with how sure it is, most likely first.
    /// Used to check that a thing the model named is really there.
    static func labels(of box: CGRect, in image: CGImage) -> [(label: String, confidence: Float)] {
        let request = VNClassifyImageRequest()
        request.regionOfInterest = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        request.runOnCPUInSimulator()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.1 }
            .prefix(10)
            .map { ($0.identifier, $0.confidence) }
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

    /// A point in the upright frame, 0...1 from the top left, in the camera sensor's own
    /// coordinates, which is what focus and exposure points use. `orientation` is how the
    /// sensor's frames are turned upright (`HoldOrientation.frameOrientation`).
    static func sensorPoint(forUpright point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let (x, y) = (point.x, point.y)
        switch orientation {
        case .up: return CGPoint(x: x, y: y)
        case .down: return CGPoint(x: 1 - x, y: 1 - y)
        case .right: return CGPoint(x: y, y: 1 - x)
        case .left: return CGPoint(x: 1 - y, y: x)
        case .upMirrored: return CGPoint(x: 1 - x, y: y)
        case .downMirrored: return CGPoint(x: x, y: 1 - y)
        case .leftMirrored: return CGPoint(x: y, y: x)
        case .rightMirrored: return CGPoint(x: 1 - y, y: 1 - x)
        }
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

/// What the coach's advice is about, like "the lamp post", outlined on the viewfinder so it's easy to find.
nonisolated struct CoachHighlight: Equatable, Sendable {
    /// In 0...1 viewfinder coordinates from the top left.
    var box: CGRect
    /// The name used in the advice, without "the", like "lamp post".
    var label: String
    /// True when only the part of the frame is known, not the object itself, so it's shown as a soft area.
    var isArea: Bool

    /// Issues whose advice names something worth pointing at, other than the subject.
    static func pointsAt(_ issue: CoachIssue) -> Bool {
        [.clutteredBackground, .distractingEdges, .tooMuchEmptySpace, .linesDontLead, .linesNotStraight].contains(issue)
    }

    /// Where the named thing probably is: the eye-catching object in `region` that isn't the subject,
    /// or else that part of the frame. Nil when the region is the whole frame.
    static func locate(
        in region: FrameRegion,
        subject: CGRect?,
        among candidates: [CGRect]
    ) -> (box: CGRect, isArea: Bool)? {
        if let object = bestCandidate(in: region, subject: subject, among: candidates) {
            return (object, false)
        }
        return area(for: region, subject: subject).map { ($0, true) }
    }

    /// The object most likely to be the one the model named. Candidates are most eye-catching first.
    static func bestCandidate(in region: FrameRegion, subject: CGRect?, among candidates: [CGRect]) -> CGRect? {
        let usable = candidates.filter { box in
            let size = box.width * box.height
            // Specks aren't worth pointing at, and a box over most of the frame points at nothing.
            guard size >= 0.002, size <= 0.5 else { return false }
            // Mostly covering the subject means it is the subject.
            guard let subject else { return true }
            let overlap = box.intersection(subject)
            return overlap.isNull || overlap.width * overlap.height < 0.6 * size
        }
        switch region {
        case .left: return usable.first { $0.midX < 0.4 }
        case .right: return usable.first { $0.midX > 0.6 }
        case .top: return usable.first { $0.midY < 0.4 }
        case .bottom: return usable.first { $0.midY > 0.6 }
        case .centre: return usable.first { centreArea.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        case .background:
            // Behind the subject: the nearest object that touches the area around it.
            guard let subject else { return nil }
            let around = subject.insetBy(dx: -0.1, dy: -0.1)
            return usable
                .filter { $0.intersects(around) }
                .min { distance($0, to: subject) < distance($1, to: subject) }
        case .whole: return nil
        }
    }

    /// The part of the frame `region` names, for when no single object stands out there.
    static func area(for region: FrameRegion, subject: CGRect?) -> CGRect? {
        switch region {
        case .left: CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .right: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .top: CGRect(x: 0, y: 0, width: 1, height: 0.25)
        case .bottom: CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
        case .centre: centreArea
        // Just around the subject, where something behind it shows.
        case .background: subject?.insetBy(dx: -0.06, dy: -0.06).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        case .whole: nil
        }
    }

    /// Blends a newly found box into the shown one, so the outline follows the object without jittering.
    static func blend(_ shown: CGRect, toward found: CGRect) -> CGRect {
        CGRect(
            x: shown.minX * 0.6 + found.minX * 0.4,
            y: shown.minY * 0.6 + found.minY * 0.4,
            width: shown.width * 0.6 + found.width * 0.4,
            height: shown.height * 0.6 + found.height * 0.4
        )
    }

    private static let centreArea = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    private static func distance(_ box: CGRect, to subject: CGRect) -> CGFloat {
        hypot(box.midX - subject.midX, box.midY - subject.midY)
    }
}

/// Outlines what the coach's advice is about, in orange so it can't be mistaken for the
/// yellow box around the chosen subject. Put it on top of the preview, sized like the viewfinder.
struct CoachHighlightOverlay: View {
    let highlight: CoachHighlight

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(
                x: highlight.box.minX * proxy.size.width,
                y: highlight.box.minY * proxy.size.height,
                width: highlight.box.width * proxy.size.width,
                height: highlight.box.height * proxy.size.height
            )
            // At the top edge the tag would be cut off above the box, so it goes underneath instead.
            let tagBelow = rect.minY < 24
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape
                .fill(.orange.opacity(highlight.isArea ? 0.18 : 0))
                .strokeBorder(.orange.opacity(highlight.isArea ? 0.6 : 1), style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                .phaseAnimator([false, true]) { outline, isBright in
                    outline.opacity(isBright ? 1 : 0.55)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: tagBelow ? .bottomLeading : .topLeading) {
                    Text(highlight.label.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: .capsule)
                        .alignmentGuide(.top) { $0[.bottom] + 4 }
                        .alignmentGuide(.bottom) { $0[.top] - 4 }
                }
                .shadow(color: .black.opacity(0.4), radius: 2)
                .offset(x: rect.minX, y: rect.minY)
                .animation(.snappy, value: highlight)
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
nonisolated enum SubjectPlacement: Equatable, Sendable {
    /// The nearest of the four points where the thirds lines cross.
    case thirdsPoint
    /// A vertical thirds line (x is 1/3 or 2/3), at whatever height the subject is.
    case thirdsLine(CGFloat)
    case centre
    /// The vertical middle line, at whatever height the subject is.
    case centreLine

    /// Where this is, in a few words, for telling the model where the subject was placed.
    var name: String {
        switch self {
        case .thirdsPoint: "on a thirds crossing"
        case .thirdsLine: "on a third line"
        case .centre: "in the centre"
        case .centreLine: "on the centre line"
        }
    }

    /// The photography idea behind putting the subject here, shown under the guide's advice.
    var why: String {
        switch self {
        case .thirdsPoint, .thirdsLine: "A subject on a third line feels more natural than one dead centre."
        case .centre: "A centred subject feels bold and balanced."
        case .centreLine: "Centring the subject lets both halves mirror each other."
        }
    }

    /// True when the guide fixes the subject's height as well as its side, so moving the
    /// camera up or down would take the subject off its spot.
    var fixesHeight: Bool {
        switch self {
        case .thirdsPoint, .centre: true
        case .thirdsLine, .centreLine: false
        }
    }
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
    /// Where the chosen style wants the subject.
    var placement: SubjectPlacement = .thirdsPoint
    /// True for the front camera, whose view is mirrored: there the scene moves the same way
    /// as the phone, so left and right swap in the advice and the guide.
    var isMirrored = false
    /// How many degrees the view spans, so the advice can say how far to turn. Nil when unknown.
    var fieldOfView: FieldOfView? = nil

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
    /// Which way the subject has to slide across the view, as the phone sees it: in a mirrored view
    /// the scene follows the phone, so the phone moves the same way as the subject has to.
    private var moveX: CGFloat { isMirrored ? -dx : dx }

    /// Puts the target where the chosen composition style wants the subject.
    /// `wasAligned` is the last result, so a lined-up subject gets the looser `holdTolerance`.
    /// `previous` is the last target, so the coach doesn't flip between left and right:
    /// the same crossing is kept, and moving just past the box counts as lined up.
    static func make(
        subject: CGRect,
        placement: SubjectPlacement,
        wasAligned: Bool = false,
        previous: SubjectTarget? = nil,
        isMirrored: Bool = false,
        fieldOfView: FieldOfView? = nil
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
            aimPoint: point,
            placement: placement,
            isMirrored: isMirrored,
            fieldOfView: fieldOfView
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
            let side = moveX > 0 ? "left" : "right"
            // With the lens's field of view known, say how far: a beginner can turn 10° in one go.
            if let span = fieldOfView?.horizontal {
                steps.append("Turn the phone about \(FieldOfView.degrees(dx, across: span))° \(side)")
            } else {
                steps.append("Move the camera\(amount(dx)) \(side)")
            }
        }
        if abs(dy) >= Self.axisThreshold {
            let side = dy > 0 ? "up" : "down"
            if let span = fieldOfView?.vertical {
                steps.append("Tilt the phone about \(FieldOfView.degrees(dy, across: span))° \(side)")
            } else {
                steps.append("Move the camera\(amount(dy)) \(side)")
            }
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

    /// Where the phone has to point, in frame coordinates, if the centre is where it points now.
    /// The opposite of the subject's shift on the back camera: to slide the subject right, the phone moves left.
    /// As the person moves the phone, this slides into the centre.
    var phoneAim: CGPoint {
        CGPoint(x: min(max(0.5 - moveX, 0.05), 0.95), y: min(max(0.5 - dy, 0.05), 0.95))
    }

    /// An arrow for the phone move `cameraAdvice` asks for, so the card's icon agrees with its words.
    var moveSymbol: String {
        let horizontal = abs(dx) >= Self.axisThreshold ? (moveX > 0 ? "left" : "right") : nil
        let vertical = abs(dy) >= Self.axisThreshold ? (dy > 0 ? "up" : "down") : nil
        switch (vertical, horizontal) {
        case let (vertical?, horizontal?): return "arrow.\(vertical).\(horizontal)"
        case let (vertical?, nil): return "arrow.\(vertical)"
        case let (nil, horizontal?): return "arrow.\(horizontal)"
        case (nil, nil): return "scope"
        }
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

/// Keeps the target guide up to date while the Composition topic is chosen.
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

        var wasPaused = false
        while !Task.isCancelled {
            // A call or another app: stop looking for the subject until the camera is back.
            let isPaused = camera.isCoachPaused
            if isPaused != wasPaused {
                camera.frameGrabber.setTracksSubject(!isPaused)
                wasPaused = isPaused
            }
            if !isPaused, let found = latestSubject(from: camera) {
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
                    previous: target,
                    isMirrored: camera.isUsingFrontCamera,
                    fieldOfView: CameraReadings.read(from: camera).viewSpan(isLandscape: found.aspect > 1)
                )
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func latestSubject(from camera: CameraManager) -> (box: CGRect, aspect: CGFloat)? {
        camera.frameGrabber.latestSubject()
    }

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

/// Shows which way to move the phone, like Samsung's shot suggestions: the dot in the middle is
/// where the phone points now, and the ring is where it should point. Move the phone toward the
/// ring until the dot is inside it, and everything turns green. Put it on top of the preview,
/// sized exactly like the preview.
struct SubjectTargetOverlay: View {
    let target: SubjectTarget
    let frameAspect: CGFloat

    private let ringSize: CGFloat = 56
    private let dotSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let subjectRect = viewRect(for: target.subject, in: proxy.size)
            let aimRect = viewRect(for: CGRect(origin: target.phoneAim, size: .zero), in: proxy.size)
            let centreRect = viewRect(for: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), in: proxy.size)
            let aim = aimRect.origin
            let dot = centreRect.origin
            let tint: Color = target.isAligned ? .green : .white

            ZStack(alignment: .topLeading) {
                // Once lined up, the subject is framed in green to show it's in place.
                if target.isAligned {
                    CornerBrackets()
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: subjectRect.width, height: subjectRect.height)
                        .offset(x: subjectRect.minX, y: subjectRect.minY)
                }

                // A dashed line from the centre to where the phone should point, until they meet.
                if !target.isAligned {
                    Path { path in
                        path.move(to: dot)
                        path.addLine(to: aim)
                    }
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                    // Chevrons along the line show which way to move the phone.
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

// MARK: - Light guide

/// The amber colour of Light & Exposure's guides, so they never look like Composition's white
/// "point the camera" arrow.
extension Color {
    static let lightGuide = Color(red: 1, green: 0.72, blue: 0.22)
}

/// Light & Exposure's signals on the viewfinder, sized like the preview:
/// - where the light comes from: a sun or lamp at that edge, or on the bright spot itself
/// - "you move": a curved arrow around the subject, the way to walk
/// - "subject moves": a short arrow from the subject toward the light, with a person badge
/// Settings tips show no arrow; their fix is a button on the card.
struct LightGuideOverlay: View {
    let feedback: PhotoFeedback

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let point = markerPoint(in: size) {
                    lightMarker
                        .position(point)
                }
                if let box = feedback.subjectBox.map({ Self.rect($0, in: size) }) {
                    switch feedback.mover {
                    case .photographer:
                        WalkAroundArrow(box: box, side: feedback.lightSide)
                    case .subject:
                        SubjectTurnArrow(box: box, side: feedback.lightSide)
                    default:
                        EmptyView()
                    }
                }
            }
            .animation(.snappy, value: feedback.lightSide)
            .animation(.snappy, value: feedback.mover)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func rect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// On the light itself when it's in the frame, otherwise at the edge it comes from.
    private func markerPoint(in size: CGSize) -> CGPoint? {
        if let spot = feedback.lightSpot {
            return CGPoint(x: spot.midX * size.width, y: spot.midY * size.height)
        }
        switch feedback.lightSide {
        case .left: return CGPoint(x: 28, y: size.height * 0.4)
        case .right: return CGPoint(x: size.width - 28, y: size.height * 0.4)
        case .top: return CGPoint(x: size.width / 2, y: 80)
        default: return nil
        }
    }

    private var lightMarker: some View {
        Image(systemName: feedback.isOutdoorLight ? "sun.max.fill" : "lightbulb.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.lightGuide)
            .padding(8)
            .background(.black.opacity(0.35), in: .circle)
            .overlay(Circle().strokeBorder(Color.lightGuide, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 3)
            .phaseAnimator([false, true]) { marker, isBright in
                marker.opacity(isBright ? 1 : 0.7)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// A curved arrow under the subject, going the way to walk around it: it says "walk around",
/// not "point the camera". With no side known, a dashed ring says "walk around it" without a way.
private struct WalkAroundArrow: View {
    let box: CGRect
    let side: LightSide?

    var body: some View {
        let centre = CGPoint(x: box.midX, y: box.midY)
        let radius = max(box.width, box.height) / 2 + 24
        ZStack {
            Circle()
                .strokeBorder(Color.lightGuide.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: radius * 2, height: radius * 2)
                .position(centre)
            if let side = side?.sideWord {
                // The near half of the circle, from below the subject round to its left or right.
                let toLeft = side == "left"
                Path { path in
                    path.addArc(center: centre, radius: radius, startAngle: .degrees(90),
                                endAngle: .degrees(toLeft ? 175 : 5), clockwise: !toLeft)
                }
                .stroke(Color.lightGuide, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                // Going round from below, the arrow at the side end points up, the way of travel.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.lightGuide)
                    .position(x: centre.x + (toLeft ? -radius : radius), y: centre.y - 6)
                Image(systemName: "figure.walk")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(6)
                    .background(Color.lightGuide, in: .circle)
                    .scaleEffect(x: toLeft ? -1 : 1)
                    .position(x: centre.x, y: centre.y + radius)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

/// A short arrow from the subject toward the light, with a person badge: "ask them to turn".
private struct SubjectTurnArrow: View {
    let box: CGRect
    let side: LightSide?

    var body: some View {
        let toLeft = side == .left
        HStack(spacing: 4) {
            if side?.sideWord != nil, toLeft {
                Image(systemName: "arrow.left").font(.title2.weight(.bold))
            }
            Image(systemName: "person.fill").font(.headline)
            if side?.sideWord != nil, !toLeft {
                Image(systemName: "arrow.right").font(.title2.weight(.bold))
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.lightGuide, in: .capsule)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .position(x: box.midX, y: max(box.minY - 24, 24))
    }
}
