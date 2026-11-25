//
//  OnboardingTour.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// The stops on the first-launch tour, in order. Each one spotlights a real control
/// and asks the person to use it; the tour moves on once they have.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case topicMenu
    case photoControls
    /// Follows on from `photoControls` once the panel is open, so it shares its number.
    case editControls
    case compositionRow
    case explainStyle
    /// A single tap sets focus and brightness, then a drag changes it. Taught just before the
    /// double tap that picks the subject, so the two are told apart.
    case brightness
    case selectObject
    case advice
    /// Comes after `selectObject`, since the dot and circle only show once there's a subject.
    case alignSubject
    case shutter

    var id: Int { rawValue }

    /// Steps that continue the one before rather than counting as a stop of their own.
    var isFollowOn: Bool { self == .editControls }

    /// Steps that spotlight nearly the whole viewfinder, leaving no room for the card beside it.
    /// Their card sits on the composition row instead, over the bottom of the viewfinder.
    var placesCardOnControls: Bool { self == .brightness || self == .selectObject || self == .alignSubject }

    /// Steps whose lowest spotlight is a tall panel with no room beside it.
    /// Their card sits inside the bottom of that panel, leaving its top and the bar above it clear.
    var placesCardInPanel: Bool { self == .editControls }

    var title: String {
        switch self {
        case .topicMenu: "Choose what to learn"
        case .photoControls: "Your camera buttons"
        case .editControls: "Pick your buttons"
        case .compositionRow: "Composition styles"
        case .explainStyle: "Learn a style"
        case .brightness: "Set the brightness"
        case .selectObject: "Pick your subject"
        case .alignSubject: "Line it up"
        case .advice: "Your coach"
        case .shutter: "Take your first shot"
        }
    }

    /// What the person is asked to do.
    var instruction: String {
        switch self {
        case .topicMenu:
            "This menu sets what the coach teaches you. Tap it to see the modes, and try each one in turn. They're numbered in shooting order: start with the light, then frame the shot."
        case .photoControls:
            "These are quick camera settings. Press and hold them to choose which ones show."
        case .editControls:
            "Tap a control below to add it to the bar, or tap − on one in the bar to remove it. The bar holds up to 3. Tap ✓ when you're done."
        case .compositionRow:
            "Each card is a way to frame your photo. Scroll the row to see them all, then tap one to practise it. You can select more than one. The ✨ icon marks the style the coach recommends for this scene."
        case .explainStyle:
            "Press and hold any card to see what the style means."
        case .brightness:
            "Tap anything to set focus and brightness there. Then drag up or down to make the photo brighter or darker."
        case .selectObject:
            "Now double-tap the thing you want to photograph. The coach will follow it and give advice about it."
        case .alignSubject:
            "The dot is where your phone points, and the circle is where it should point. Move the phone until the dot is inside the circle."
        case .advice:
            "The coach gives live tips as you frame. Tap the card once to see why it's suggesting this, then tap again to tuck it away."
        case .shutter:
            "The ring fills from yellow to green as your shot gets ready. Tap the shutter to take a photo."
        }
    }
}

/// How the person did on the current step.
struct OnboardingFeedback: Equatable {
    var text: String
    /// The step's goal is met, so the tour can move on.
    var isComplete: Bool
    /// A small picture shown with the text, for things the tour can't count on seeing for real.
    var preview: TourPreview? = nil
}

/// Pictures the tour can show with its feedback.
nonisolated enum TourPreview: Equatable {
    /// Light & Exposure's signals: who moves, the amber arrow, and a one-tap fix button.
    case lightSignals
}

