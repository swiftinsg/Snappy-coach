//
//  CompositionGuide.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// Composition techniques the person can pick while the advice topic is Composition.
enum CompositionGuide: String, CaseIterable, Identifiable {
    case ruleOfThirdsOne, ruleOfThirdsTwo, ruleOfThirdsCorner, centre
    case onePointPerspective, tableTop45, tableTop90
    case leadingLines, singleVertex, doubleVertex, triangle, leadingLinesAligning
    case symmetry, halfBodyPortrait, compression, negativeSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ruleOfThirdsOne: "Thirds · 1/3"
        case .ruleOfThirdsTwo: "Thirds · 2/3"
        case .ruleOfThirdsCorner: "Thirds · Corner"
        case .centre: "Centre"
        case .onePointPerspective: "One-Point Perspective"
        case .tableTop45: "Table-Top 45°"
        case .tableTop90: "Table-Top 90° Aerial"
        case .leadingLines: "Leading Lines"
        case .singleVertex: "Single Vertex"
        case .doubleVertex: "Double Vertex"
        case .triangle: "Triangle"
        case .leadingLinesAligning: "Aligning Lines"
        case .symmetry: "Symmetry"
        case .halfBodyPortrait: "Half-Body Portrait"
        case .compression: "Compression"
        case .negativeSpace: "Negative Space"
        }
    }
}

// MARK: - Scene suitability

extension SceneType {
    /// Composition styles that usually suit this kind of photo, best first.
    var suitedStyles: [CompositionGuide] {
        switch self {
        case .food: [.tableTop45, .tableTop90, .centre, .negativeSpace]
        case .city: [.leadingLines, .onePointPerspective, .leadingLinesAligning, .symmetry]
        case .landscape: [.ruleOfThirdsOne, .ruleOfThirdsTwo, .leadingLines, .negativeSpace, .compression]
        case .nature: [.ruleOfThirdsCorner, .negativeSpace, .centre]
        case .people: [.halfBodyPortrait, .ruleOfThirdsOne, .centre]
        case .object: [.centre, .negativeSpace, .ruleOfThirdsCorner]
        }
    }
}

extension CompositionGuide {
    /// Styles that clearly can't work for what the camera currently sees, with a short reason.
    /// Only styles that are certain to be wrong are disabled; anything uncertain stays available.
    static func unavailableStyles(in analysis: SceneAnalysis) -> [CompositionGuide: String] {
        var unavailable: [CompositionGuide: String] = [:]

        // A half-body portrait needs a person in the frame.
        if analysis.personCount == 0 {
            unavailable[.halfBodyPortrait] = "Point the camera at a person"
        }

        // Table-top styles need the camera angled down toward a surface.
        if let pitch = analysis.pitch {
            if pitch > -20 {
                unavailable[.tableTop45] = "Tilt the camera down toward a surface"
            }
            if pitch > -55 {
                unavailable[.tableTop90] = "Hold the camera straight down"
            }
        }

        // These styles need something to place in the frame.
        if analysis.subject == nil {
            unavailable[.compression] = "Point the camera at a subject"
            unavailable[.negativeSpace] = "Point the camera at a small subject"
        }

        return unavailable
    }

    /// Styles that ask for incompatible subject positions or camera angles can't be practised together.
    func conflicts(with other: CompositionGuide) -> Bool {
        guard self != other else { return false }
        let pair: Set<CompositionGuide> = [self, other]

        // Only one subject placement makes sense at a time.
        let placements: Set<CompositionGuide> = [.ruleOfThirdsOne, .ruleOfThirdsTwo, .ruleOfThirdsCorner, .centre]
        if pair.isSubset(of: placements) { return true }
        // Two camera-angle styles can't both be right.
        if pair.isSubset(of: [.tableTop45, .tableTop90]) { return true }
        // One focal point or two, not both.
        if pair.isSubset(of: [.singleVertex, .doubleVertex]) { return true }
        // Filling the frame and leaving lots of empty space pull opposite ways.
        if pair.isSubset(of: [.negativeSpace, .compression]) { return true }

        // Symmetry wants the subject centred, so it can't sit on a thirds style.
        let thirds: Set<CompositionGuide> = [.ruleOfThirdsOne, .ruleOfThirdsTwo, .ruleOfThirdsCorner]
        if pair.contains(.symmetry), !pair.isDisjoint(with: thirds) { return true }
        // Negative space deliberately puts the subject off centre.
        if pair.contains(.negativeSpace), !pair.isDisjoint(with: [.centre, .symmetry]) { return true }
        // Table-top shots look down, which rules out a level portrait or one-point view.
        if !pair.isDisjoint(with: [.tableTop45, .tableTop90]),
           !pair.isDisjoint(with: [.halfBodyPortrait, .onePointPerspective]) {
            return true
        }
        return false
    }

