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
    var placesCardOnControls: Bool { self == .selectObject || self == .alignSubject }

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
        case .selectObject:
            "Double-tap the thing you want to photograph. The coach will follow it and give advice about it. A single tap sets focus and brightness, like the Camera app."
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
}

// MARK: - Explanations shown as feedback

extension AdviceTopic {
    /// What picking this topic does, in a sentence.
    var tourDescription: String {
        switch self {
        case .composition: "Pick a style, then move the phone until the dot is in the circle."
        case .anglePerspective: "A level helps you hold the camera straight and find better angles."
        case .focus: "The coach helps keep your subject sharp."
        case .light: "The coach helps you find good light and get the brightness right. Amber arrows show who moves: you, around the subject, or the subject, toward the light."
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
            card
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.headline)
                Spacer()
                Text("\(stepNumber) of \(stepCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

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
            }

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
            feedback: OnboardingFeedback(text: "Composition it is. \(AdviceTopic.composition.tourDescription)", isComplete: true),
            onContinue: {},
            onSkip: {}
        )
    }
    .ignoresSafeArea()
    .background(.gray)
    .environment(\.colorScheme, .dark)
}