/// A sample of Light & Exposure's signals, in their real colours. Light tips only appear when
/// the light needs fixing, which it may not during the tour, so this shows what to look for.
struct LightSignalsPreview: View {
    private var chips: some View {
        ForEach([Mover.photographer, .subject, .settings], id: \.self) { mover in
            Label(mover.label, systemImage: mover.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.lightGuide, in: .capsule)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // In a row when they fit, stacked at larger text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips }
                VStack(alignment: .leading, spacing: 6) { chips }
            }
            HStack(spacing: 10) {
                // A tiny "walk around the subject" arrow.
                ZStack {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Circle()
                        .trim(from: 0.25, to: 0.5)
                        .stroke(Color.lightGuide, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 30, height: 30)
                    Image(systemName: "sun.max.fill")
                        .font(.caption)
                        .foregroundStyle(Color.lightGuide)
                        .offset(x: -20, y: -12)
                }
                .frame(width: 44, height: 36)
                Label(QuickFix.nightMode.title, systemImage: QuickFix.nightMode.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.lightGuide, in: .capsule)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light tips say You move, Subject moves or Settings, show amber arrows, and can have a button that does the fix for you.")
    }
}

// MARK: - Explanations shown as feedback

extension AdviceTopic {
    /// What picking this topic does, in a sentence.
    var tourDescription: String {
        switch self {
        case .composition: "Pick a style, then move the phone until the dot is in the circle."
        case .focus: "A level helps you hold the camera straight, and the coach helps keep your subject sharp."
        case .light: "The coach helps you find good light and get the brightness right."
        }
    }
}

extension PhotoControl {
    /// What the control does, finishing the sentence "It …".
    var tourDescription: String {
        switch self {
        case .flash: "lights up dark scenes"
        case .live: "records a moment of movement around the photo"
        case .aspect: "changes the shape of the photo"
        case .timer: "gives you a few seconds before the photo is taken"
        case .exposure: "makes the photo brighter or darker"
        case .styles: "changes the look and colour of the photo"
        case .depth: "blurs the background behind your subject when you take the photo"
        case .nightMode: "brightens shots in low light"
        case .centerStage: "keeps you in frame on the front camera"
        case .format: "switches the file format the photo is saved in"
        case .focus: "lets you set the focus by hand"
        case .shutterSpeed: "controls how much movement blurs"
        case .whiteBalance: "makes colours warmer or cooler"
        case .histogram: "shows how bright the scene is"
        case .lensAperture: "changes how much of the scene is in focus"
        }
    }
}

extension CompositionGuide {
    /// The idea behind the style, in a sentence.
    var tourDescription: String {
        switch self {
        case .ruleOfThirdsOne: "Put your subject on a third line instead of dead centre."
        case .ruleOfThirdsTwo: "Let your subject fill two thirds of the frame."
        case .ruleOfThirdsCorner: "Place your subject where two third lines cross."
        case .centre: "Put your subject right in the middle for a bold, simple shot."
        case .onePointPerspective: "Line up so everything runs towards one point in the distance."
        case .tableTop45: "Shoot food or objects from a 45° angle."
        case .tableTop90: "Shoot straight down from above."
        case .leadingLines: "Use lines in the scene to lead the eye to your subject."
        case .triangle: "Arrange things in a triangle for a balanced shot."
        case .leadingLinesAligning: "Keep lines in the scene straight and lined up with the frame."
        case .symmetry: "Balance both halves of the frame like a mirror."
        case .halfBodyPortrait: "Frame a person from the waist up."
        case .compression: "Zoom in from far away so the background looks closer."
        case .negativeSpace: "Leave lots of empty space around a small subject."
        }
    }
}

// MARK: - Anchors

/// Collects where each tour stop's controls sit on screen. A step can spotlight more than one.
struct OnboardingAnchorKey: PreferenceKey {
    static let defaultValue: [OnboardingStep: [Anchor<CGRect>]] = [:]

    static func reduce(value: inout [OnboardingStep: [Anchor<CGRect>]], nextValue: () -> [OnboardingStep: [Anchor<CGRect>]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

extension View {
    /// Marks this view as a control the tour spotlights for each of `steps`.
    func onboardingAnchor(_ steps: OnboardingStep...) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) { anchor in
            Dictionary(uniqueKeysWithValues: steps.map { ($0, [anchor]) })
        }
    }
}

// MARK: - Overlay

/// Dims the screen except for the spotlighted controls, points at them, and explains what to do.
/// The controls stay live: touches inside the spotlight reach them, everything else is blocked.
struct OnboardingOverlay: View {
    let step: OnboardingStep
    /// The controls' frames, in the same space as `canvas`.
    let spots: [CGRect]
    let canvas: CGSize
    let stepNumber: Int
    let stepCount: Int
    let feedback: OnboardingFeedback?
    /// When set, the card's bottom edge sits here, with no arrow, instead of beside the spotlight.
    var cardBottom: CGFloat? = nil
    let onContinue: () -> Void
    let onSkip: () -> Void

    private let cornerRadius: CGFloat = 16
    /// The height of the card's text below the title, measured so the card hugs it.
    @State private var detailsHeight: CGFloat = 0
    /// The title row and the button row, measured, so the text gets whatever room is left.
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// Everything on the card but the scrolling text: title, buttons, the 10-point gaps and the padding.
    private var chromeHeight: CGFloat {
        headerHeight + footerHeight + 2 * 10 + 2 * 16
    }

    /// The holes in the dimming, a little bigger than the controls.
    private var cutouts: [CGRect] {
        spots.map { $0.insetBy(dx: -8, dy: -8) }
    }

    private var isLastStep: Bool {
        stepNumber == stepCount
    }

