//
//  AdviceTopic.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// What the live advice focuses on. Chosen from the dropdown in the top bar.
enum AdviceTopic: String, CaseIterable, Identifiable {
    /// In the order to work in: where to stand for the light, then the framing, then the details.
    case light, composition, anglePerspective, focus

    var id: String { rawValue }

    /// A topic saved by an earlier version. Light and Exposure became one mode, so old
    /// Exposure photos and settings carry over to it.
    static func stored(_ rawValue: String) -> AdviceTopic? {
        rawValue == "exposure" ? .light : AdviceTopic(rawValue: rawValue)
    }

    /// Where it comes in the shooting order, shown beside it in the menu.
    var step: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var title: String {
        switch self {
        case .composition: "Composition"
        case .anglePerspective: "Angle & Perspective"
        case .focus: "Focus"
        case .light: "Light & Exposure"
        }
    }

    /// The name as shown on screen: never split across lines, so "Angle & Perspective" moves to the
    /// next line whole rather than breaking as "Per-spective". `title` stays plain for the model.
    var displayTitle: String { title.keptTogether }

    /// Shorter name for the dropdown button, so it fits beside the camera controls.
    var shortTitle: String {
        switch self {
        case .anglePerspective: "Angle"
        case .light: "Light"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .composition: "square.grid.3x3"
        case .anglePerspective: "angle"
        case .focus: "dot.viewfinder"
        case .light: "sun.max"
        }
    }

    /// Controls pinned to the top bar for this topic until the user customises it.
    /// These match the tools the coach names in its tips for the topic.
    var defaultControls: [PhotoControl] {
        switch self {
        case .composition: [.aspect, .timer, .live]
        case .anglePerspective: [.aspect, .timer, .live]
        case .focus: [.focus, .depth, .lensAperture]
        case .light: [.exposure, .flash, .nightMode]
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
                            Label("\(topic.step). \(topic.displayTitle)", systemImage: topic.systemImage)
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
                Label("\(topic.step). \(topic.displayTitle)", systemImage: topic.systemImage)
                    .tag(topic)
            }
        }
    }
}

// Only redrawn when what it shows changes. The camera screen around it updates many times a second,
// and an open menu that gets rebuilt jumps back to the top while it's being scrolled.
extension AdviceTopicMenu: Equatable {
    static func == (lhs: AdviceTopicMenu, rhs: AdviceTopicMenu) -> Bool {
        lhs.selection == rhs.selection && lhs.prompt == rhs.prompt && lhs.iconRotation == rhs.iconRotation
    }
}

extension String {
    /// The same text, but the system never hyphenates its words when wrapping: an invisible
    /// word joiner sits between each pair of letters. Spaces can still wrap.
    var unhyphenated: String {
        var result = ""
        var previous: Character?
        for character in self {
            if let previous, previous.isLetter || previous.isNumber, character.isLetter || character.isNumber {
                result.append("\u{2060}")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// The same text, never split across lines at all: no hyphens, and no breaks at its spaces.
    /// For short names inside sentences, which then move to the next line whole.
    var keptTogether: String {
        unhyphenated.replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}
