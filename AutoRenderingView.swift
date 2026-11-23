//
//  AutoRenderingView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import AVKit
import FoundationModels
import SwiftUI

struct AutoRenderingView: View {
    @State private var controls = PhotoControlsModel()
    @State private var camera = CameraManager()
    @State private var coach = PhotoCoach()
    @State private var subjectGuide = SubjectGuide()
    /// The object the person tapped to get advice about.
    @State private var objectSelection = ObjectSelection()
    @State private var gallery = PhotoGallery()
    @State private var isGalleryPresented = false
    /// How far the zoom row, composition styles and shutter reach up from the bottom of the screen,
    /// so the sideways advice card can stop short of them.
    @State private var bottomControlsHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Remembered between launches.
    @AppStorage("adviceTopic") private var adviceTopic: AdviceTopic = .composition
    /// Raw values of the selected composition styles, joined with commas, so the selection persists.
    @AppStorage("compositionGuides") private var compositionGuidesRaw = CompositionGuide.ruleOfThirdsOne.rawValue
    @State private var activeAdjustment: PhotoControl?
    @State private var statusMessage: String?
    /// What the coach knew at each shutter press, waiting for its photo to finish saving. Oldest first,
    /// so quick shots in a row each keep their own story.
    @State private var pendingShots: [ShotRecord] = []
    /// The composition style being explained after a press and hold, shown for a few seconds.
    @State private var compositionExplanation: CompositionGuide?
    /// Briefly blacks out the screen when a photo is taken, like the Camera app.
    @State private var isShutterBlinking = false
    /// The advice card is pushed down out of the way, leaving a small pill to pull it back up. Remembered between launches.
    @AppStorage("isAdviceCollapsed") private var isAdviceCollapsed = false
    /// The advice card also shows the idea behind the advice. Tapping the card toggles through prompt, explanation, then back to the pill.
    @State private var isAdviceExplained = false
    /// How far the advice card is being dragged, while the finger is down.
    @State private var adviceDragOffset: CGFloat = 0
    /// The zoom when the current pinch began, so the pinch scales from there.
    @State private var pinchStartZoom: CGFloat?
    /// The first-launch tour only runs until it's finished or skipped once.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// The tour stop being shown, or nil when the tour isn't running.
    @State private var onboardingStep: OnboardingStep?
    /// How the person is doing on the current tour stop.
    @State private var onboardingFeedback: OnboardingFeedback?
    /// On the topic stop, the mode the tour asks for next. Nil once every mode has been tried,
    /// when the tour asks to go back to Composition.
    @State private var tourNextTopic: AdviceTopic? = AdviceTopic.allCases.dropFirst().first
    /// On the composition stop, whether the person has scrolled the row and picked a style yet.
    @State private var tourScrolledStyles = false
    @State private var tourPickedStyle = false

    private func showOnboarding(_ step: OnboardingStep) {
        onboardingStep = step
        onboardingFeedback = nil
        tourScrolledStyles = false
        tourPickedStyle = false
        // A style explanation left over from the press-and-hold stop would sit over the next stop's spotlight.
        compositionExplanation = nil
    }

    /// The header inside the open topic menu while the tour is on that stop, since the menu covers the tour card.
    private var topicMenuPrompt: String? {
        guard onboardingStep == .topicMenu else { return nil }
        if let next = tourNextTopic {
            return "Each mode coaches a different skill. Select \(next.displayTitle) next."
        }
        return "That's every mode. Go back to Composition."
    }

    /// Moves to the next tour stop whose control is on screen, or ends the tour after the last one.
    private func continueOnboarding(from step: OnboardingStep, available: Set<OnboardingStep>) {
        if let next = OnboardingStep.allCases.first(where: {
            $0.rawValue > step.rawValue && !$0.isFollowOn && available.contains($0)
        }) {
            showOnboarding(next)
        } else {
            finishOnboarding()
        }
    }

    private func finishOnboarding() {
        onboardingStep = nil
        onboardingFeedback = nil
        hasCompletedOnboarding = true
    }

    /// Shows feedback, but only while the tour is on `step`.
    private func noteOnboarding(_ step: OnboardingStep, _ text: String, isComplete: Bool) {
        guard onboardingStep == step else { return }
        onboardingFeedback = OnboardingFeedback(text: text, isComplete: isComplete)
    }

