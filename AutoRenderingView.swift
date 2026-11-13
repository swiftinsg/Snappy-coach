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
    @State private var subjectGuide = SubjectGuide()
    @State private var gallery = PhotoGallery()
    @State private var isGalleryPresented = false
    /// Remembered between launches.
    @AppStorage("adviceTopic") private var adviceTopic: AdviceTopic = .composition
    /// Raw values of the selected composition styles, joined with commas, so the selection persists.
    @AppStorage("compositionGuides") private var compositionGuidesRaw = CompositionGuide.ruleOfThirdsOne.rawValue
    @State private var activeAdjustment: PhotoControl?
    @State private var statusMessage: String?
    /// Briefly blacks out the screen when a photo is taken, like the Camera app.
    @State private var isShutterBlinking = false
    /// Shows the coach's raw measurements over the card, for tuning the advice.
    @State private var isCoachDebugOn = false
    /// The zoom when the current pinch began, so the pinch scales from there.
    @State private var pinchStartZoom: CGFloat?

    /// The composition styles the person is practising. At least one is always selected,
    /// and only styles that can work together are kept.
    private var compositionGuides: Set<CompositionGuide> {
        let stored = Set(compositionGuidesRaw.split(separator: ",").compactMap { CompositionGuide(rawValue: String($0)) })
        let compatible = CompositionGuide.compatibleSelection(stored)
        return compatible.isEmpty ? [CompositionGuide.ruleOfThirdsOne] : compatible
    }

    /// Persists the selection in a stable order, never empty and never self-contradictory.
    private func setCompositionGuides(_ newValue: Set<CompositionGuide>) {
        let compatible = CompositionGuide.compatibleSelection(newValue)
        let ordered = CompositionGuide.allCases.filter(compatible.contains)
        let kept = ordered.isEmpty ? [CompositionGuide.ruleOfThirdsOne] : ordered
        compositionGuidesRaw = kept.map(\.rawValue).joined(separator: ",")
    }

    /// A stable description of the selection, used to restart the coach when it changes.
    private var compositionSelectionID: String {
        CompositionGuide.allCases.filter(compositionGuides.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The green box only appears for topics and styles about where the subject sits.
    private var showsSubjectBox: Bool {
        subjectPlacement != nil
    }

    /// Where the green box puts the subject for the chosen topic and style, if it has a box at all.
    private var subjectPlacement: SubjectPlacement? {
        switch adviceTopic {
        case .subjectPosition:
            .thirdsPoint
        case .composition:
            // With several styles picked, the first one that defines a subject position leads.
            CompositionGuide.allCases
                .first { compositionGuides.contains($0) && $0.subjectPlacement != nil }?
                .subjectPlacement
        default:
            nil
        }
    }

    /// The auto-rendering coach's latest feedback, or a notice when it can't run.
    @ViewBuilder
    private var coachCard: some View {
        VStack(spacing: 8) {
            // Hidden debug view: press and hold the card to see what the coach measured.
            if isCoachDebugOn, !coach.debugText.isEmpty {
                Text(coach.debugText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
            }
            if let notice = coach.notice {
                CoachTipView(text: notice)
            } else if let feedback = coach.feedback {
                CoachFeedbackView(feedback: feedback)
            }
        }
        .onLongPressGesture {
            isCoachDebugOn.toggle()
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // The viewfinder takes the shape of the chosen aspect ratio, with black bars
            // around it, so what you see matches the photo that's saved.
            CameraPreview(session: camera.session)
                .aspectRatio(camera.aspectRatio.portraitAspect, contentMode: .fit)
                // Grids help line the scene up while composing.
                .overlay {
                    if adviceTopic == .composition {
                        CompositionGrid(styles: compositionGuides)
                    }
                }
                // A level in the middle of the frame while practising angle and perspective.
                .overlay {
                    if adviceTopic == .anglePerspective {
                        CameraLevel(attitude: coach.attitude)
                    }
                }
                // The green box shows where the subject should be.
                .overlay {
                    if showsSubjectBox, let target = subjectGuide.target {
                        SubjectTargetOverlay(target: target, frameAspect: subjectGuide.frameAspect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .animation(.snappy, value: camera.aspectRatio)
                // Pinch to zoom, like the Camera app. Lenses switch at the same points as the zoom buttons.
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStartZoom ?? camera.zoomLevel
                            pinchStartZoom = start
                            let widest = camera.zoomStops.first ?? 1
                            let longest = max(10, camera.zoomStops.last ?? 1)
                            let level = min(max(start * value.magnification, widest), longest)
                            if let message = camera.setZoom(level) {
                                statusMessage = message
                            }
                        }
                        .onEnded { _ in
                            pinchStartZoom = nil
                        }
                )

            VStack(spacing: 12) {
                // Top bar: advice topic dropdown on the left, camera controls on the right.
                HStack(alignment: .center, spacing: 8) {
                    // Hidden rather than removed while editing, so the controls bar doesn't shift.
                    AdviceTopicMenu(selection: $adviceTopic)
                        .opacity(controls.isEditing ? 0 : 1)
                        .disabled(controls.isEditing)
                        .accessibilityHidden(controls.isEditing)
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

                // Brief banner confirming what a tap changed, e.g. "Flash Auto". It sits in the
                // stack so it appears below an open slider or histogram instead of covering them.
                if let statusMessage {
                    Text(statusMessage)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                Spacer()

                if controls.isEditing {
                    PhotoControlsSheet(model: controls)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 10) {
                        // Zoom and composition styles share one row to keep more of the viewfinder clear.
                        HStack(spacing: 8) {
                            ZoomPicker(stops: camera.zoomStops, level: camera.zoomLevel) { level in
                                if let message = camera.setZoom(level) {
                                    statusMessage = message
                                }
                            }

                            // Composition styles, only while the Composition topic is chosen.
                            if adviceTopic == .composition {
                                CompositionPicker(
                                    selection: Binding(get: { compositionGuides }, set: { setCompositionGuides($0) }),
                                    unavailable: coach.unavailableCompositions,
                                    recommended: coach.recommendedComposition,
                                    onMessage: { statusMessage = $0 }
                                )
                                    // Undo the picker's leading bleed so chips don't scroll under the zoom buttons.
                                    .padding(.leading, 16)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        // Full width, so the coach card gets room even when only the zoom buttons are showing.
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            // Floats above the controls, so a longer card never pushes them around.
                            coachCard
                                .alignmentGuide(.top) { $0[.bottom] + 12 }
                        }
                        CaptureBar(
                            camera: camera,
                            gallery: gallery,
                            sectionProgress: coach.sectionProgress
                        ) {
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
                    // Keeps the thin numerals readable against bright scenes.
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .contentTransition(.numericText(countsDown: true))
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(countdown) seconds")
            }

            Color.black
                .ignoresSafeArea()
                .opacity(isShutterBlinking ? 1 : 0)
                .allowsHitTesting(false)
        }
        .task {
            await camera.start()
        }
        // Restarts whenever the advice topic or composition selection changes, so the tips follow the pickers.
        .task(id: "\(adviceTopic.rawValue)-\(compositionSelectionID)") {
            await coach.run(camera: camera, topic: adviceTopic, styles: compositionGuides, guide: subjectGuide)
        }
        // The box follows the topic, and each style puts it in a different place.
        .task(id: "\(adviceTopic.rawValue)-\(compositionSelectionID)") {
            await subjectGuide.run(camera: camera, placement: subjectPlacement)
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
        // Swap the top bar to the controls that matter for the chosen topic.
        .onChange(of: adviceTopic, initial: true) {
            controls.setTopic(adviceTopic)
            if let activeAdjustment, !controls.pinned.contains(activeAdjustment) {
                self.activeAdjustment = nil
            }
        }
        .onChange(of: camera.shutterCount) {
            // Taking the photo finishes the coach's current section.
            coach.noteShutter()
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