    var body: some View {
        ZStack {
            // Touches in the holes fall through to the real controls; the rest are swallowed.
            SpotlightMask(holes: cutouts, cornerRadius: cornerRadius)
                .fill(.black.opacity(0.7), style: FillStyle(eoFill: true))
                .contentShape(SpotlightMask(holes: cutouts, cornerRadius: cornerRadius), eoFill: true)
                .onTapGesture {}
                .accessibilityHidden(true)

            // A ring that keeps pulsing outwards from each control.
            ForEach(Array(cutouts.enumerated()), id: \.offset) { _, cutout in
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(feedback?.isComplete == true ? .green : .white, lineWidth: 2)
                    .frame(width: cutout.width, height: cutout.height)
                    .phaseAnimator([false, true]) { ring, isOut in
                        ring
                            .scaleEffect(isOut ? 1.12 : 1)
                            .opacity(isOut ? 0 : 0.9)
                    } animation: { isOut in
                        isOut ? .easeOut(duration: 1.2) : .linear(duration: 0)
                    }
                    .position(x: cutout.midX, y: cutout.midY)
                    .allowsHitTesting(false)
            }

            callout
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    /// Where the card goes: in the biggest free band of the screen, pointing at the control next to it.
    private var placement: (pointsUp: Bool, arrowX: CGFloat?, inset: CGFloat) {
        if let cardBottom {
            return (false, nil, canvas.height - cardBottom)
        }
        let sorted = cutouts.sorted { $0.minY < $1.minY }
        var bands: [(top: CGFloat, bottom: CGFloat, above: CGRect?, below: CGRect?)] = []
        var top: CGFloat = 0
        var above: CGRect?
        for cutout in sorted {
            bands.append((top, cutout.minY, above, cutout))
            top = cutout.maxY
            above = cutout
        }
        bands.append((top, canvas.height, above, nil))
        let band = bands.max { ($0.bottom - $0.top) < ($1.bottom - $1.top) }

        // Prefer pointing down at the control below the band, so the card sits right above it.
        if let below = band?.below {
            return (false, below.midX, canvas.height - below.minY + 6)
        }
        let target = band?.above ?? .zero
        return (true, target.midX, target.maxY + 6)
    }

    /// The explanation card, with an arrow pointing at the control.
    private var callout: some View {
        let placement = placement
        return VStack(spacing: 6) {
            if placement.pointsUp, let x = placement.arrowX {
                arrow(pointsUp: true, x: x)
            }
            card(maxHeight: max(canvas.height - placement.inset - 110, 200))
            if !placement.pointsUp, let x = placement.arrowX {
                arrow(pointsUp: false, x: x)
            }
        }
        .padding(placement.pointsUp ? .top : .bottom, placement.inset)
        .frame(width: canvas.width, height: canvas.height, alignment: placement.pointsUp ? .top : .bottom)
    }

    private func arrow(pointsUp: Bool, x: CGFloat) -> some View {
        let arrowWidth: CGFloat = 40
        // Lines up with the control, but never runs off the screen edge.
        let leading = min(max(x - arrowWidth / 2, 12), canvas.width - arrowWidth - 12)
        return Image(systemName: pointsUp ? "arrow.up" : "arrow.down")
            .font(.title.bold())
            .foregroundStyle(.white)
            .symbolEffect(.bounce, options: .repeating)
            .frame(width: arrowWidth)
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// `maxHeight` is the room beside the spotlight; at large text sizes the middle scrolls to fit.
    private func card(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The step count moves under the title when large text leaves no room beside it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer()
                    stepCounter
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    stepCounter
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            // Sized to its text, and scrolls only when large text needs more room than there is.
            ScrollView {
                details
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
            }
            .frame(maxHeight: min(detailsHeight, max(maxHeight - chromeHeight, 80)))
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)

            HStack {
                Button {
                    onSkip()
                } label: {
                    Text("Skip tour")
                }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if feedback?.isComplete == true {
                    Button {
                        onContinue()
                    } label: {
                        Text(isLastStep ? "Finish" : "Continue")
                    }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.glassProminent)
                        .tint(.yellow)
                        .foregroundStyle(.black)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Label("Your turn", systemImage: "hand.tap.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 360)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 20))
        // The card can sit inside the spotlight, so it takes touches itself rather than letting them reach the viewfinder.
        .contentShape(.rect(cornerRadius: 20))
        .padding(.horizontal, 20)
        .animation(.snappy, value: feedback)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text(step.title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stepCounter: some View {
        Text("\(stepNumber) of \(stepCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize()
    }

    /// The instruction, the feedback and any preview: the part of the card that can scroll.
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.instruction)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let feedback {
                Label {
                    Text(feedback.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: feedback.isComplete ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(feedback.isComplete ? .green : .yellow)
                }
                .font(.subheadline)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 12))
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .id(feedback.text)
                .accessibilityAddTraits(.updatesFrequently)

                if feedback.preview == .lightSignals {
                    LightSignalsPreview()
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole screen with rounded holes cut out. Filled and hit-tested even-odd, so the holes stay empty.
private struct SpotlightMask: Shape {
    var holes: [CGRect]
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        return path
    }
}

#Preview {
    GeometryReader { proxy in
        OnboardingOverlay(
            step: .topicMenu,
            spots: [CGRect(x: 16, y: 70, width: 150, height: 44)],
            canvas: proxy.size,
            stepNumber: 1,
            stepCount: 5,
            feedback: OnboardingFeedback(
                text: "\(AdviceTopic.light.displayTitle): \(AdviceTopic.light.tourDescription) When the light needs fixing, the card says who moves, amber arrows show the way, and Settings tips have a button that does it for you.",
                isComplete: false,
                preview: .lightSignals
            ),
            onContinue: {},
            onSkip: {}
        )
    }
    .ignoresSafeArea()
    .background(.gray)
    .environment(\.colorScheme, .dark)
}
