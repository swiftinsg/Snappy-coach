//
//  CaptureBar.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// Bottom row of the camera: gallery button on the left, shutter in the centre.
struct CaptureBar: View {
    let camera: CameraManager
    let gallery: PhotoGallery
    /// How much of the coach's current section is done, 0...1, drawn around the shutter.
    var sectionProgress: Double = 0
    var onOpenGallery: () -> Void = {}
    /// Called with a message to show, e.g. when saving fails or the timer is cancelled.
    var onStatus: (String) -> Void = { _ in }

    private let thumbnailSize: CGFloat = 52

    var body: some View {
        HStack {
            galleryButton
            Spacer()
            ShutterButton(
                isCountingDown: camera.countdown != nil,
                isBusy: camera.isCapturing,
                sectionProgress: sectionProgress
            ) {
                Task {
                    if let message = await camera.shutterTapped() {
                        onStatus(message)
                    }
                }
            }
            Spacer()
            switchCameraButton
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// Flips between the back and front cameras. Same size as the gallery button so the shutter stays centred.
    private var switchCameraButton: some View {
        Button {
            if let message = camera.switchCamera() {
                onStatus(message)
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .rotationEffect(.degrees(camera.isUsingFrontCamera ? 180 : 0))
                .frame(width: thumbnailSize, height: thumbnailSize)
                .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(camera.isCapturing || camera.countdown != nil)
        .animation(.snappy, value: camera.isUsingFrontCamera)
        .sensoryFeedback(.selection, trigger: camera.isUsingFrontCamera)
        .accessibilityLabel("Switch camera")
        .accessibilityValue(camera.isUsingFrontCamera ? "Front" : "Back")
    }

    /// Shows the newest photo, or a gallery icon before any photos are taken.
    private var galleryButton: some View {
        Button(action: onOpenGallery) {
            Group {
                if let image = gallery.coverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                        }
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .frame(width: thumbnailSize, height: thumbnailSize)
            .clipShape(.rect(cornerRadius: 10))
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gallery")
    }
}

/// The iOS photo shutter: a white ring around a solid white disc. During a timer
/// countdown the disc shows an X (tap again to cancel); it dims while a photo is saving.
/// A progress ring around it shows how much of the coach's section is done.
struct ShutterButton: View {
    let isCountingDown: Bool
    let isBusy: Bool
    /// 0...1. Yellow while work remains, green and complete when the shot is ready.
    let sectionProgress: Double
    let action: () -> Void

    private var progress: Double {
        min(max(sectionProgress, 0), 1)
    }

    private var isComplete: Bool {
        progress >= 1
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Track, then the filled part of the section progress.
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 5)
                    .frame(width: 88, height: 88)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        isComplete ? Color.green : Color.yellow,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 88, height: 88)
                    .shadow(color: (isComplete ? Color.green : Color.yellow).opacity(0.6), radius: 5)
                    .animation(.snappy, value: progress)

                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(.white)
                    .frame(width: 64, height: 64)
                    .opacity(isBusy ? 0.5 : 1)
                if isCountingDown {
                    Image(systemName: "xmark")
                        .font(.title2.bold())
                        .foregroundStyle(.black)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 4)
            .animation(.snappy, value: isCountingDown)
            .animation(.snappy, value: isComplete)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(isBusy)
        .accessibilityLabel(isCountingDown ? "Cancel timer" : "Take photo")
        .accessibilityValue(
            isComplete ? "Section complete" : "Section \(Int(progress * 100)) percent complete"
        )
    }
}

/// Shrinks the shutter slightly while pressed, like the Camera app.
private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
