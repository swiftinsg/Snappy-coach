//
//  PreviewView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//


import SwiftUI
import UIKit
import AVFoundation

class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
    }
}

/// The viewfinder's touch layer, like the Camera app: a tap focuses and sets the brightness on
/// that spot and shows the yellow box with a sun slider beside it. While the box shows, dragging
/// up or down anywhere on the viewfinder makes the photo brighter or darker.
/// A double tap picks what to photograph. Put it inside `UprightOverlay`, so "up" is up.
struct ViewfinderTapLayer: View {
    let camera: CameraManager
    /// Focuses and meters at a tap. Returns false when the tap missed the frame.
    let onFocus: (CGPoint, CGSize) -> Bool
    /// Picks the object under a double tap.
    let onSelect: (CGPoint, CGSize) -> Void

    /// Where the last single tap landed, while its box is showing.
    @State private var mark: CGPoint?
    /// Restarts the timer that hides the box, on every tap and drag.
    @State private var markActivity = 0
    /// The exposure when a brightness drag began, so the drag moves it from there.
    @State private var biasAtDragStart: Float?

    /// Points of drag for one stop of brightness.
    private static let pointsPerStop: CGFloat = 80

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // UIKit's recognizers, because SwiftUI's single tap, double tap and drag on one
                // view kept swallowing taps and mistaking a brightness drag for a new tap.
                ViewfinderTouches(
                    isBrightnessDragEnabled: mark != nil,
                    onTap: { location in
                        if onFocus(location, proxy.size) {
                            mark = location
                            markActivity += 1
                        }
                    },
                    onDoubleTap: { location in onSelect(location, proxy.size) },
                    onDrag: dragBrightness
                )
                .accessibilityHidden(true)

                if let mark {
                    FocusExposureMark(bias: camera.exposureBias, isAdjusting: biasAtDragStart != nil)
                        .position(mark)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 1.3)))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: mark)
        // Long enough to find the sun and drag it; the box stays while dragging and for a while after.
        .task(id: markActivity) {
            guard mark != nil, biasAtDragStart == nil else { return }
            try? await Task.sleep(for: .seconds(4))
            mark = nil
        }
        .sensoryFeedback(.selection, trigger: Int((camera.exposureBias * 3).rounded())) { _, _ in
            biasAtDragStart != nil
        }
    }

    /// Up is brighter, down is darker, within the camera's ±2 stops. `translation` is nil when the drag ends.
    private func dragBrightness(_ translation: CGFloat?) {
        guard let translation else {
            biasAtDragStart = nil
            markActivity += 1
            return
        }
        let start = biasAtDragStart ?? camera.exposureBias
        biasAtDragStart = start
        let bias = start - Float(translation / Self.pointsPerStop)
        camera.setAdjustment(min(max(bias, -2), 2), for: .exposure)
        markActivity += 1
    }
}

/// The viewfinder's taps and one-finger drags, with UIKit's recognizers: a single tap waits for a
/// double tap to fail, and a drag never counts as a tap. Two-finger pinches pass through to zoom.
private struct ViewfinderTouches: UIViewRepresentable {
    let isBrightnessDragEnabled: Bool
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void
    /// The drag's upward-negative distance in points, or nil when it ends.
    let onDrag: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator

        [double, single, pan].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onDrag = onDrag
        // Checked when a drag starts rather than switching the recognizer off: switching it off
        // mid-drag cancels it right here, changing SwiftUI state during the view update.
        coordinator.isDragEnabled = isBrightnessDragEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGPoint) -> Void = { _ in }
        var onDoubleTap: (CGPoint) -> Void = { _ in }
        var onDrag: (CGFloat?) -> Void = { _ in }
        var isDragEnabled = false

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap(recognizer.location(in: recognizer.view))
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            onDoubleTap(recognizer.location(in: recognizer.view))
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                onDrag(recognizer.translation(in: recognizer.view).y)
            case .ended, .cancelled, .failed:
                onDrag(nil)
            default:
                break
            }
        }

        /// Only mostly-vertical drags change the brightness, so a sideways swipe stays free.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            guard isDragEnabled else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) >= abs(velocity.x)
        }

        /// Pinch to zoom keeps working alongside.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPinchGestureRecognizer
        }
    }
}

/// The yellow focus box, with a sun slider beside it like the Camera app's: a thin track with the
/// sun on it, which rises for brighter and falls for darker.
private struct FocusExposureMark: View {
    let bias: Float
    /// A drag is changing the brightness, so the track shows fully.
    let isAdjusting: Bool

    private static let size: CGFloat = 76
    private static let trackHeight: CGFloat = 110
    private static let sunSize: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Rectangle()
                .strokeBorder(.yellow, lineWidth: 1.5)
                .frame(width: Self.size, height: Self.size)
            slider
        }
        // Centred on the box, not on the box and slider together.
        .offset(x: (Self.sunSize + 8) / 2)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityHidden(true)
    }

    /// ±2 stops spans the whole track; the line is cut around the sun so it reads as a slider.
    private var slider: some View {
        let travel = (Self.trackHeight - Self.sunSize) / 2
        let offset = -CGFloat(bias) / 2 * travel
        return ZStack {
            Capsule()
                .fill(.yellow.opacity(isAdjusting ? 0.9 : 0.6))
                .frame(width: 1.5, height: Self.trackHeight)
                .mask {
                    Rectangle()
                        .overlay {
                            Circle()
                                .frame(width: Self.sunSize + 6, height: Self.sunSize + 6)
                                .offset(y: offset)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            Image(systemName: "sun.max.fill")
                .font(.system(size: Self.sunSize * 0.8, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: Self.sunSize, height: Self.sunSize)
                .offset(y: offset)
        }
        .frame(width: Self.sunSize, height: Self.trackHeight)
        .animation(.interactiveSpring, value: bias)
    }
}

/// A frosted layer over the viewfinder while the camera switches between front and back.
/// It fades in fast and out a little slower, so the new camera appears gently.
struct CameraSwitchBlur: View {
    let isSwitching: Bool

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .opacity(isSwitching ? 1 : 0)
            .animation(isSwitching ? .easeIn(duration: 0.12) : .easeOut(duration: 0.3), value: isSwitching)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
