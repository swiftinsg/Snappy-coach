//
//  PhotoControlsSheet.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// The "Add Photo Controls" panel. Controls are dragged from here onto the
/// top bar; dragging a control from the bar back onto this panel removes it.
struct PhotoControlsSheet: View {
    let model: PhotoControlsModel

    private static let columns = 4

    /// Controls split into rows of four (HStack rows inside a VStack).
    private var rows: [[PhotoControl]] {
        let all = model.availableControls
        return stride(from: 0, to: all.count, by: Self.columns).map {
            Array(all[$0..<min($0 + Self.columns, all.count)])
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            header

            Text(model.canAddMore
                 ? "Drag controls to the top bar."
                 : "The top bar is full. Remove a control to add another.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 20) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(row) { control in
                            cell(for: control)
                        }
                        // Pad short rows so cells stay aligned to the grid. Spacer only
                        // grows horizontally, so the short row stays the same height as the others.
                        ForEach(row.count..<Self.columns, id: \.self) { _ in
                            Spacer(minLength: 0)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            Button("Reset to Essentials") {
                model.resetToEssentials()
            }
            .buttonStyle(.glass(.clear))
        }
        .padding(20)
        // Clear Liquid Glass so the camera viewfinder shows through.
        .glassEffect(.clear, in: .rect(cornerRadius: 36))
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = PhotoControl(payload: items) else { return }
            model.remove(dropped)
        }
    }

    /// Cancel and Done sit in the two top corners, like the iOS Camera app.
    private var header: some View {
        HStack {
            Button {
                model.cancel()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass(.clear))
            .buttonBorderShape(.circle)
            .accessibilityLabel("Cancel")

            Spacer()

            Text("Add Photo Controls")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                model.done()
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass(.clear))
            .buttonBorderShape(.circle)
            .accessibilityLabel("Done")
        }
    }

    @ViewBuilder
    private func cell(for control: PhotoControl) -> some View {
        let isPinned = model.draft.contains(control)

        VStack(spacing: 6) {
            ControlIcon(control: control, size: 56)
                .opacity(isPinned ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    }
                }

            Text(control.title)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .draggable(control.rawValue) {
            ControlIcon(control: control)
        }
        .onTapGesture {
            model.toggle(control)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isPinned ? "Added" : "Not added")
    }
}