    /// Keeps the first style of each conflicting group, in picker order.
    static func compatibleSelection(_ styles: Set<CompositionGuide>) -> Set<CompositionGuide> {
        var kept: Set<CompositionGuide> = []
        for guide in allCases where styles.contains(guide) {
            if !kept.contains(where: { $0.conflicts(with: guide) }) {
                kept.insert(guide)
            }
        }
        return kept
    }
}

// MARK: - Viewfinder grid

/// Draws the rule-of-thirds grid, plus guides for the selected composition styles.
struct CompositionGrid: View {
    let styles: Set<CompositionGuide>

    private let styleTint = Color.yellow.opacity(0.75)

    var body: some View {
        Canvas { context, size in
            // Rule-of-thirds lines are always visible while composing.
            var thirds = Path()
            for fraction in [1.0 / 3, 2.0 / 3] {
                thirds.move(to: CGPoint(x: size.width * fraction, y: 0))
                thirds.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                thirds.move(to: CGPoint(x: 0, y: size.height * fraction))
                thirds.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.3)), lineWidth: 0.75)

            // Extra guides for the styles that have a fixed line to aim at.
            var guides = Path()
            if styles.contains(.centre) {
                guides.move(to: CGPoint(x: size.width / 2, y: 0))
                guides.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                guides.move(to: CGPoint(x: 0, y: size.height / 2))
                guides.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            if styles.contains(.symmetry) {
                guides.move(to: CGPoint(x: size.width / 2, y: 0))
                guides.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            if styles.contains(.ruleOfThirdsOne) {
                guides.move(to: CGPoint(x: size.width / 3, y: 0))
                guides.addLine(to: CGPoint(x: size.width / 3, y: size.height))
            }
            if styles.contains(.ruleOfThirdsTwo) {
                guides.move(to: CGPoint(x: size.width * 2 / 3, y: 0))
                guides.addLine(to: CGPoint(x: size.width * 2 / 3, y: size.height))
            }
            if styles.contains(.onePointPerspective) {
                guides.move(to: .zero)
                guides.addLine(to: CGPoint(x: size.width, y: size.height))
                guides.move(to: CGPoint(x: size.width, y: 0))
                guides.addLine(to: CGPoint(x: 0, y: size.height))
            }
            context.stroke(guides, with: .color(styleTint), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))

            // The three-by-three style aims at the points where the thirds lines cross.
            if styles.contains(.ruleOfThirdsCorner) {
                for x in [size.width / 3, size.width * 2 / 3] {
                    for y in [size.height / 3, size.height * 2 / 3] {
                        let dot = CGRect(x: x - 6, y: y - 6, width: 12, height: 12)
                        context.stroke(Path(ellipseIn: dot), with: .color(styleTint), lineWidth: 1.5)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Level

/// A level like the Camera app's: two fixed marks with a line between them that follows the
/// horizon. When the phone is level enough for the coach, the pieces join and turn green.
/// Works held in portrait or sideways, and hides when the phone points straight up or down.
struct CameraLevel: View {
    let attitude: PhoneAttitude

    var body: some View {
        // Gravity is read on its own clock, much faster than the coach checks frames.
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            if let roll = attitude.roll {
                // Which way up the phone is held (portrait or sideways), and how far off level it is.
                let base = (roll / 90).rounded() * 90
                let tilt = roll - base
                let isLevel = !CoachRules.isTilted(tilt, alreadyShown: true)
                let tint: Color = isLevel ? .green : .white

                HStack(spacing: 0) {
                    Capsule().fill(tint).frame(width: 28, height: 2)
                    Spacer().frame(width: isLevel ? 0 : 10)
                    // The horizon turns the opposite way to the phone.
                    Capsule().fill(tint).frame(width: 110, height: isLevel ? 2 : 1.5)
                        .rotationEffect(.degrees(isLevel ? 0 : -tilt))
                    Spacer().frame(width: isLevel ? 0 : 10)
                    Capsule().fill(tint).frame(width: 28, height: 2)
                }
                .shadow(color: .black.opacity(0.5), radius: 1)
                .rotationEffect(.degrees(-base))
                .animation(.snappy, value: isLevel)
                .accessibilityElement()
                .accessibilityLabel(isLevel ? "Level" : "Tilted \(Int(abs(tilt).rounded())) degrees")
            }
        }
        .allowsHitTesting(false)
        .onAppear { attitude.start() }
        .onDisappear { attitude.stop() }
    }
}

// MARK: - Picker

/// Horizontally scrolling row of composition styles, shown above the shutter.
/// Several styles can be selected at once, but only ones that can work together.
/// Styles that don't suit the scene are dark; tapping one explains why.
struct CompositionPicker: View {
    @Binding var selection: Set<CompositionGuide>
    /// Styles that don't suit the current scene, with the reason to show.
    let unavailable: [CompositionGuide: String]
    /// The style the coach thinks suits this scene best. Only a suggestion — any style can be picked.
    var recommended: CompositionGuide?
    /// Called with an explanation when a style can't be used.
    var onMessage: (String) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(CompositionGuide.allCases) { guide in
                        chip(for: guide)
                            .id(guide)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Let the row run to the screen edges while the first and last chips keep a margin.
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
            .onAppear {
                scrollToFirstSelection(proxy)
            }
            .onChange(of: selection) {
                scrollToFirstSelection(proxy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composition styles")
    }

    private func scrollToFirstSelection(_ proxy: ScrollViewProxy) {
        guard let first = CompositionGuide.allCases.first(where: selection.contains) else { return }
        withAnimation(.snappy) {
            proxy.scrollTo(first, anchor: .center)
        }
    }

    private func chip(for guide: CompositionGuide) -> some View {
        let isSelected = selection.contains(guide)
        let reason = unavailable[guide]
        let isUnavailable = reason != nil
        let isRecommended = guide == recommended
        // Greyed out like a disabled control, but still tappable so it can explain why.
        let isGreyedOut = isUnavailable && !isSelected
        return Button {
            toggle(guide)
        } label: {
            HStack(spacing: 4) {
                if isUnavailable {
                    Image(systemName: "slash.circle")
                        .font(.caption2)
                } else if isRecommended {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .black : .yellow)
                }
                Text(guide.title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? .black : (isUnavailable ? Color.gray : .white))
            .shadow(color: .black.opacity(isSelected || isUnavailable ? 0 : 0.5), radius: 2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(
                isSelected
                    ? .regular.tint(.yellow)
                    : .regular.tint(.black.opacity(isUnavailable ? 0.7 : 0.35)),
                in: .capsule
            )
            .overlay {
                // The coach's pick gets a thin yellow ring so it stands out without being pushy.
                if isRecommended, !isSelected {
                    Capsule()
                        .strokeBorder(.yellow.opacity(0.8), lineWidth: 1)
                }
            }
            .saturation(isGreyedOut ? 0 : 1)
            .opacity(isGreyedOut ? 0.55 : (isUnavailable ? 0.7 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(accessibilityHint(for: guide, isUnavailable: isUnavailable, isRecommended: isRecommended))
    }

    private func accessibilityHint(for guide: CompositionGuide, isUnavailable: Bool, isRecommended: Bool) -> String {
        if let reason = unavailable[guide] { return "Does not work for this scene. \(reason)" }
        var parts: [String] = []
        if isRecommended { parts.append("Recommended for this scene") }
        let conflicts = selection.filter { $0.conflicts(with: guide) }
        if !conflicts.isEmpty {
            let names = CompositionGuide.allCases.filter(conflicts.contains).map(\.title)
            parts.append("Replaces \(names.formatted(.list(type: .and)))")
        }
        return parts.joined(separator: ". ")
    }

    private func toggle(_ guide: CompositionGuide) {
        if selection.contains(guide) {
            // Keep at least one style selected so the coach always has a goal.
            guard selection.count > 1 else {
                onMessage("Keep at least one style selected.")
                return
            }
            selection.remove(guide)
            return
        }

        // The style is looked at through a dark, usable chip rather than being disabled.
        if let reason = unavailable[guide] {
            onMessage("\(guide.title) does not work for this scene. \(reason).")
            return
        }

        // Multi-select only combines styles that can be true at the same time, so a style that
        // conflicts with the selection replaces the styles it conflicts with.
        // Built up first and written once: the binding fills an empty selection back in with a
        // default, so removing the conflicts and adding the new style separately would undo the swap.
        let conflicts = selection.filter { $0.conflicts(with: guide) }
        var updated = selection.subtracting(conflicts)
        updated.insert(guide)
        selection = updated
        if !conflicts.isEmpty {
            let names = CompositionGuide.allCases.filter(conflicts.contains).map(\.title)
            onMessage("Swapped \(names.formatted(.list(type: .and))) for \(guide.title).")
        }
    }
}
