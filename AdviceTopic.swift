//
//  AdviceTopic.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// What the live advice focuses on. Chosen from the dropdown in the top bar.
enum AdviceTopic: String, CaseIterable, Identifiable {
    case composition, subjectPosition, anglePerspective, focus, light, exposure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composition: "Composition"
        case .subjectPosition: "Subject Position"
        case .anglePerspective: "Angle & Perspective"
        case .focus: "Focus"
        case .light: "Light"
        case .exposure: "Exposure"
        }
    }

    /// Shorter name for the dropdown button, so it fits beside the camera controls.
    var shortTitle: String {
        switch self {
        case .subjectPosition: "Subject"
        case .anglePerspective: "Angle"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .composition: "square.grid.3x3"
        case .subjectPosition: "person.crop.rectangle"
        case .anglePerspective: "angle"
        case .focus: "dot.viewfinder"
        case .light: "sun.max"
        case .exposure: "plusminus.circle"
        }
    }
}

/// Glass dropdown button for picking the advice topic.
struct AdviceTopicMenu: View {
    @Binding var selection: AdviceTopic

    var body: some View {
        Menu {
            Picker("Advice Topic", selection: $selection) {
                ForEach(AdviceTopic.allCases) { topic in
                    Label(topic.title, systemImage: topic.systemImage)
                        .tag(topic)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.systemImage)
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
}
