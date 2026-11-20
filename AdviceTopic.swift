//
//  AdviceTopic.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// What the live advice focuses on. Chosen from the dropdown in the top bar.
enum AdviceTopic: String, CaseIterable, Identifiable {
    case composition, anglePerspective, focus, light, exposure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composition: "Composition"
        case .anglePerspective: "Angle & Perspective"
        case .focus: "Focus"
        case .light: "Light"
        case .exposure: "Exposure"
        }
    }

    /// Shorter name for the dropdown button, so it fits beside the camera controls.
    var shortTitle: String {
        switch self {
        case .anglePerspective: "Angle"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .composition: "square.grid.3x3"
        case .anglePerspective: "angle"
        case .focus: "dot.viewfinder"
        case .light: "sun.max"
        case .exposure: "plusminus.circle"
        }
    }

    /// Controls pinned to the top bar for this topic until the user customises it.
    /// These match the tools the coach names in its tips for the topic.
    var defaultControls: [PhotoControl] {
        switch self {
        case .composition: [.aspect, .timer, .live]
        case .anglePerspective: [.aspect, .timer, .live]
        case .focus: [.focus, .depth, .lensAperture]
        case .light: [.flash, .nightMode, .whiteBalance]
        case .exposure: [.exposure, .shutterSpeed, .histogram]
        }
    }
}

/// Glass dropdown button for picking the advice topic.
struct AdviceTopicMenu: View {
    @Binding var selection: AdviceTopic
    /// Turns the topic icon to face the person when the phone is held sideways.
    var iconRotation: Angle = .zero
    /// Called whenever a topic is picked, even the one already selected.
    var onSelect: (AdviceTopic) -> Void = { _ in }
    /// Shown as a header at the top of the open menu to guide the first-launch tour.
    /// While it's set, each topic also says what it teaches.
    var prompt: String? = nil

    var body: some View {
        Menu {
            if let prompt {
                Section(prompt) {
                    // Toggles rather than a picker, because menu toggles can show a subtitle.
                    ForEach(AdviceTopic.allCases) { topic in
                        Toggle(isOn: Binding(get: { selection == topic }, set: { _ in
                            selection = topic
                            onSelect(topic)
                        })) {
                            Label(topic.title, systemImage: topic.systemImage)
                            Text(topic.tourDescription)
                        }
                    }
                }
            } else {
                topicPicker
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.systemImage)
                    .rotationEffect(iconRotation)
                Text(selection.shortTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
        }
        .accessibilityLabel("Advice topic")
        .accessibilityValue(selection.title)
    }

    private var topicPicker: some View {
        Picker("Advice Topic", selection: Binding(get: { selection }, set: { topic in
            selection = topic
            onSelect(topic)
        })) {
            ForEach(AdviceTopic.allCases) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic)
            }
        }
    }
}
