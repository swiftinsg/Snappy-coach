//
//  PhotoControlsBar.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// The row of pinned controls at the top of the camera view.
/// In edit mode it becomes a drop target: controls can be dropped in, reordered, or removed.
struct PhotoControlsBar: View {
    let model: PhotoControlsModel
    let camera: CameraManager
    /// The slider control currently open under the bar, if any.
    @Binding var activeAdjustment: PhotoControl?
    /// Called with a short message (e.g. "Flash Auto") after a control is tapped.
    var onStatus: (String) -> Void = { _ in }

    var body: some View {
        // Push the controls into the top-right corner.
        HStack {
            Spacer(minLength: 0)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ForEach(model.visibleControls) { control in
                if model.isEditing {
                    editableIcon(for: control)
                } else {
                    Button {
                        handleTap(on: control)
                    } label: {
                        ControlIcon(
                            control: control,
                            systemImage: camera.systemImage(for: control),
                            text: camera.badgeText(for: control),
                            isActive: camera.isActive(control) || activeAdjustment == control
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(control.title)
                }
            }

            if model.isEditing {
                // Dashed empty slots hint at where controls can be dropped.
                ForEach(0..<model.emptySlotCount, id: \.self) { _ in
                    Circle()
                        .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }
        }
        // Keep a corner target to press even if every control was removed.
        .frame(minWidth: 44, minHeight: 44)
        .padding(8)
        .contentShape(.rect)
        // Press and hold the controls to open the photo controls panel. It's simultaneous
        // so it fires as soon as the hold duration is reached, instead of waiting for the
        // icon buttons to give up the touch on release. Disabled while editing so it
        // doesn't compete with dragging icons.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                model.beginEditing()
            },
            isEnabled: !model.isEditing
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit photo controls") {
            model.beginEditing()
        }
        .background {
            if model.isEditing {
                RoundedRectangle(cornerRadius: 30)
                    .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6]))
            }
        }
        // Dropping anywhere on the bar appends the control.
        .dropDestination(for: String.self, isEnabled: model.isEditing) { items, _ in
            guard let dropped = PhotoControl(payload: items) else { return }
            model.place(dropped)
        }
    }

    /// Slider controls open or close their slider; everything else toggles or cycles straight away.
    private func handleTap(on control: PhotoControl) {
        if control.usesSlider {
            activeAdjustment = activeAdjustment == control ? nil : control
        } else {
            onStatus(camera.activate(control))
        }
    }

    private func editableIcon(for control: PhotoControl) -> some View {
        ControlIcon(control: control)
            .overlay(alignment: .topLeading) {
                Button {
                    model.remove(control)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: -4)
                .accessibilityLabel("Remove \(control.title)")
            }
            .draggable(control.rawValue) {
                ControlIcon(control: control)
            }
            // Dropping onto an existing icon inserts before it, which also handles reordering.
            .dropDestination(for: String.self) { items, _ in
                guard let dropped = PhotoControl(payload: items) else { return }
                model.place(dropped, before: control)
            }
    }
}