    /// The tour walks through every mode in menu order, then asks to go back to Composition.
    /// Whichever topic is picked gets explained.
    private func noteTopicPicked(_ topic: AdviceTopic) {
        guard onboardingStep == .topicMenu else { return }
        let explained = "\(topic.displayTitle): \(topic.tourDescription)"
        guard let next = tourNextTopic else {
            if topic == .composition {
                noteOnboarding(.topicMenu, "Back to Composition. \(topic.tourDescription)", isComplete: true)
            } else {
                noteOnboarding(.topicMenu, "\(explained) Now open the menu and go back to Composition.", isComplete: false)
            }
            return
        }
        guard topic == next else {
            noteOnboarding(.topicMenu, "\(explained) For this tour, open the menu and select \(next.displayTitle).", isComplete: false)
            return
        }
        let modes = AdviceTopic.allCases
        let after = modes.firstIndex(of: topic).map { modes.index(after: $0) }
        tourNextTopic = after.flatMap { $0 < modes.endIndex ? modes[$0] : nil }
        if let upcoming = tourNextTopic {
            noteOnboarding(.topicMenu, "\(explained) Open the menu again and select \(upcoming.displayTitle).", isComplete: false)
        } else {
            noteOnboarding(.topicMenu, "\(explained) That's every mode. Open the menu once more and go back to Composition.", isComplete: false)
        }
    }

    /// Opening the controls panel moves the tour on to picking buttons; closing it finishes that stop.
    private func noteControlsEditingChanged() {
        if controls.isEditing {
            if onboardingStep == .photoControls {
                showOnboarding(.editControls)
            }
        } else {
            let names = controls.pinned.map(\.title)
            let text = names.isEmpty
                ? "Your bar is empty now. Press and hold the top right corner anytime to add buttons back."
                : "Your bar shows \(names.formatted(.list(type: .and))). Press and hold it anytime to change them."
            noteOnboarding(.editControls, text, isComplete: true)
        }
    }

    /// Says what each tap in the controls panel did.
    private func noteDraftChanged(from old: [PhotoControl], to new: [PhotoControl]) {
        // Opening and closing the panel also change the draft; only the person's own edits count.
        guard controls.isEditing, !old.isEmpty || new != controls.pinned else { return }
        if let added = new.first(where: { !old.contains($0) }) {
            noteOnboarding(.editControls, "Added \(added.title). It \(added.tourDescription). Tap ✓ to keep it.", isComplete: false)
        } else if let removed = old.first(where: { !new.contains($0) }) {
            noteOnboarding(.editControls, "Removed \(removed.title). Tap ✓ to keep the change.", isComplete: false)
        } else if old != new {
            noteOnboarding(.editControls, "Moved them around. Tap ✓ to keep this order.", isComplete: false)
        }
    }

    /// Explains the composition style that was just picked.
    private func noteCompositionChanged(from old: String, to new: String) {
        let before = Set(old.split(separator: ",").compactMap { CompositionGuide(rawValue: String($0)) })
        let after = Set(new.split(separator: ",").compactMap { CompositionGuide(rawValue: String($0)) })
        // The stop is done once the row has been scrolled and a style picked, in either order.
        let next = tourScrolledStyles
            ? "Tap another to combine styles. The ✨ icon marks the coach's recommendation for this scene."
            : "Now scroll the row to see the other styles."
        if let added = CompositionGuide.allCases.first(where: { after.contains($0) && !before.contains($0) }) {
            tourPickedStyle = true
            noteOnboarding(.compositionRow, "\(added.title.keptTogether): \(added.tourDescription) The grid on screen shows you how. \(next)", isComplete: tourScrolledStyles)
        } else if let removed = CompositionGuide.allCases.first(where: { before.contains($0) && !after.contains($0) }) {
            tourPickedStyle = true
            noteOnboarding(.compositionRow, "Turned off \(removed.title.keptTogether). You can practise a few styles at once. \(next)", isComplete: tourScrolledStyles)
        }
    }

    private func noteCompositionScrolled() {
        guard onboardingStep == .compositionRow, !tourScrolledStyles else { return }
        tourScrolledStyles = true
        let text = tourPickedStyle
            ? "That's all \(CompositionGuide.allCases.count) styles. You can select more than one, and the ✨ icon marks the coach's recommendation for this scene."
            : "That's all \(CompositionGuide.allCases.count) styles. Now tap one to practise it. You can select more than one, and the ✨ icon marks the coach's recommendation."
        noteOnboarding(.compositionRow, text, isComplete: tourPickedStyle)
    }

