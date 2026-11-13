//
//  PhotoReviewView.swift
//  Grp 6pm Photo App
//
//  Shown right after the shutter fires: a look at the photo just taken, an offer of
//  AI feedback, and a way back to the camera.
//

import SwiftUI
import UIKit
import Photos

/// A photo that was just saved, identified by its Photos library identifier.
struct CapturedPhoto: Identifiable {
    let assetIdentifier: String
    var id: String { assetIdentifier }
}

/// Full-screen review of a new photo. The person can ask Apple Intelligence for
/// feedback or head straight back to the camera.
struct PhotoReviewView: View {
    let photo: CapturedPhoto
    let gallery: PhotoGallery

    @Environment(\.dismiss) private var dismiss
    @State private var critique = PhotoCritique()
    @State private var image: UIImage?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                photoView
                panel
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            image = await gallery.image(
                forIdentifier: photo.assetIdentifier,
                size: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit
            )
        }
        .onDisappear {
            feedbackTask?.cancel()
        }
    }

    // MARK: - The photo

    private var photoView: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .accessibilityLabel("Your photo")
    }

    // MARK: - The bottom panel

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 16) {
            switch critique.state {
            case .idle:
                offer
            case .thinking:
                thinking
            case .finished(let text):
                result(text)
            case .failed(let message):
                failure(message)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.snappy, value: critique.state)
    }

    /// Asks whether to send the photo to the model.
    private var offer: some View {
        VStack(spacing: 12) {
            Label("Want AI feedback?", systemImage: "sparkles")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Send this photo to Apple Intelligence for a few tips on how to make it even better.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Button {
                requestFeedback()
            } label: {
                Label("Get Feedback", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(image == nil)

            Button("Back to Camera") {
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Shown while the model reads the photo.
    private var thinking: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)

            Label("Looking at your photo…", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Finding the strongest part of the shot and one way to improve it.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Button("Back to Camera") {
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// The model's feedback.
    private func result(_ text: String) -> some View {
        VStack(spacing: 12) {
            Label("AI Feedback", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)

            Button {
                dismiss()
            } label: {
                Text("Back to Camera")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Shown when the model can't answer, e.g. Apple Intelligence is turned off.
    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label("No Feedback Yet", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Button {
                critique.reset()
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(image == nil)

            Button("Back to Camera") {
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Starts the model request and keeps the task so leaving the screen cancels it.
    private func requestFeedback() {
        guard let image else { return }
        feedbackTask?.cancel()
        feedbackTask = Task {
            await critique.requestFeedback(for: image)
        }
    }
}

#Preview {
    PhotoReviewView(
        photo: CapturedPhoto(assetIdentifier: "preview"),
        gallery: PhotoGallery()
    )
}
