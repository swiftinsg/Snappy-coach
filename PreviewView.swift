//
//  PreviewView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//


import SwiftUI
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
/// that spot, then dragging the yellow square up or down makes the photo brighter or darker.
/// A double tap picks what to photograph. Put it inside `UprightOverlay`, so "up" is up.
struct ViewfinderTapLayer: View {
    let camera: CameraManager
    /// Focuses and meters at a tap. Returns false when the tap missed the frame.
    let onFocus: (CGPoint, CGSize) -> Bool
    /// Picks the object under a double tap.
    let onSelect: (CGPoint, CGSize) -> Void

    /// Where the last single tap landed, while its square is showing.
    @State private var mark: CGPoint?
    /// Restarts the timer that hides the square, on every tap and drag.
    @State private var markActivity = 0
    /// The exposure when a brightness drag began, so the drag moves it from there.
    @State private var biasAtDragStart: Float?

    /// Points of drag for one stop of brightness.
    private static let pointsPerStop: CGFloat = 80

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(.rect)
                    // The double tap is checked first, so a single tap waits a moment to see it isn't one.
                    .onTapGesture(count: 2) { location in
                        onSelect(location, proxy.size)
                    }
                    .onTapGesture { location in
                        if onFocus(location, proxy.size) {
                            mark = location
                            markActivity += 1
                        }
                    }
                    .accessibilityHidden(true)

                if let mark, camera.isFocusPointSet {
                    FocusExposureMark(bias: camera.exposureBias)
                        .position(mark)
                        .gesture(brightnessDrag)
                        .transition(.opacity.combined(with: .scale(scale: 1.3)))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: mark)
        .task(id: markActivity) {
            guard mark != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            mark = nil
        }
    }

    /// Up is brighter, down is darker, within the camera's ±2 stops.
    private var brightnessDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = biasAtDragStart ?? camera.exposureBias
                biasAtDragStart = start
                let bias = start - Float(value.translation.height / Self.pointsPerStop)
                camera.setAdjustment(min(max(bias, -2), 2), for: .exposure)
                markActivity += 1
            }
            .onEnded { _ in
                biasAtDragStart = nil
            }
    }
}

/// The yellow focus square, with a sun beside it that rises and falls with the brightness.
private struct FocusExposureMark: View {
    let bias: Float

    private static let size: CGFloat = 76

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Rectangle()
                .strokeBorder(.yellow, lineWidth: 1.5)
                .frame(width: Self.size, height: Self.size)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16))
                .foregroundStyle(.yellow)
                // ±2 stops spans the height of the square.
                .offset(y: -CGFloat(bias) / 2 * Self.size / 2)
        }
        // Centred on the square, not on the square and sun together.
        .offset(x: 11)
        .frame(width: Self.size + 44, height: Self.size + 44)
        .contentShape(.rect)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityHidden(true)
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