    private func noteZoomChanged() {
        let level = Double(camera.zoomLevel).formatted(.number.precision(.fractionLength(0...1)))
        noteOnboarding(.compositionRow, "Zoomed to \(level)×. Zooming changes how much of the scene fits in the frame. Now try tapping a style.", isComplete: false)
    }

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

    /// The third lines the advice on screen names, lit up on the grid while the advice is showing.
    private var highlightedThirdsLines: Set<ThirdsLine> {
        guard !isWaitingForObject, !isAdviceCollapsed, coach.notice == nil else { return [] }
        return coach.feedback?.thirdsLines ?? []
    }

    /// The target guide only appears for topics and styles about where the subject sits.
    private var showsSubjectBox: Bool {
        subjectPlacement != nil
    }

    /// Where the target guide puts the subject for the chosen topic and style, if it has a box at all.
    private var subjectPlacement: SubjectPlacement? {
        adviceTopic == .composition ? CompositionGuide.guidePlacement(for: compositionGuides) : nil
    }

    /// Topics whose advice is about one subject, so they wait for the person to double-tap it.
    private var needsObject: Bool {
        [.composition, .focus].contains(adviceTopic)
    }

    /// The advice is about a subject that hasn't been chosen yet.
    private var isWaitingForObject: Bool {
        needsObject && objectSelection.object == nil
    }

    /// How far the advice has to be dragged before it collapses or expands.
    private let adviceDragThreshold: CGFloat = 50

