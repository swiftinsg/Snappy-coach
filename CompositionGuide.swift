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

/// Horizontally scrolling row of composition styles, shown above the shutter.
struct CompositionPicker: View {
    @Binding var selection: CompositionGuide

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
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) {
                withAnimation(.snappy) {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composition style")
    }

    private func chip(for guide: CompositionGuide) -> some View {
        let isSelected = guide == selection
        return Button {
            selection = guide
        } label: {
            Text(guide.title)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
