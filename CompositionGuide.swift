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

extension CompositionGuide {
    /// Styles that clearly can't work for what the camera currently sees, with a short reason.
    /// Only styles that are certain to be wrong are disabled; anything uncertain stays available.
    static func unavailableStyles(in analysis: SceneAnalysis) -> [CompositionGuide: String] {
        var unavailable: [CompositionGuide: String] = [:]

        // A half-body portrait needs a person in the frame.
        if analysis.faces.isEmpty {
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

// MARK: - Picker

/// Horizontally scrolling row of composition styles, shown above the shutter.
/// Several styles can be selected at once; styles that don't suit the scene are dimmed.
struct CompositionPicker: View {
    @Binding var selection: Set<CompositionGuide>
    /// Styles that don't suit the current scene, with the reason to show.
    let unavailable: [CompositionGuide: String]

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
        // A style the person picked stays usable, even if the scene no longer suits it.
        let isDisabled = reason != nil && !isSelected
        return Button {
            toggle(guide)
        } label: {
            HStack(spacing: 4) {
                if isDisabled {
                    Image(systemName: "slash.circle")
                        .font(.caption2)
                }
                Text(guide.title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? .black : .white)
            .shadow(color: .black.opacity(isSelected ? 0 : 0.5), radius: 2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(
                isSelected ? .regular.tint(.yellow) : .regular.tint(.black.opacity(0.35)),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(reason ?? "")
    }

    private func toggle(_ guide: CompositionGuide) {
        if selection.contains(guide) {
            // Keep at least one style selected so the coach always has a goal.
            guard selection.count > 1 else { return }
            selection.remove(guide)
        } else {
            selection.insert(guide)
        }
    }
}
