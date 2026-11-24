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
import Vision
import UIKit
import os

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
    /// How to turn frames upright for the way the phone is held. Portrait by default.
    private var frameOrientation: CGImagePropertyOrientation = .right
    // The object the person tapped, followed from frame to frame.
    private var selected: SelectedObject?
    /// Where the person tapped, waiting for the next frame to find what's there.
    private var pendingTap: CGPoint?
    private var tracker: VNTrackObjectRequest?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTrack = Date.distantPast
    /// Checks in a row the tracker wasn't sure, so one blurry frame doesn't drop the object.
    private var missedTracks = 0
    /// The followed object was lost, until the next tap.
    private var lostSelection = false
    /// Goes up on every tap, clear and turn of the phone, so a lookup that finishes after
    /// one of those knows it's out of date and doesn't bring back an old selection.
    private var selectionGeneration = 0

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
        let orientation = frameOrientation
        let tap = pendingTap
        pendingTap = nil
        let follower = tracker
        let generation = selectionGeneration
        lock.unlock()

        if let tap {
            startFollowing(at: tap, in: buffer, orientation: orientation, generation: generation)
        } else if let follower, Date().timeIntervalSince(lastTrack) > 0.1 {
            lastTrack = Date()
            follow(follower, in: buffer, orientation: orientation)
        }

        // Looking for the subject costs a little, so only do it when the green box is on,
        // and not at all while the person has picked the subject themselves.
        guard tracking, follower == nil, tap == nil, Date().timeIntervalSince(lastDetection) > 0.3 else { return }
        lastDetection = Date()
        // Frames arrive in the sensor's landscape shape, so held upright the aspect is height over width.
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let aspect = Self.isSideways(orientation) ? height / width : width / height
        guard let box = SubjectFinder.subject(in: buffer, orientation: orientation) else { return }
        lock.lock()
        subject = (box, aspect)
        lock.unlock()
    }

    /// Whether turning a frame this way swaps its width and height.
    private static func isSideways(_ orientation: CGImagePropertyOrientation) -> Bool {
        [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
    }

    func setFrameOrientation(_ orientation: CGImagePropertyOrientation) {
        lock.lock()
        if orientation != frameOrientation {
            // Turning the phone turns the frame: carry the followed box across, then look the
            // object up again at its new spot. Switching cameras shows a different scene, so it's dropped.
            // Mirrored frames are the front camera, so a change between mirrored and not is a camera switch.
            let switchedCamera = (Self.unmirrored(orientation) == nil) != (Self.unmirrored(frameOrientation) == nil)
            if !switchedCamera, let current = selected,
               let box = Self.rotate(current.box, from: frameOrientation, to: orientation) {
                selected = SelectedObject(box: box, frameAspect: 1 / current.frameAspect, name: current.name)
                pendingTap = CGPoint(x: box.midX, y: box.midY)
            } else {
                selected = nil
                pendingTap = nil
            }
            tracker = nil
            selectionGeneration += 1
        }
        frameOrientation = orientation
        lock.unlock()
    }

    /// A box in one upright frame, in another upright frame of the same sensor image.
    private static func rotate(_ box: CGRect, from old: CGImagePropertyOrientation, to new: CGImagePropertyOrientation) -> CGRect? {
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
        let mapped = corners.compactMap { corner in
            sensorPoint(corner, in: old).flatMap { uprightPoint($0, in: new) }
        }
        guard mapped.count == 2 else { return nil }
        return CGRect(
            x: min(mapped[0].x, mapped[1].x),
            y: min(mapped[0].y, mapped[1].y),
            width: abs(mapped[0].x - mapped[1].x),
            height: abs(mapped[0].y - mapped[1].y)
        )
    }

    /// A sensor-frame point (0...1 from the top left) once the frame is turned upright with `orientation`.
    private static func uprightPoint(_ point: CGPoint, in orientation: CGImagePropertyOrientation) -> CGPoint? {
        // A mirrored frame is the unmirrored one flipped left to right.
        if let plain = unmirrored(orientation) {
            return uprightPoint(point, in: plain).map { CGPoint(x: 1 - $0.x, y: $0.y) }
        }
        return switch orientation {
        case .up: point
        case .down: CGPoint(x: 1 - point.x, y: 1 - point.y)
        // Turned a quarter clockwise: the sensor's top edge becomes the right side.
        case .right: CGPoint(x: 1 - point.y, y: point.x)
        case .left: CGPoint(x: point.y, y: 1 - point.x)
        default: nil
        }
    }

    /// The reverse of `uprightPoint`.
    private static func sensorPoint(_ point: CGPoint, in orientation: CGImagePropertyOrientation) -> CGPoint? {
        if let plain = unmirrored(orientation) {
            return sensorPoint(CGPoint(x: 1 - point.x, y: point.y), in: plain)
        }
        return switch orientation {
        case .up: point
        case .down: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .right: CGPoint(x: point.y, y: 1 - point.x)
        case .left: CGPoint(x: 1 - point.y, y: point.x)
        default: nil
        }
    }

    /// The plain orientation a mirrored one flips, or nil when `orientation` isn't mirrored.
    /// Checked by turning a test image: `.leftMirrored` is `.right` flipped left to right.
    private static func unmirrored(_ orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation? {
        switch orientation {
        case .upMirrored: .up
        case .downMirrored: .down
        case .leftMirrored: .right
        case .rightMirrored: .left
        default: nil
        }
    }

    // MARK: Following a tapped object

    /// Finds the object at `point` (0...1 of the whole upright frame, from the top left) in the next frame, then follows it.
    func selectObject(at point: CGPoint) {
        lock.lock()
        pendingTap = point
        lostSelection = false
        selectionGeneration += 1
        lock.unlock()
    }

    func clearSelection() {
        lock.lock()
        selected = nil
        tracker = nil
        pendingTap = nil
        lostSelection = false
        selectionGeneration += 1
        lock.unlock()
    }

    /// The object being followed, whether a tap is still being looked up, and whether the object was lost.
    func selection() -> (object: SelectedObject?, isPending: Bool, isLost: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (selected, pendingTap != nil, lostSelection)
    }

    /// Width divided by height of the newest frame once turned upright.
    /// Where a point in the upright frame is on the sensor, for tap to focus.
    func sensorPoint(forUpright point: CGPoint) -> CGPoint {
        lock.lock()
        let orientation = frameOrientation
        lock.unlock()
        return FrameMapping.sensorPoint(forUpright: point, orientation: orientation)
    }

    func uprightAspect() -> CGFloat? {
        lock.lock()
        let buffer = latest
        let orientation = frameOrientation
        lock.unlock()
        guard let buffer else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        return Self.isSideways(orientation) ? height / width : width / height
    }

    private func startFollowing(
        at point: CGPoint,
        in buffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        generation: Int
    ) {
        // Looked up on an upright copy, so the object's outline lines up with the tap.
        var upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let scale = Self.longestSide / max(upright.extent.width, upright.extent.height)
        if scale < 1 {
            upright = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let image = context.createCGImage(upright, from: upright.extent) else { return }
        let found = SubjectFinder.object(at: point, in: image)
        let start = VNDetectedObjectObservation(
            boundingBox: CGRect(x: found.box.minX, y: 1 - found.box.maxY, width: found.box.width, height: found.box.height)
        )
        let request = VNTrackObjectRequest(detectedObjectObservation: start)
        request.trackingLevel = .accurate
        lock.lock()
        // A newer tap, a clear, or a turn of the phone while looking means this result is stale.
        if generation == selectionGeneration, orientation == frameOrientation {
            selected = SelectedObject(box: found.box, frameAspect: CGFloat(image.width) / CGFloat(image.height), name: found.name)
            tracker = request
            sequenceHandler = VNSequenceRequestHandler()
            missedTracks = 0
        }
        lock.unlock()
    }

    private func follow(_ request: VNTrackObjectRequest, in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        lock.lock()
        let handler = sequenceHandler
        lock.unlock()
        guard (try? handler.perform([request], on: buffer, orientation: orientation)) != nil,
              let observation = request.results?.first as? VNDetectedObjectObservation else { return }

        lock.lock()
        defer { lock.unlock() }
        guard tracker === request else { return }
        guard observation.confidence >= 0.3 else {
            missedTracks += 1
            if missedTracks >= 5 {
                selected = nil
                tracker = nil
                lostSelection = true
            }
            return
        }
        missedTracks = 0
        request.inputObservation = observation
        let box = observation.boundingBox
        selected?.box = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    func setTracksSubject(_ on: Bool) {
        lock.lock()
        tracksSubject = on
        if !on { subject = nil }
        lock.unlock()
    }

    /// The main subject's box in a recent frame, while tracking is on. The tapped object, if there is one.
    func latestSubject() -> (box: CGRect, aspect: CGFloat)? {
        lock.lock()
        defer { lock.unlock() }
        if let selected {
            return (selected.box, selected.frameAspect)
        }
        return subject
    }

    /// The newest frame, turned upright for the way the phone is held, cropped to the viewfinder's
    /// `portraitAspect` (width ÷ height when held upright) so the coach only judges what the person
    /// can see, and shrunk so the model can read it quickly.
    func latestImage(portraitAspect: CGFloat? = nil) -> CGImage? {
        lock.lock()
        let buffer = latest
        let orientation = frameOrientation
        lock.unlock()
        guard let buffer else { return nil }

        // Frames arrive in the sensor's landscape orientation, so turn them upright.
        var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        if let portraitAspect, portraitAspect > 0 {
            // Held sideways, the viewfinder's long side runs across.
            let portraitAspect = Self.isSideways(orientation) ? portraitAspect : 1 / portraitAspect
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
    /// Where the target guide puts the subject for the picked styles. The first style that
    /// places the subject leads. Styles that don't still get a guide: the middle for One-Point
    /// Perspective, where the lines meet, and otherwise the nearest thirds crossing.
    static func guidePlacement(for styles: Set<CompositionGuide>) -> SubjectPlacement {
        allCases.first { styles.contains($0) && $0.subjectPlacement != nil }?.subjectPlacement
            ?? (styles.contains(.onePointPerspective) ? .centre : .thirdsPoint)
    }

    /// Where the target guide puts the subject, or nil when the style isn't about subject position.
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
        let tools = "Tools: move the camera, step closer or back, or tap a zoom button. Never suggest rotating, tilting or angling the phone"
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
    /// The camera move the first improvement asks for, shown as a big arrow on the viewfinder.
    var move: CameraMove? = nil
    /// What the first improvement names, like "the lamp post", outlined on the viewfinder.
    var highlight: CoachHighlight? = nil
    /// The third lines the first improvement names, lit up on the viewfinder grid.
    var thirdsLines: Set<ThirdsLine> = []
    /// True when the shot is ready to take.
    var isGoodEnough: Bool
    /// What to practise next, shown once the current section is complete.
    var nextSection: String? = nil
    /// Who the first improvement asks to act, for the light tips.
    var mover: Mover? = nil
    /// Where the light comes from, as measured, for the light marker on the viewfinder.
    var lightSide: LightSide? = nil
    /// A bright light source in the frame, from the top left of the viewfinder.
    var lightSpot: CGRect? = nil
    /// Outdoors, so the light is the sun rather than a lamp or window.
    var isOutdoorLight = false
    /// The subject, from the top left of the viewfinder, so a move arrow can go around it.
    var subjectBox: CGRect? = nil
    /// A setting that follows the first improvement in one tap.
    var quickFix: QuickFix? = nil
    /// The mode to go on to once this one is done, like framing once the light is good.
    var nextMode: AdviceTopic? = nil
}

/// Things in the shot besides the people, kept for a few checks after they were last seen, so one
/// frame where Vision misses them never brings back a tip that turns away from them.
struct RecentThings: Equatable {
    /// Checks a thing is kept for, counting the one it was last seen in.
    static let checks = 3
    private var lastSeen: [CGRect] = []
    private var missed = 0

    mutating func note(_ now: [CGRect]) -> [CGRect] {
        if !now.isEmpty {
            lastSeen = now
            missed = 0
            return now
        }
        guard !lastSeen.isEmpty else { return [] }
        missed += 1
        if missed >= Self.checks {
            lastSeen = []
            return []
        }
        return lastSeen
    }
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

    /// Composition got the subject lined up, so light tips mustn't move the camera until the
    /// photo is taken, or until the person has clearly moved to another view.
    private(set) var isFramingLinedUp = false
    /// The view's layout and zoom when the framing was last lined up, to tell when it's been left.
    private var linedUpLayout: [Double] = []
    private var linedUpZoom = 1.0
    /// Checks in a row the view has been clearly different from the lined-up one.
    private var driftPasses = 0

    mutating func noteFramingLinedUp(layout: [Double], zoom: Double) {
        isFramingLinedUp = true
        linedUpLayout = layout
        linedUpZoom = zoom
        driftPasses = 0
    }

    /// Lets go of the lined-up framing once the view has been clearly different twice in a row,
    /// measured like reframing for model tips, so one jumpy frame doesn't count.
    mutating func noteView(layout: [Double], zoom: Double) {
        guard isFramingLinedUp else { return }
        let zoomChange = max(zoom, linedUpZoom) / max(min(zoom, linedUpZoom), 0.1)
        let moved = SceneAnalysis.reframeAmount(from: linedUpLayout, to: layout) >= CoachRules.reframeThreshold
            || zoomChange >= 1.3
        driftPasses = moved ? driftPasses + 1 : 0
        if driftPasses >= 2 { clearFraming() }
    }

    mutating func clearFraming() {
        isFramingLinedUp = false
        linedUpLayout = []
        driftPasses = 0
    }

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
    /// "Light first": a big light problem was seen while framing, so the light should be fixed
    /// before the framing, which moving for the light would undo.
    private(set) var lightNudge: String?
    /// The nudge shows once each time a mode is started.
    private var hasNudgedLight = false

    func dismissLightNudge() { lightNudge = nil }
    /// What has been done so far, kept across topics and photos.
    private(set) var memory = CoachMemory()
    /// What was fixed and liked in each mode since the last photo, for that photo's story in the gallery.
    private(set) var progressSinceShot = ShotProgress()
    /// The mode being coached and its Composition styles, so fixes are kept under the right mode.
    private var practisingTopic: AdviceTopic?
    private var practisingStyles: [String] = []
    /// What kind of photo the camera is looking at, smoothed over the last few checks.
    private(set) var scene: SceneType?

    var isReady: Bool { feedback?.isGoodEnough ?? false }

    /// The Apple Intelligence notice is shown once per launch, not every time the topic changes.
    private static var hasExplainedModel = false

    /// Shows `text` instead of the advice for a while, unless something else replaced it first.
    private func showNotice(_ text: String, for duration: Duration) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.notice == text { self?.notice = nil }
        }
    }

    /// How often the model looks at the frame.
    private static let modelInterval: Duration = .seconds(2)
    /// How often measured-only topics refresh. Measuring is cheap, so it can be quicker.
    private static let measureInterval: Duration = .seconds(1)
    /// How long the model gets to judge a frame before the request is cancelled.
    private static let modelTimeout: Duration = .seconds(8)
    /// Failed model requests in a row after which the coach goes on with the measurements alone.
    private static let modelFailureLimit = 3
    private static let modelLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoApp", category: "coach-model")

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
    /// Checks in a row the model named something else in the same place, so one odd answer doesn't rename it.
    private var renamePasses = 0
    /// What the advice names, outlined on the viewfinder and following it as the camera moves.
    private var highlight: CoachHighlight?
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

    // The model can't tell from one photo that the person stepped closer or back, so the
    // subject's size is measured instead. Zooming counts too, as it frames the same way.
    /// How much of the frame the subject filled when a move tip appeared.
    private var moveStartSize: Double?
    /// Checks in a row the subject has been the asked-for size, so one jumpy frame doesn't count.
    private var movePasses = 0
    // Tips only the model can judge clear once the view has clearly changed since they appeared.
    /// The frame's layout, and the zoom, when a model-only tip appeared.
    private var reframeStart: (layout: [Double], zoom: CGFloat)?
    /// Checks in a row the view has been clearly different, so one jumpy frame doesn't count.
    private var reframePasses = 0
    /// Model-only tips done during this topic, so the model can't ask for them again.
    private var reframedDone: Set<CoachIssue> = []

    /// Moves done during this topic. Once someone has stepped closer, no tip asks again.
    private var movesDone: Set<DistanceMove> = []
    /// Recent backdrops (nil for none), smoothed like the scene so it doesn't flicker.
    private var recentBackdrops: [SceneType?] = []

    /// Runs until the task is cancelled. Restart it (with a new topic or selection) when the pickers change.
    func run(camera: CameraManager, topic: AdviceTopic, styles: Set<CompositionGuide>, guide: SubjectGuide) async {
        // Keep how the mode being left stood, before its card is cleared.
        noteModeState()
        practisingTopic = topic
        practisingStyles = Self.styleTitles(topic: topic, styles: styles)
        feedback = nil
        notice = nil
        lightNudge = nil
        hasNudgedLight = false
        candidate = nil
        candidateCount = 0
        movesDone = []
        reframedDone = []
        sectionProgress = 0
        sectionRecommendation = nil
        // A new topic is a new section; the memory sentence carries what was done before.
        endSection()
        memory.notePractising(topic, styles: styles)
        // Counted, so the task being replaced can't switch motion off for this one.
        attitude.start()
        defer { attitude.stop() }

        var usesModel = CoachRules.usesModel(topic) && SystemLanguageModel.default.isAvailable
        if usesModel {
            session = makeSession(for: topic, styles: styles)
            session?.prewarm()
        }
        // Say once why the tips are simpler when Apple Intelligence can't help, and what's missing.
        if CoachRules.usesModel(topic), !Self.hasExplainedModel,
           let text = CoachRules.modelNotice(for: SystemLanguageModel.default.availability) {
            Self.hasExplainedModel = true
            showNotice(text, for: .seconds(8))
        }

        var isFirstPass = true
        var lastFrame = ContinuousClock.now
        // True while the notice says the camera is paused or missing, so it's cleared once it's back.
        var showsCameraNotice = false
        // What else was in the shot lately, so tips keep it there.
        var recentThings = RecentThings()
        // Model requests in a row that failed or timed out. Past the limit, the measurements
        // speak alone, so a model that keeps failing can't leave the card empty.
        var modelFailures = 0
        while !Task.isCancelled {
            if !isFirstPass {
                try? await Task.sleep(for: usesModel ? Self.modelInterval : Self.measureInterval)
            }
            isFirstPass = false
            guard !Task.isCancelled else { continue }

            // Apple Intelligence can finish downloading, or be turned on or off, while the camera is
            // open: follow it, so the full coach starts as soon as it's ready.
            let modelReady = CoachRules.usesModel(topic) && SystemLanguageModel.default.isAvailable
            if modelReady != usesModel {
                usesModel = modelReady
                session = modelReady ? makeSession(for: topic, styles: styles) : nil
                session?.prewarm()
            } else if usesModel, session == nil {
                // Each request uses a fresh session; making it now, while the frame is analysed,
                // means the model is warm by the time it's asked.
                session = makeSession(for: topic, styles: styles)
                session?.prewarm()
            }

            // A call or another app: say so, and don't spend effort on a frozen frame.
            if let pause = camera.pauseNotice {
                notice = pause
                showsCameraNotice = true
                continue
            }
            guard let frame = currentFrame(from: camera) else {
                if ContinuousClock.now - lastFrame > .seconds(3) {
                    notice = "Waiting for the camera…"
                    showsCameraNotice = true
                }
                continue
            }
            lastFrame = .now
            if showsCameraNotice {
                notice = nil
                showsCameraNotice = false
            }

            let readings = CameraReadings.read(from: camera)
            // The object the person tapped, mapped into the part of the frame the viewfinder shows.
            let picked = camera.frameGrabber.selection().object
            let pickedBox = picked.map { picked in
                let portraitAspect = camera.aspectRatio.portraitAspect
                let viewAspect = picked.frameAspect < 1 ? portraitAspect : 1 / portraitAspect
                return FrameMapping.visibleBox(picked.box, frameAspect: picked.frameAspect, viewAspect: viewAspect)
            }
            guard var analysis = await SceneAnalysis.analyze(
                frame, readings: readings, pitch: attitude.pitch, tilt: attitude.tilt, shake: attitude.shake,
                selectedSubject: pickedBox.flatMap { $0.isEmpty ? nil : $0 }
            ), !Task.isCancelled else { continue }
            recentScenes = Array((recentScenes + [analysis.scene]).suffix(Self.sceneHistory))
            if let smoothed = SceneType.smoothed(recentScenes) {
                analysis.scene = smoothed
                scene = smoothed
            }
            recentBackdrops = Array((recentBackdrops + [analysis.backdrop]).suffix(Self.sceneHistory))
            // A backdrop is kept only when it was seen in most of the recent checks.
            let backdropCounts = Dictionary(recentBackdrops.compactMap(\.self).map { ($0, 1) }, uniquingKeysWith: +)
            let steadyBackdrop = backdropCounts.first { $0.value * 2 > recentBackdrops.count }?.key
            analysis.backdrop = analysis.scene == .people ? steadyBackdrop : nil
            analysis.otherThings = recentThings.note(analysis.otherThings)

            // Tell the picker which styles don't suit the scene.
            unavailableCompositions = CompositionGuide.unavailableStyles(in: analysis)
            // The model's suggestion: the best style for this scene that still fits what's picked.
            recommendedComposition = Self.recommendation(
                for: analysis,
                unavailable: unavailableCompositions,
                selected: styles
            )

            // Where the subject sits is geometry, so the green box decides while it's off target.
            // Composition always has the guide: the style's spot, or the nearest thirds crossing.
            let usesBox = topic == .composition
            // Light first: framing a shot whose light needs fixing gets undone by the fix.
            if usesBox, !hasNudgedLight, guide.target?.isAligned != true,
               let big = CoachRules.issues(for: .light, in: analysis).first(where: CoachRules.bigLightIssues.contains) {
                lightNudge = big.lightNudge
                hasNudgedLight = true
            }
            if usesBox, guide.target?.isAligned == true {
                memory.noteFramingLinedUp(layout: analysis.layout, zoom: Double(camera.zoomLevel))
                lightNudge = nil
            }
            // Light keeps a frame lined up in Composition only while the view is still that frame:
            // once the person has clearly moved elsewhere, moving tips are allowed again.
            if topic == .light {
                memory.noteView(layout: analysis.layout, zoom: Double(camera.zoomLevel))
            }
            if usesBox, let target = guide.target, !target.isAligned {
                // The model's praise stays on the card, so the guide and the model read as one coach.
                feedback = Self.positionFeedback(for: target, praise: sectionStrength ?? memory.recentStrengths.last)
                sectionProgress = target.progress
                continue
            }

            // Moving the camera doesn't change the light, so light tips clear only once the model
            // stops seeing the problem, not when the view changes.
            if let shownIssue, shownIssue.isModelOnly, !shownIssue.isLightQuality {
                let zoom = camera.zoomLevel
                if let start = reframeStart {
                    let zoomChange = max(zoom, start.zoom) / max(min(zoom, start.zoom), 0.1)
                    let reframeAmount = SceneAnalysis.reframeAmount(from: start.layout, to: analysis.layout)
                    let reframed = reframeAmount >= CoachRules.reframeThreshold || zoomChange >= 1.3
                    reframePasses = reframed ? reframePasses + 1 : 0
                    if reframePasses >= 2 { reframedDone.insert(shownIssue) }
                } else {
                    reframeStart = (analysis.layout, zoom)
                }
            }

            if let shownIssue, let move = shownIssue.asksToMove, let size = Self.subjectSize(in: analysis) {
                if let start = moveStartSize {
                    movePasses = move.isDone(from: start, to: size) ? movePasses + 1 : 0
                    if movePasses >= 2 { movesDone.insert(move) }
                } else {
                    moveStartSize = size
                }
            }

            let tiltShown = shownIssue == .phoneTilted
            var issues = CoachRules.issues(for: topic, in: analysis, tiltShown: tiltShown, styles: styles)
            issues.removeAll { $0.asksToMove.map(movesDone.contains) ?? false }
            var good = CoachRules.strengths(for: topic, in: analysis, tiltShown: tiltShown)
            if usesBox, guide.target?.isAligned == true {
                good.insert("Subject lined up", at: 0)
            }

            // The model is only asked when nothing it can't see past was measured, which saves
            // battery and keeps it to what it's good at: judging the look of the scene.
            var details: [CoachIssue: IssueDetail] = [:]
            // Once the subject is in place, the guide's job is done, and the model must keep it there.
            // In Light & Exposure, a frame lined up in Composition is kept: no tip moves the camera.
            let keepsPlacement = usesBox ? guide.target?.isAligned == true : (topic == .light && memory.isFramingLinedUp)
            // The rules and the model are one coach: the model hears what the rules are already
            // dealing with, so it neither repeats nor contradicts them.
            let handled = [
                CoachRules.handledNote(
                    issues: issues, keepsPlacement: usesBox && keepsPlacement,
                    placement: CompositionGuide.guidePlacement(for: styles)
                ),
                topic == .light ? CoachRules.lightKeepNote(keepsFraming: keepsPlacement) : nil,
            ].compactMap(\.self).joined(separator: " ")
            // Whether the model judged this frame, when it's meant to. Until then, nothing is praised.
            var modelAnswered = !usesModel
            var judgement: CoachJudgement?
            // The light problem the model found this pass, which its own praise mustn't contradict.
            var modelLightIssue: CoachIssue?
            if usesModel, !issues.contains(where: { $0.blocksModel(in: topic) }) {
                judgement = await judge(
                    frame, topic: topic, styles: styles, analysis: analysis,
                    selectedName: picked?.name, handled: handled.isEmpty ? nil : handled
                )
                guard !Task.isCancelled else { break }
                modelFailures = judgement == nil ? modelFailures + 1 : 0
            }
            if let judgement {
                modelAnswered = true
                var detail = IssueDetail(region: judgement.region, rawThing: judgement.thing, subjectName: picked?.name)
                detail.subjectBox = analysis.subject
                detail.isMirrored = camera.isUsingFrontCamera
                if CoachRules.allows(judgement.issue, for: topic, styles: styles),
                   let issue = judgement.issue.coachIssue,
                   !(issue.asksToMove.map(movesDone.contains) ?? false),
                   !(issue.asksToMove == .closer && analysis.isWideScene),
                   !reframedDone.contains(issue),
                   // "Cut off" is only believed when the subject really runs off an edge.
                   issue != .subjectCutOff || analysis.subjectTouchesEdge,
                   // A plain wall or glass doors aren't clutter, whatever the model says.
                   CoachRules.believes(issue, detail: detail, analysis: analysis),
                   // A tip that can only be fixed by moving the subject off its spot loses to the guide.
                   !(keepsPlacement && issue.undoesPlacement(CompositionGuide.guidePlacement(for: styles))) {
                    // What the model saw is more specific than a minor measurement, so it leads.
                    issues.removeAll { $0 == issue }
                    issues.insert(issue, at: 0)
                    // Find what the model named, so the advice can point at it and say which way to step.
                    if CoachHighlight.pointsAt(issue), detail.distraction != nil {
                        let candidates = await Self.salientObjects(in: frame)
                        guard !Task.isCancelled else { break }
                        if let found = CoachHighlight.locate(in: detail.region, subject: analysis.subject, among: candidates) {
                            detail.box = found.box
                            detail.boxIsArea = found.isArea
                            // Check the model didn't imagine it: if Vision clearly sees something else
                            // there, the tip falls back to its general wording and nothing is outlined.
                            if !found.isArea {
                                let labels = await Self.labels(of: found.box, in: frame)
                                guard !Task.isCancelled else { break }
                                if !detail.matches(labels: labels) {
                                    detail.thing = nil
                                    detail.box = nil
                                }
                            }
                        }
                    }
                    details[issue] = detail
                    // Praise the model's light verdict contradicts goes, so the card never says
                    // "Soft, even light" beside a hard-shadows tip.
                    if issue.isLightQuality {
                        modelLightIssue = issue
                        good.removeAll { !CoachRules.praise($0, survives: issue) }
                        if let kept = sectionStrength, !CoachRules.praise(kept, survives: issue) {
                            sectionStrength = nil
                        }
                    }
                }
                if let strength = Self.cleanedStrength(judgement.strength),
                   !CoachRules.contradicts(strength: strength, analysis: analysis),
                   modelLightIssue.map({ CoachRules.praise(strength, survives: $0) }) ?? true {
                    sectionStrength = strength
                    if !good.contains(strength) { good.append(strength) }
                }
            }
            issues = memory.reordered(issues, keeping: shownIssue)
            // The first request can be slow to start or time out. Saying the shot looks good on the
            // measurements alone, then finding a problem a moment later, reads as the coach changing its mind.
            // But once it has failed several times in a row, the measurements are all there is.
            if issues.isEmpty, !modelAnswered, modelFailures < Self.modelFailureLimit { continue }

            publish(
                top: issues.first,
                next: issues.dropFirst().first,
                remaining: issues.count,
                good: good,
                details: details,
                topic: topic,
                styles: styles,
                analysis: analysis,
                keepsPlacement: keepsPlacement
            )
        }
    }

    /// Call when a photo is taken: that finishes the current section.
    func noteShutter() {
        endSection()
        progressSinceShot = ShotProgress()
        // A new photo starts a new framing.
        memory.clearFraming()
    }

    /// What the coach knew when the shutter fired, kept with the photo for its story in the gallery.
    /// Call before `noteShutter()`, which ends the section this describes.
    func shotRecord(topic: AdviceTopic, styles: Set<CompositionGuide>) -> ShotRecord {
        let praised = currentPraise
        let styleTitles = Self.styleTitles(topic: topic, styles: styles)
        var progress = progressSinceShot
        progress.noteState(of: topic, styles: styleTitles, praised: praised, wasReady: isReady)
        let modes = progress.results(current: topic)
        return ShotRecord(
            topicID: topic.rawValue,
            styles: styleTitles,
            scene: scene?.title,
            wasReady: isReady,
            fixed: modes.first { $0.topicID == topic.rawValue }?.fixed ?? [],
            praised: praised,
            suggestion: isReady ? nil : feedback?.improve.first,
            date: .now,
            modes: modes
        )
    }

    /// What the card likes now, plus the section's strength.
    private var currentPraise: [String] {
        var praised = feedback?.good ?? []
        if let sectionStrength, !praised.contains(sectionStrength) {
            praised.append(sectionStrength)
        }
        return praised
    }

    /// Saves how the mode being coached stands, when the person moves to another mode.
    private func noteModeState() {
        guard let practisingTopic, feedback != nil else { return }
        progressSinceShot.noteState(of: practisingTopic, styles: practisingStyles, praised: currentPraise, wasReady: isReady)
    }

    private static func styleTitles(topic: AdviceTopic, styles: Set<CompositionGuide>) -> [String] {
        topic == .composition ? CompositionGuide.allCases.filter(styles.contains).map(\.title) : []
    }

    // MARK: - Sections and memory

    /// Ends the current section: remembers what was done, so the next session starts from there.
    private func endSection(fixed issue: CoachIssue? = nil) {
        if let issue {
            memory.noteFixed(issue)
            if let practisingTopic {
                progressSinceShot.noteFixed(issue.accomplishment, in: practisingTopic, styles: practisingStyles)
            }
        }
        if let sectionStrength {
            memory.noteStrength(sectionStrength)
        }
        session = nil
        shownIssue = nil
        sectionDetail = nil
        renamePasses = 0
        highlight = nil
        usesAlternative = false
        sectionStrength = nil
        sectionProgress = 0
        sectionIssueCount = 1
        moveStartSize = nil
        reframeStart = nil
        reframePasses = 0
        movePasses = 0
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
        analysis: SceneAnalysis,
        keepsPlacement: Bool = false
    ) {
        if candidate == .some(top) {
            candidateCount += 1
        } else {
            candidate = .some(top)
            candidateCount = 1
        }
        // A first tip shows at once, but "looks good" must be seen twice, so it isn't taken back.
        let isFirstVerdict = feedback == nil && top != nil
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
                nextSection: sectionRecommendation,
                // Light first, then framing: once the light is good, it's time to frame the shot.
                nextMode: topic == .light ? .composition : nil
            )
            return
        }

        sectionRecommendation = nil
        if isNewSection {
            sectionIssueCount = max(remaining, 1)
            // The usual tip didn't work in earlier sections, so try a different one.
            usesAlternative = memory.timesShown(top) >= CoachMemory.repeatLimit
                && top.alternativeAdvice(for: topic, analysis: analysis, keepsPlacement: keepsPlacement) != nil
            memory.noteShown(top)
            sectionDetail = details[top]
            renamePasses = 0
        } else if let detail = details[top], detail.region != sectionDetail?.region,
                  detail.region != sectionDetail?.region.opposite {
            // The problem has moved, so the direction has to change too. A jump to the
            // opposite side is the model wavering, not the scene, so the tip keeps its
            // direction rather than flipping between left and right.
            sectionDetail = detail
            renamePasses = 0
        } else if let detail = details[top], detail.thing != nil, detail.thing != sectionDetail?.thing {
            // Something else is causing it now, e.g. the person stepped past the lamp post and
            // a sign is behind the subject. Seen twice in a row, the advice names the new thing.
            renamePasses += 1
            if renamePasses >= 2 {
                sectionDetail = detail
                renamePasses = 0
            }
        } else if details[top] != nil {
            renamePasses = 0
        }
        updateHighlight(for: top, latest: details[top])
        // The ring fills as the issues in the section are cleared.
        sectionProgress = max(
            0.1,
            1 - Double(remaining) / Double(max(sectionIssueCount, remaining, 1))
        )

        let usual = top.advice(for: topic, analysis: analysis, detail: sectionDetail, keepsPlacement: keepsPlacement)
        // The other way must still be possible here; if it isn't, the usual tip stays.
        let alternative = top.alternativeAdvice(for: topic, analysis: analysis, keepsPlacement: keepsPlacement)
        let advice = usesAlternative ? (alternative ?? usual) : usual
        var improve = [advice.action]
        // The rules and the model are one coach: the second tip is left out when it would
        // undo the first, or move the subject off the spot the guide put it in.
        if let next, CoachRules.showsSecondTip(for: topic),
           !(keepsPlacement && next.undoesPlacement(CompositionGuide.guidePlacement(for: styles))) {
            let then = next.advice(for: topic, analysis: analysis, detail: details[next], keepsPlacement: keepsPlacement)
            if !then.conflicts(with: advice) {
                improve.append(then.action)
            }
        }
        feedback = PhotoFeedback(
            good: Array(good.prefix(2)),
            improve: improve,
            why: advice.why,
            symbol: advice.symbol,
            move: top.asksToMove.map { $0 == .closer ? .closer : .back },
            highlight: highlight,
            thirdsLines: advice.thirdsLines,
            isGoodEnough: false,
            mover: advice.mover,
            lightSide: advice.lightSide,
            lightSpot: topic == .light ? analysis.lightSpot : nil,
            isOutdoorLight: analysis.isOutdoors,
            subjectBox: analysis.subject ?? analysis.faces.max { $0.width * $0.height < $1.width * $1.height },
            quickFix: advice.quickFix
        )
    }

    /// Outlines what the section's advice names. The wording stays fixed for the section, but the
    /// outline follows the thing as the camera moves, while the model still names the same thing.
    private func updateHighlight(for issue: CoachIssue, latest: IssueDetail?) {
        guard CoachHighlight.pointsAt(issue), let detail = sectionDetail,
              let name = detail.distraction, let sectionBox = detail.box else {
            highlight = nil
            return
        }
        let label = name.hasPrefix("the ") ? String(name.dropFirst(4)) : name
        let current = latest.flatMap { $0.thing == detail.thing && $0.box != nil ? $0 : nil }
        let found = current?.box ?? sectionBox
        let shown = highlight?.label == label ? highlight?.box : nil
        highlight = CoachHighlight(
            box: shown.map { CoachHighlight.blend($0, toward: found) } ?? found,
            label: label,
            isArea: current?.boxIsArea ?? detail.boxIsArea
        )
    }

    /// Eye-catching objects in the frame. Runs off the main thread because Vision takes a moment.
    @concurrent
    nonisolated private static func salientObjects(in frame: CGImage) async -> [CGRect] {
        SubjectFinder.salientObjects(in: frame)
    }

    /// What Vision sees in `box`. Runs off the main thread because Vision takes a moment.
    @concurrent
    nonisolated private static func labels(of box: CGRect, in frame: CGImage) async -> [(label: String, confidence: Float)] {
        SubjectFinder.labels(of: box, in: frame)
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
                return "Section complete. Try the \(next.title.keptTogether) style next."
            }
            return "Section complete. Try another topic from the menu."
        }

        let topics = AdviceTopic.allCases
        guard topics.count > 1, let index = topics.firstIndex(of: topic) else { return nil }
        let next = topics[(index + 1) % topics.count]
        return "Section complete. Try the \(next.displayTitle) topic next."
    }

    /// Picks the style that best matches the scene, falling back to the first available one.
    private static func preferredNextStyle(
        for analysis: SceneAnalysis,
        from candidates: [CompositionGuide]
    ) -> CompositionGuide? {
        guard !candidates.isEmpty else { return nil }
        // Styles that suit this kind of scene come first.
        var preferred = analysis.scenes.flatMap(\.suitedStyles)
        if analysis.personCount > 0 { preferred.append(.halfBodyPortrait) }
        if let pitch = analysis.pitch {
            if pitch < -55 { preferred.append(.tableTop90) }
            if pitch < -20 { preferred.append(.tableTop45) }
        }
        if analysis.subject != nil { preferred.append(.negativeSpace) }
        preferred += [
            .ruleOfThirdsCorner, .symmetry, .leadingLines, .centre,
            .leadingLinesAligning, .triangle, .onePointPerspective,
            .compression,
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
    /// so it isn't nudged toward an issue it can't use. Style examples come first, so a picked
    /// style's own example is always among those shown.
    private static let examples: [(issue: VisualIssue, text: String)] = [
        (.notSymmetric, #"A doorway framed off-centre, with more wall on the left: issue notSymmetric, region left, thing "the wall", strength "Strong shape"."#),
        (.noTriangle, #"Three cups in a straight row: issue noTriangle, region whole, thing "the cups", strength "Simple setup"."#),
        (.layersNotStacked, #"Hills far apart with lots of sky between them: issue layersNotStacked, region background, thing "the hills", strength "Soft colours"."#),
        (.jointsCropped, #"A portrait cut off at the knees: issue jointsCropped, region bottom, thing "the subject", strength "Sharp eyes"."#),
        (.linesDontLead, #"A path running off the right edge instead of toward the bench: issue linesDontLead, region right, thing "the path", strength "Clear subject"."#),
        (.clutteredBackground, #"A person with a lamp post right behind their head: issue clutteredBackground, region background, thing "the lamp post", strength "Soft, even light"."#),
        (.distractingEdges, #"A bright sign at the right edge: issue distractingEdges, region right, thing "the sign", strength "Clear subject"."#),
        (.subjectCutOff, #"A tree cut off at the top: issue subjectCutOff, region top, thing "the tree", strength "Rich colours"."#),
        (.hardShadowsOnSubject, #"A face lit hard from one side, with the other half lost in deep shadow: issue hardShadowsOnSubject, region left, thing "the subject", strength "Clear subject"."#),
        (.hardShadowsOnSubject, #"A face in midday sun with dark shadows under the eyes and nose: issue hardShadowsOnSubject, region centre, thing "the subject", strength "Bright colours"."#),
        (.flatLight, #"A plate lit straight from the front, looking flat with no shadows to show its shape: issue flatLight, region whole, thing "the plate", strength "Neat setup"."#),
        (.patchyLight, #"A person under a tree with spots of sun across the face: issue patchyLight, region centre, thing "the subject", strength "Nice setting"."#),
        (.sunGlare, #"A street scene washed out with haze and a flare streak from the sun just above the frame: issue sunGlare, region top, thing "the sun", strength "Clear subject"."#),
    ]
    /// Light's answers when the light is already good, so soft, even light isn't marked down.
    private static let lightNoneExample = """
        A face lit softly by a window to one side, with the far side a little darker but still clearly visible: issue none, region whole, thing "", strength "Soft side light".
        A person in open shade on a bright day: issue none, region whole, thing "", strength "Even, soft light".
        A street on a rainy, cloudy day with wet, shiny ground: issue none, region whole, thing "", strength "Soft, even light".
        """
    private static let noneExample = """
        A tidy portrait against a plain wall: issue none, region whole, thing "", strength "Clean background".
        A person in front of glass doors: issue none, region whole, thing "", strength "Clean background".
        A cup slightly off the third line with a small plant at the edge: issue none, region whole, thing "", strength "Nice framing".
        """

    private func makeSession(for topic: AdviceTopic, styles: Set<CompositionGuide>) -> LanguageModelSession {
        let allowed = VisualIssue.allCases.filter { $0 != .none && CoachRules.allows($0, for: topic, styles: styles) }
        let none = topic == .light ? Self.lightNoneExample : Self.noneExample
        // One example per issue before the limit, so no allowed issue goes without one
        // (Light has two hard-shadow examples, which used to push sun glare out).
        var seen: Set<VisualIssue> = []
        let examples = Self.examples
            .filter { allowed.contains($0.issue) && seen.insert($0.issue).inserted }
            .prefix(4).map(\.text) + [none]
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
            Never describe people: call one person the subject and several people the subjects.
            Also name one thing that already works, in 2 to 5 words.\(praised)
            \(CoachRules.plainSurfaceRule)
            Only report horizonThroughMiddle when you can see a real horizon, where land or sea meets the sky. \
            Indoor scenes, desks and close-ups have no horizon.
            Brightness, sharpness and tilt are measured by the camera and handled separately, so never report them. \
            The measurements given with each photo, including where the subject is and how big it is, are always correct.
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
        case .light:
            return """
                the quality of the light on the subject, not how bright it is: whether its shadows are \
                hard or soft, whether the light comes from the side or flat from straight ahead, whether \
                patches of sun and shade fall across it, and \
                whether the sun just outside the frame washes it out with haze or flare. \
                Side light is only good when it is soft and the shadow side still shows detail: if half of \
                the subject or a face is lost in deep, dark shadow, that is hardShadowsOnSubject, not a strength. \
                Raindrops, water on the lens, wet shiny ground and reflections are not patches of light or \
                shadows. On a cloudy or rainy day the light is soft, so pick none unless a lamp or the sun \
                clearly lights the subject
                """
        default:
            return "the framing: the background, the edges, whether the subject is cut off, and empty space"
        }
    }

    /// Asks the model about the frame. Returns nil if it couldn't answer.
    /// Internal rather than private so tests can run the app's exact prompt on test scenes.
    func judge(
        _ frame: CGImage,
        topic: AdviceTopic,
        styles: Set<CompositionGuide>,
        analysis: SceneAnalysis,
        selectedName: String? = nil,
        handled: String? = nil
    ) async -> CoachJudgement? {
        // The person chose what they're photographing, so the advice is about that.
        let chosen = selectedName.map { name in
            name == "person"
                ? "The person taking the photo tapped the subject they want to photograph; judge the photo around them."
                : "The person taking the photo tapped the \(name) as what they want to photograph; treat it as the subject and judge the photo around it."
        }
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
                    if topic == .light, let hint = CoachRules.timeOfDayHint(hour: Calendar.current.component(.hour, from: .now), outdoors: analysis.isOutdoors) {
                        hint
                    }
                    if let chosen {
                        chosen
                    }
                    // What the rules are already dealing with, so the model doesn't repeat or undo it.
                    if let handled {
                        handled
                    }
                    for scene in analysis.scenes where scene != .object {
                        scene.coachingHint
                    }
                    Attachment(frame)
                }.content
            }
        } catch {
            // Logged so a model that keeps failing (timeouts, an unsupported language, guardrails)
            // can be seen in the console instead of the coach quietly getting simpler.
            if !Task.isCancelled {
                Self.modelLog.error("\(topic.title, privacy: .public) request failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// How much of the frame the subject fills, 0...1: the main subject, or else the biggest face.
    static func subjectSize(in analysis: SceneAnalysis) -> Double? {
        if let subject = analysis.subject { return Double(subject.width * subject.height) }
        return analysis.faces.map { Double($0.width * $0.height) }.max()
    }

    /// Keeps the model's "what works" short and free of numbers.
    private static func cleanedStrength(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = trimmed.split(separator: " ").count
        guard (1...6).contains(words), !trimmed.contains(where: \.isNumber) else { return nil }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    // MARK: - Frames

    private static func positionFeedback(for placement: SubjectTarget, praise: String? = nil) -> PhotoFeedback {
        PhotoFeedback(
            good: praise.map { [$0] } ?? [],
            improve: placement.cameraAdvice,
            why: placement.placement.why,
            symbol: placement.moveSymbol,
            isGoodEnough: false
        )
    }

    /// The newest live camera frame, cropped to the viewfinder.
    private func currentFrame(from camera: CameraManager) -> CGImage? {
        camera.frameGrabber.latestImage(portraitAspect: camera.aspectRatio.portraitAspect)
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
    /// Whether the photography idea behind the advice is shown under it.
    var showsExplanation = true
    /// Whether a tip's one-tap fix can be applied on this camera right now.
    var canApply: (QuickFix) -> Bool = { _ in false }
    var onQuickFix: (QuickFix) -> Void = { _ in }
    /// Goes on to the next mode, like Composition once the light is good.
    var onNextMode: (AdviceTopic) -> Void = { _ in }

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
                    HStack(spacing: 8) {
                        Text("Do this now")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.yellow)
                            .textCase(.uppercase)
                        // Who acts, so it's never unclear whether you or the subject should move.
                        if let mover = feedback.mover {
                            Label(mover.label, systemImage: mover.systemImage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.lightGuide, in: .capsule)
                        }
                    }

                    Label {
                        Text(actionText(action))
                    } icon: {
                        Image(systemName: feedback.symbol ?? "arrow.right")
                            .foregroundStyle(.yellow)
                    }
                    .font(.headline)
                    .accessibilityHint(highlightHint)

                    if feedback.improve.count > 1 {
                        Text("Then: \(feedback.improve[1])")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Follow the tip in one tap, or do it yourself.
                    if let fix = feedback.quickFix, canApply(fix) {
                        Button(fix.title, systemImage: fix.systemImage) {
                            onQuickFix(fix)
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Color.lightGuide)
                        .foregroundStyle(.black)
                        .padding(.top, 4)
                    }
                }
            }

            // The photography idea behind the advice, so the user learns as they shoot.
            if showsExplanation, !feedback.isGoodEnough, let why = feedback.why {
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

            // Light first, then framing: once the light is good, go on to frame the shot.
            if feedback.isGoodEnough, let next = feedback.nextMode {
                Button("Light looks good. Now frame it", systemImage: next.systemImage) {
                    onNextMode(next)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .foregroundStyle(.black)
            }
        }
        // Long advice wraps onto more lines at full size, and the card grows, instead of ending in "…".
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 22))
        // Contain rather than combine, so the fix and next-mode buttons stay usable with VoiceOver.
        .accessibilityElement(children: .contain)
    }

    /// The advice in white, with the outlined thing's name in the outline's orange so the two are linked.
    private func actionText(_ action: String) -> AttributedString {
        var text = AttributedString(action)
        text.foregroundColor = .white
        if let label = feedback.highlight?.label, let range = text.range(of: label) {
            text[range].foregroundColor = .orange
        }
        return text
    }

    /// Says where the outlined thing is, for VoiceOver, which can't see the outline.
    private var highlightHint: String {
        guard let highlight = feedback.highlight else { return "" }
        let box = highlight.box
        let across = box.midX < 0.4 ? "left" : box.midX > 0.6 ? "right" : "middle"
        let down = box.midY < 0.4 ? "top" : box.midY > 0.6 ? "bottom" : nil
        let place = down.map { across == "middle" ? $0 : "\($0) \(across)" } ?? across
        return "The \(highlight.label) is outlined at the \(place) of the viewfinder."
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