    /// The coach's advice, which can be pushed down into a small pill and pulled back up.
    @ViewBuilder
    private var adviceArea: some View {
        if coach.notice != nil || coach.feedback != nil || isWaitingForObject {
            if isAdviceCollapsed {
                collapsedAdvicePill
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                coachCard
                    // Follows the finger down; resists being pulled up.
                    .offset(y: adviceDragOffset > 0 ? adviceDragOffset : adviceDragOffset / 4)
                    .opacity(1 - min(max(adviceDragOffset, 0) / 200, 0.6))
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                adviceDragOffset = value.translation.height
                            }
                            .onEnded { value in
                                withAnimation(.snappy) {
                                    if value.translation.height > adviceDragThreshold
                                        || value.predictedEndTranslation.height > adviceDragThreshold * 3 {
                                        isAdviceCollapsed = true
                                        isAdviceExplained = false
                                    }
                                    adviceDragOffset = 0
                                }
                            }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture(perform: advanceAdvice)
                    .accessibilityAction(named: hasAdviceExplanation && !isAdviceExplained ? "Explain advice" : "Hide advice") {
                        advanceAdvice()
                    }
            }
        }
    }

    /// Whether the current advice has an explanation to reveal.
    private var hasAdviceExplanation: Bool {
        guard coach.notice == nil, !isWaitingForObject, let feedback = coach.feedback else { return false }
        return !feedback.isGoodEnough && feedback.why != nil
    }

    /// A tap on the card first reveals the explanation, then pushes the card back down into the pill.
    /// Advice without an explanation goes straight back to the pill.
    private func advanceAdvice() {
        withAnimation(.snappy) {
            if hasAdviceExplanation && !isAdviceExplained {
                isAdviceExplained = true
            } else {
                isAdviceCollapsed = true
                isAdviceExplained = false
            }
        }
    }

    /// What's left of the advice once it's pushed down. Tap it or swipe it up to bring the card back.
    private var collapsedAdvicePill: some View {
        let isGoodEnough = coach.feedback?.isGoodEnough == true
        return Button {
            withAnimation(.snappy) {
                isAdviceCollapsed = false
                isAdviceExplained = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isGoodEnough ? "checkmark.circle.fill" : "lightbulb.fill")
                    .foregroundStyle(isGoodEnough ? .green : .yellow)
                Text("Advice")
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -adviceDragThreshold / 2
                        || value.predictedEndTranslation.height < -adviceDragThreshold {
                        withAnimation(.snappy) {
                            isAdviceCollapsed = false
                            isAdviceExplained = false
                        }
                    }
                }
        )
        .accessibilityLabel("Show advice")
        .accessibilityValue(isGoodEnough ? "Looks good, take it" : "")
    }

    /// The auto-rendering coach's latest feedback, or a notice when it can't run.
    @ViewBuilder
    private var coachCard: some View {
        VStack(spacing: 8) {
            // Grab handle, hinting that the card can be pushed down.
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            if adviceTopic == .composition, let nudge = coach.lightNudge {
                lightNudgeBanner(nudge)
            }
            if let notice = coach.notice {
                CoachTipView(text: notice)
            } else if isWaitingForObject {
                // Advice about the subject needs the person to pick it first.
                CoachTipView(text: selectObjectPrompt)
            } else if let feedback = coach.feedback {
                if let object = objectSelection.object {
                    selectedObjectHeader(object)
                } else {
                    // Optional for this topic, but it still tailors the advice.
                    Label("Tip: double-tap an object for advice about it.", systemImage: "hand.tap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                CoachFeedbackView(
                    feedback: feedback,
                    showsExplanation: isAdviceExplained,
                    canApply: camera.canApply,
                    onQuickFix: applyQuickFix,
                    onNextMode: { adviceTopic = $0 }
                )
            } else {
                // The first look takes a moment; say so rather than showing an empty space.
                CoachTipView(text: "Looking at your shot…")
            }
        }
    }

    /// Room at each end of the advice card when the phone is held sideways. The card runs along
    /// the screen's long side, so one end points at the bottom of the phone, where the zoom row,
    /// composition styles and shutter are: that end stops short of them. Turned clockwise, the
    /// card's trailing end is at the bottom of the phone; turned the other way, its leading end.
    private var sidewaysAdviceInsets: EdgeInsets {
        let clear = max(40, bottomControlsHeight + 12)
        return camera.holdOrientation == .landscapeLeft
            ? EdgeInsets(top: 0, leading: 40, bottom: 0, trailing: clear)
            : EdgeInsets(top: 0, leading: clear, bottom: 0, trailing: 40)
    }

    /// Shown over the black viewfinder when camera access is off.
    private var cameraAccessMessage: some View {
        ContentUnavailableView {
            Label("Camera access is off", systemImage: "camera.fill")
        } description: {
            Text(camera.cameraAccess == .restricted
                 ? "Camera access is restricted on this iPhone."
                 : "Allow camera access to take photos and get coaching.")
        } actions: {
            if camera.cameraAccess == .denied {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
    }

    /// A problem that stays until it's read, with a way to fix it in Settings when that's where the fix is.
    private func problemBanner(_ problem: CameraProblem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(problem.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if problem.opensSettings {
                Button("Settings", action: openSettings)
                    .font(.subheadline.bold())
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
            Button {
                camera.clearProblem()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: 360)
        .glassEffect(.regular.tint(.black.opacity(0.5)), in: .rect(cornerRadius: 18))
        .rotationEffect(camera.holdOrientation.uiRotation)
        .transition(.opacity)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private var selectObjectPrompt: String {
        if objectSelection.isFinding {
            return "Finding what you double-tapped…"
        }
        if objectSelection.isLost {
            return "Lost sight of it. Double-tap the object again to keep getting advice about it."
        }
        return "Select an object: double-tap what you want to photograph to get advice about it."
    }

    /// Says what the advice is about, with a button to choose something else.
    private func selectedObjectHeader(_ object: SelectedObject) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .foregroundStyle(.yellow)
            Text(object.name == "person" ? "Advice for your subject" : "Advice for the \(object.name)")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) {
                    objectSelection.clear(camera: camera)
                    isAdviceExplained = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a different object")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
    }

    /// Composition's camera-move arrow, or Light & Exposure's amber guide: who moves, which way,
    /// and where the light is.
    @ViewBuilder
    private var guidanceOverlays: some View {
        if !isWaitingForObject, coach.notice == nil {
            if let move = coach.feedback?.move {
                UprightOverlay(orientation: camera.holdOrientation) {
                    CameraMoveArrow(move: move)
                }
            } else if adviceTopic == .light, !isAdviceCollapsed, let feedback = coach.feedback, !feedback.isGoodEnough {
                UprightOverlay(orientation: camera.holdOrientation) {
                    LightGuideOverlay(feedback: feedback)
                }
                .transition(.opacity)
            }
        }
    }

    /// "Light first", with a way to go and fix it, shown once when framing a shot with bad light.
    private func lightNudgeBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "sun.max.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            HStack {
                Button("Fix the light first", systemImage: AdviceTopic.light.systemImage) {
                    coach.dismissLightNudge()
                    adviceTopic = .light
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.lightGuide)
                .foregroundStyle(.black)
                Button("Not now") {
                    coach.dismissLightNudge()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lightGuide.opacity(0.18), in: .rect(cornerRadius: 16))
    }

    /// Follows a tip's fix in one tap. Setting brightness for the subject meters on where it is.
    private func applyQuickFix(_ fix: QuickFix) {
        var point: CGPoint?
        if fix == .meterOnSubject, let box = coach.feedback?.subjectBox {
            point = camera.frameGrabber.sensorPoint(forUpright: CGPoint(x: box.midX, y: box.midY))
        }
        statusMessage = camera.apply(fix, subjectPoint: point)
    }

    /// Focuses and meters where a single tap landed. `location` and `size` are in the upright view.
    /// Returns false when the tap missed the frame, so no focus square is shown.
    private func focus(at location: CGPoint, in size: CGSize) -> Bool {
        guard let aspect = camera.frameGrabber.uprightAspect() else { return false }
        let point = FrameMapping.framePoint(for: location, frameAspect: aspect, in: size)
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
        camera.focusAndExpose(at: camera.frameGrabber.sensorPoint(forUpright: point))
        return true
    }

    /// Picks the object under a double tap on the viewfinder. `location` and `size` are in the upright view.
    private func selectObject(at location: CGPoint, in size: CGSize) {
        guard let aspect = camera.frameGrabber.uprightAspect() else { return }
        let point = FrameMapping.framePoint(for: location, frameAspect: aspect, in: size)
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        objectSelection.select(at: point, camera: camera)
        // Bring the advice back out, so the person sees it's now about what they tapped.
        withAnimation(.snappy) {
            isAdviceCollapsed = false
            isAdviceExplained = false
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
                // Blurs over the swap between front and back, like the Camera app, so the
                // last frame of one camera doesn't jump straight to the other.
                .overlay {
                    CameraSwitchBlur(isSwitching: camera.isSwitchingCamera)
                }
                // The tour spotlights the whole viewfinder, so the tap reaches the object.
                .onboardingAnchor(.selectObject)
                // Grids help line the scene up while composing.
                .overlay {
                    if adviceTopic == .composition {
                        UprightOverlay(orientation: camera.holdOrientation) {
                            CompositionGrid(styles: compositionGuides, highlightedLines: highlightedThirdsLines)
                        }
                    }
                }
                // A level in the middle of the frame while practising angle and perspective.
                .overlay {
                    if adviceTopic == .anglePerspective {
                        CameraLevel(attitude: coach.attitude)
                    }
                }
                // The dot and circle show which way to move the phone to place the subject.
                .overlay {
                    if showsSubjectBox, !isWaitingForObject, let target = subjectGuide.target {
                        UprightOverlay(orientation: camera.holdOrientation) {
                            SubjectTargetOverlay(target: target, frameAspect: subjectGuide.frameAspect)
                        }
                    }
                }
                // The tour spotlights the viewfinder for lining up, but only for styles that have a dot and circle.
                .overlay {
                    if showsSubjectBox {
                        Color.clear
                            .allowsHitTesting(false)
                            .onboardingAnchor(.alignSubject)
                    }
                }
                // Tap to focus and set the brightness, like the Camera app. Double-tap anything to
                // get advice about it, and see it outlined while it's followed.
                .overlay {
                    UprightOverlay(orientation: camera.holdOrientation) {
                        ViewfinderTapLayer(camera: camera, onFocus: focus, onSelect: selectObject)
                    }
                }
                .overlay {
                    if let object = objectSelection.object {
                        UprightOverlay(orientation: camera.holdOrientation) {
                            SelectedObjectOverlay(object: object)
                        }
                    }
                }
                // Outlines what the advice names, like "the lamp post", so it's clear what it means.
                .overlay {
                    if !isWaitingForObject, !isAdviceCollapsed, coach.notice == nil, let highlight = coach.feedback?.highlight {
                        UprightOverlay(orientation: camera.holdOrientation) {
                            CoachHighlightOverlay(highlight: highlight)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut, value: coach.feedback?.highlight)
                // Arrows for what the advice asks: Composition's white camera move, Light's amber who-moves guide.
                .overlay { guidanceOverlays }
                .animation(.snappy, value: coach.feedback?.move)
                // Without camera access the viewfinder is black, so explain why and how to fix it.
                .overlay {
                    if camera.cameraAccess == .denied || camera.cameraAccess == .restricted {
                        cameraAccessMessage
                            .rotationEffect(camera.holdOrientation.uiRotation)
                    }
                }
                // Held sideways, the advice reads along the long side, at the bottom as the person sees it.
                .overlay {
                    if camera.holdOrientation.isLandscape, !controls.isEditing {
                        UprightOverlay(orientation: camera.holdOrientation) {
                            VStack {
                                Spacer()
                                adviceArea
                                    .onboardingAnchor(.advice)
                            }
                            .padding(sidewaysAdviceInsets)
                            .padding(.bottom, 16)
                        }
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
                    AdviceTopicMenu(
                        selection: $adviceTopic,
                        iconRotation: camera.holdOrientation.uiRotation,
                        onSelect: { noteTopicPicked($0) },
                        prompt: topicMenuPrompt
                    )
                        .equatable()
                        .opacity(controls.isEditing ? 0 : 1)
                        .disabled(controls.isEditing)
                        .accessibilityHidden(controls.isEditing)
                        .onboardingAnchor(.topicMenu)
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
                        .rotationEffect(camera.holdOrientation.uiRotation)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // Something the person needs to fix, like Photos access. It stays longer than the
                // confirmation banner, and links to Settings when that's where the fix is.
                if let problem = camera.problem {
                    problemBanner(problem)
                }

                // What a composition style means, after pressing and holding its card.
                if let compositionExplanation {
                    VStack(spacing: 4) {
                        Text(compositionExplanation.title.keptTogether)
                            .font(.subheadline.bold())
                        Text(compositionExplanation.explanation)
                            .font(.subheadline)
                        if compositionExplanation.needsAppleIntelligence, !SystemLanguageModel.default.isAvailable {
                            Text(CompositionGuide.withoutAppleIntelligenceNote)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320)
                    // Room on the sides so the text never runs under the close button.
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 18))
                    // Only the close button takes touches; the rest lets taps through to the viewfinder.
                    .allowsHitTesting(false)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            self.compositionExplanation = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 32, height: 32)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close explanation")
                    }
                    .rotationEffect(camera.holdOrientation.uiRotation)
                    // Lit up too while the tour is on this stop, so the explanation isn't dimmed.
                    .onboardingAnchor(.explainStyle)
                    .transition(.opacity)
                    .id(compositionExplanation)
                }

                Spacer()

                if controls.isEditing {
                    PhotoControlsSheet(model: controls)
                        .onboardingAnchor(.editControls)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 10) {
                        // Zoom and composition styles share one row to keep more of the viewfinder clear.
                        HStack(spacing: 8) {
                            ZoomPicker(stops: camera.zoomStops, level: camera.zoomLevel, labelRotation: camera.holdOrientation.uiRotation) { level in
                                // A tap on a lens button glides there, like the Camera app.
                                if let message = camera.setZoom(level, smoothly: true) {
                                    statusMessage = message
                                }
                            }

                            // Composition styles, only while the Composition topic is chosen.
                            if adviceTopic == .composition {
                                CompositionPicker(
                                    selection: Binding(get: { compositionGuides }, set: { setCompositionGuides($0) }),
                                    unavailable: coach.unavailableCompositions,
                                    recommended: coach.recommendedComposition,
                                    onMessage: { statusMessage = $0 },
                                    onExplain: { compositionExplanation = $0 },
                                    onScroll: noteCompositionScrolled,
                                    chipRotation: camera.holdOrientation.uiRotation
                                )
                                    // Undo the picker's leading bleed so chips don't scroll under the zoom buttons.
                                    .padding(.leading, 16)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .onboardingAnchor(.compositionRow, .explainStyle)
                        // Full width, so the coach card gets room even when only the zoom buttons are showing.
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            // Floats above the controls, so a longer card never pushes them around.
                            // Held sideways, the advice moves onto the viewfinder instead.
                            Group {
                                if !camera.holdOrientation.isLandscape {
                                    adviceArea
                                        .onboardingAnchor(.advice)
                                }
                            }
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        bottomControlsHeight = height
                    }
                }
            }
            .padding(.horizontal)
            // Run into the home-indicator area so the shutter row sits low, like the Camera app.
            .ignoresSafeArea(.container, edges: .bottom)
            // Get out of the way while a Camera Control slider fills the screen.
            .opacity(camera.isCameraControlFullscreen ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: camera.isCameraControlFullscreen)

            // Self-timer countdown.
            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 120, weight: .thin))
                    .foregroundStyle(.white)
                    // Keeps the thin numerals readable against bright scenes.
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .contentTransition(.numericText(countsDown: true))
                    .rotationEffect(camera.holdOrientation.uiRotation)
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(countdown) seconds")
            }

            Color.black
                .ignoresSafeArea()
                .opacity(isShutterBlinking ? 1 : 0)
                .allowsHitTesting(false)
        }
        // The first-launch tour, spotlighting the controls for one step at a time.
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            if let step = onboardingStep, let stepAnchors = anchors[step], !stepAnchors.isEmpty {
                // Numbered stops are the ones on screen now, plus any already passed.
                let stops = OnboardingStep.allCases.filter {
                    !$0.isFollowOn && ($0.rawValue <= step.rawValue || anchors[$0] != nil)
                }
                let numberedStep = step.isFollowOn ? OnboardingStep.photoControls : step
                let rowAnchor = step.placesCardOnControls ? anchors[.compositionRow]?.first : nil
                GeometryReader { proxy in
                    let spots = stepAnchors.map { proxy[$0] }
                    // Covers the composition row, with the bottom of the viewfinder above it,
                    // or sits just inside the bottom of the controls panel while it's open.
                    // Once ✓ closes the panel, only the bar is lit, so the card goes back beside it.
                    let cardBottom = rowAnchor.map { proxy[$0].maxY }
                        ?? (step.placesCardInPanel && controls.isEditing ? spots.map(\.maxY).max().map { $0 - 12 } : nil)
                    OnboardingOverlay(
                        step: step,
                        spots: spots,
                        canvas: proxy.size,
                        stepNumber: (stops.firstIndex(of: numberedStep) ?? 0) + 1,
                        stepCount: stops.count,
                        feedback: onboardingFeedback,
                        cardBottom: cardBottom,
                        onContinue: { continueOnboarding(from: step, available: Set(anchors.keys)) },
                        onSkip: finishOnboarding
                    )
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .onAppear {
            guard !hasCompletedOnboarding else { return }
            // Make sure the advice card is out, so the tour can point at it.
            isAdviceCollapsed = false
            // The walk through the modes starts from Composition, the first one.
            adviceTopic = .composition
            tourNextTopic = AdviceTopic.allCases.dropFirst().first
            showOnboarding(.topicMenu)
        }
        .task {
            await camera.start()
        }
        .task {
            await objectSelection.run(camera: camera)
        }
        // Clicking the Camera Control (or a volume button) takes a photo, like the Camera app.
        // It fires on release, so a light press to open the overlay doesn't take one.
        .onCameraCaptureEvent(isEnabled: !isGalleryPresented && !controls.isEditing && (onboardingStep == nil || onboardingStep == .shutter)) { event in
            guard event.phase == .ended else { return }
            Task {
                if let message = await camera.shutterTapped() {
                    statusMessage = message
                }
            }
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
            let record = pendingShots.isEmpty ? nil : pendingShots.removeFirst()
            Task { await gallery.add(identifier, record: record) }
        }
        // A shot that never reached the library takes its story with it, so the next photo gets its own.
        .onChange(of: camera.unsavedCaptureCount) {
            if !pendingShots.isEmpty { pendingShots.removeFirst() }
        }
        .fullScreenCover(isPresented: $isGalleryPresented) {
            GalleryView(gallery: gallery)
        }
        .task(id: camera.problem) {
            guard camera.problem != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            camera.clearProblem()
        }
        // Coming back to the app: make sure the camera is running again.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                camera.resumeIfNeeded()
            }
        }
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            statusMessage = nil
        }
        // Long enough to read a full sentence. Holding another card restarts the timer.
        .task(id: compositionExplanation) {
            guard compositionExplanation != nil else { return }
            try? await Task.sleep(for: .seconds(10))
            compositionExplanation = nil
        }
        .onChange(of: controls.isEditing) {
            if controls.isEditing {
                activeAdjustment = nil
            }
        }
        // Swap the top bar to the controls that matter for the chosen topic.
        .onChange(of: adviceTopic, initial: true) {
            controls.setTopic(adviceTopic)
            if adviceTopic != .composition {
                compositionExplanation = nil
            }
            if let activeAdjustment, !controls.pinned.contains(activeAdjustment) {
                self.activeAdjustment = nil
            }
        }        .onChange(of: camera.shutterCount) {
            // Keep what the coach knew for the photo's story, before the section it describes ends.
            pendingShots.append(coach.shotRecord(topic: adviceTopic, styles: compositionGuides))
            // Taking the photo finishes the coach's current section.
            coach.noteShutter()
            isShutterBlinking = true
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.2)) {
                    isShutterBlinking = false
                }
            }
            noteOnboarding(.shutter, "Nice shot! It's saved. Tap the thumbnail at the bottom left to see your photos.", isComplete: true)
        }
        // The tour watches what the person does and tells them what it did.
        .onChange(of: controls.isEditing) { noteControlsEditingChanged() }
        .onChange(of: controls.draft) { old, new in noteDraftChanged(from: old, to: new) }
        .onChange(of: compositionGuidesRaw) { old, new in noteCompositionChanged(from: old, to: new) }
        .onChange(of: camera.zoomLevel) { noteZoomChanged() }
        .onChange(of: objectSelection.object?.name) {
            guard let name = objectSelection.object?.name else { return }
            let subject = name == "person" ? "your subject" : "the \(name)"
            noteOnboarding(.selectObject, "Got it: \(subject). The outline follows it, and the advice is now about it.", isComplete: true)
        }
        .onChange(of: compositionExplanation) {
            guard let guide = compositionExplanation else { return }
            noteOnboarding(.explainStyle, "\(guide.title.keptTogether): \(guide.tourDescription) Hold another card to compare, or tap Continue.", isComplete: true)
        }
        .onChange(of: subjectGuide.target?.isAligned) {
            guard onboardingStep == .alignSubject, let target = subjectGuide.target else { return }
            if target.isAligned {
                noteOnboarding(.alignSubject, "Lined up! The frame turns green and you'll feel a tick when your subject is in place.", isComplete: true)
            } else if onboardingFeedback?.isComplete == true {
                // Drifting off after lining up keeps the step done, but says how to get back.
                noteOnboarding(.alignSubject, "You drifted off. Follow the arrows to bring the dot back into the circle.", isComplete: true)
            }
        }
        .onChange(of: isAdviceExplained) {
            guard isAdviceExplained else { return }
            // Not done yet: the tour wants the second tap too, which tucks the card away.
            noteOnboarding(.advice, "That's the idea behind the tip. Now tap the card again to tuck it away.", isComplete: false)
        }
        .onChange(of: isAdviceCollapsed) {
            guard isAdviceCollapsed else { return }
            noteOnboarding(.advice, "Tucked away. Tap the Advice pill to bring the coach back anytime.", isComplete: true)
        }
        .animation(.spring, value: controls.isEditing)
        .animation(.snappy, value: controls.draft)
        .animation(.snappy, value: activeAdjustment)
        .animation(.snappy, value: adviceTopic)
        .animation(.easeInOut, value: statusMessage)
        .animation(.easeInOut, value: camera.problem)
        .animation(.easeInOut, value: coach.notice)
        .animation(.easeInOut, value: compositionExplanation)
        .animation(.easeInOut, value: coach.feedback)
        .animation(.snappy, value: isAdviceCollapsed)
        .animation(.snappy, value: onboardingStep)
        .sensoryFeedback(.selection, trigger: onboardingStep)
        .sensoryFeedback(.success, trigger: coach.isReady) { _, isReady in isReady }
        // A tick as the dot reaches the circle, so lining up doesn't need watching the arrows.
        .sensoryFeedback(.alignment, trigger: subjectGuide.target?.isAligned) { _, isAligned in isAligned == true }
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

