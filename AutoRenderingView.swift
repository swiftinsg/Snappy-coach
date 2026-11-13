//
//  AutoRenderingView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import SwiftUI

struct AutoRenderingView: View {
    @State private var controls = PhotoControlsModel()
    @State private var camera = CameraManager()
    @State private var coach = PhotoCoach()
    @State private var gallery = PhotoGallery()
    @State private var isGalleryPresented = false
    /// Remembered between launches.
    @AppStorage("adviceTopic") private var adviceTopic: AdviceTopic = .composition
    @AppStorage("compositionGuide") private var compositionGuide: CompositionGuide = .ruleOfThirdsOne
    @State private var activeAdjustment: PhotoControl?
    @State private var statusMessage: String?
    /// Briefly blacks out the screen when a photo is taken, like the Camera app.
    @State private var isShutterBlinking = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // The viewfinder takes the shape of the chosen aspect ratio, with black bars
            // around it, so what you see matches the photo that's saved.
            CameraPreview(session: camera.session)
                .aspectRatio(camera.aspectRatio.portraitAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .animation(.snappy, value: camera.aspectRatio)

            VStack(spacing: 12) {
                // Top bar: advice topic dropdown on the left, camera controls on the right.
                HStack(alignment: .center, spacing: 8) {
                    if !controls.isEditing {
                        AdviceTopicMenu(selection: $adviceTopic)
                            .transition(.opacity)
                    }
                    PhotoControlsBar(model: controls, camera: camera, activeAdjustment: $activeAdjustment) { message in
                        statusMessage = message
                    }
                }

                if !controls.isEditing {
                    if let activeAdjustment {
                        CameraAdjustmentSlider(control: activeAdjustment, camera: camera)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if camera.isHistogramOn {
                        HistogramView(bins: camera.histogram)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Spacer()

                if controls.isEditing {
                    PhotoControlsSheet(model: controls)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 16) {
                        if let notice = coach.notice {
                            CoachTipView(text: notice)
                                .transition(.opacity)
                        } else if let feedback = coach.feedback {
                            CoachFeedbackView(feedback: feedback)
                                .transition(.opacity)
                        }

                        ZoomPicker(stops: camera.zoomStops, level: camera.zoomLevel) { level in
                            if let message = camera.setZoom(level) {
                                statusMessage = message
                            }
                        }

                        // Composition styles, only while the Composition topic is chosen.
                        if adviceTopic == .composition {
                            CompositionPicker(selection: $compositionGuide)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        CaptureBar(camera: camera, gallery: gallery) {
                            isGalleryPresented = true
                        } onStatus: { message in
                            statusMessage = message
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .padding(.horizontal)
            // Run into the home-indicator area so the shutter row sits low, like the Camera app.
            .ignoresSafeArea(.container, edges: .bottom)

            // Self-timer countdown.
            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 120, weight: .thin))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(countdown) seconds")
            }

            Color.black
                .ignoresSafeArea()
                .opacity(isShutterBlinking ? 1 : 0)
                .allowsHitTesting(false)
        }
        // Brief banner confirming what a tap changed, e.g. "Flash Auto".
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                    .padding(.top, 72)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task {
            await camera.start()
        }
        // Restarts whenever the advice topic changes, so the tips follow the dropdown.
        .task(id: adviceTopic) {
            await coach.run(camera: camera, topic: adviceTopic)
        }
        .task {
            await gallery.load()
        }
        // Add each newly saved photo to the in-app gallery.
        .onChange(of: camera.lastSavedAssetIdentifier) {
            guard let identifier = camera.lastSavedAssetIdentifier else { return }
            Task { await gallery.add(identifier) }
        }
        .fullScreenCover(isPresented: $isGalleryPresented) {
            GalleryView(gallery: gallery)
        }
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            statusMessage = nil
        }
        .onChange(of: controls.isEditing) {
            if controls.isEditing {
                activeAdjustment = nil
            }
        }
        .onChange(of: camera.shutterCount) {
            isShutterBlinking = true
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.2)) {
                    isShutterBlinking = false
                }
            }
        }
        .animation(.spring, value: controls.isEditing)
        .animation(.snappy, value: controls.draft)
        .animation(.snappy, value: activeAdjustment)
        .animation(.snappy, value: adviceTopic)
        .animation(.easeInOut, value: statusMessage)
        .animation(.easeInOut, value: coach.feedback)
        .sensoryFeedback(.success, trigger: coach.isReady) { _, isReady in isReady }
        .animation(.snappy, value: camera.countdown)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.shutterCount)
        .sensoryFeedback(.impact, trigger: controls.draft)
        .sensoryFeedback(.selection, trigger: statusMessage)
        .environment(\.colorScheme, .dark)
    }
}

#Preview {
    AutoRenderingView()
}
