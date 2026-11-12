//
//  ZoomPicker.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// Row of lens buttons (.5, 1×, 2, 5…) like the Camera app. The selected one is
/// larger, yellow and shows a "×".
struct ZoomPicker: View {
    let stops: [CGFloat]
    let level: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(stops, id: \.self) { stop in
                let isSelected = stop == level
                Button {
                    onSelect(stop)
                } label: {
                    Text(label(for: stop, isSelected: isSelected))
                        .font(isSelected ? .footnote.bold() : .caption2.bold())
                        .foregroundStyle(isSelected ? .yellow : .white)
                        .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
                        .background(.black.opacity(0.35), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label(for: stop, isSelected: false)) times zoom")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
        .animation(.snappy, value: level)
    }

    /// "0.5" becomes ".5", whole numbers drop the decimal, and the selected one gets "×".
    private func label(for stop: CGFloat, isSelected: Bool) -> String {
        var text = Double(stop).formatted(.number.precision(.fractionLength(0...1)))
        if stop < 1, text.hasPrefix("0") {
            text.removeFirst()
        }
        return isSelected ? text + "×" : text
    }
}