// MARK: - Apple Intelligence alert

/// Tells people once, in an alert, when Apple Intelligence can't help on this iPhone, so they know
/// Composition advice may not be as good before they rely on it. Waits until the tour is done so
/// it doesn't cover it, and alerts again only if the reason changes.
private struct AppleIntelligenceAlert: ViewModifier {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// The reason last alerted about, so the same one isn't repeated on every launch.
    @AppStorage("appleIntelligenceAlertShown") private var shownReason = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var alert: (key: String, title: String, message: String)?

    func body(content: Content) -> some View {
        content
            .alert(
                alert?.title ?? "",
                isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(alert?.message ?? "")
            }
            .onChange(of: hasCompletedOnboarding, initial: true) { check() }
            // Apple Intelligence can be switched off, or finish downloading, while the app is away.
            .onChange(of: scenePhase) { if scenePhase == .active { check() } }
    }

    private func check() {
        guard let found = CoachRules.modelAlert(for: SystemLanguageModel.default.availability) else {
            // It's working now, so a later problem is worth an alert again.
            shownReason = ""
            return
        }
        guard hasCompletedOnboarding, alert == nil, found.key != shownReason else { return }
        shownReason = found.key
        alert = found
    }
}

extension View {
    /// Alerts once when Apple Intelligence isn't available, saying what that means for the advice.
    func appleIntelligenceAlert() -> some View {
        modifier(AppleIntelligenceAlert())
    }
}
