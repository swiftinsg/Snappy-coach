//
//  PhotoControls.swift
//  Grp 6pm Photo App
//

import SwiftUI
import Observation

/// A camera control that can be pinned to the top bar of the camera view.
enum PhotoControl: String, CaseIterable, Identifiable {
    case flash, live, aspect, timer, exposure, styles, depth, nightMode
    case centerStage, format, focus, shutterSpeed, whiteBalance, histogram
    /// Physical variable aperture. Only offered on hardware that has one (iPhone 18 Pro / Pro Max).
    case lensAperture

    var id: String { rawValue }

    /// The controls shown by default and restored by "Reset to Essentials".
    static let essentials: [PhotoControl] = [.flash, .live]

    var title: String {
        switch self {
        case .flash: "Flash"
        case .live: "Live"
        case .aspect: "Aspect"
        case .timer: "Timer"
        case .exposure: "Exposure"
        case .styles: "Styles"
        case .depth: "Depth"
        case .nightMode: "Night Mode"
        case .centerStage: "Center Stage"
        case .format: "Format"
        case .focus: "Focus"
        case .shutterSpeed: "Shutter"
        case .whiteBalance: "White Balance"
        case .histogram: "Histogram"
        case .lensAperture: "Aperture"
        }
    }

    var systemImage: String {
        switch self {
        case .flash: "bolt.fill"
        case .live: "livephoto"
        case .aspect: "aspectratio"
        case .timer: "timer"
        case .exposure: "plusminus.circle"
        case .styles: "paintpalette"
        case .depth: "f.cursive.circle"
        case .nightMode: "moon.fill"
        case .centerStage: "person.crop.square"
        case .format: "r.square"
        case .focus: "viewfinder"
        case .shutterSpeed: "stopwatch"
        case .whiteBalance: "thermometer.sun"
        case .histogram: "chart.bar.fill"
        case .lensAperture: "camera.aperture"
        }
    }

    /// Controls with a range of values open a slider instead of toggling on tap.
    var usesSlider: Bool {
        switch self {
        case .exposure, .focus, .shutterSpeed, .whiteBalance, .lensAperture: true
        default: false
        }
    }

    /// Decodes the first dropped drag payload (a raw value string) into a control.
    init?(payload: [String]) {
        guard let first = payload.first, let control = PhotoControl(rawValue: first) else { return nil }
        self = control
    }
}

/// Holds the controls pinned to the top bar and the in-progress edits made
/// in the photo controls panel. Edits only apply when the user taps Done.
@Observable
final class PhotoControlsModel {
    static let maxPinned = 3

    private(set) var pinned: [PhotoControl] = PhotoControl.essentials
    private(set) var draft: [PhotoControl] = []
    private(set) var isEditing = false

    /// Controls this device can offer. Aperture is hidden unless the camera has a variable aperture.
    let availableControls: [PhotoControl]

    init(supportsVariableAperture: Bool = CameraManager.supportsVariableAperture) {
        availableControls = PhotoControl.allCases.filter {
            $0 != .lensAperture || supportsVariableAperture
        }
    }

    /// While editing, the top bar previews the draft so drops show up immediately.
    var visibleControls: [PhotoControl] { isEditing ? draft : pinned }
    var canAddMore: Bool { draft.count < Self.maxPinned }
    var emptySlotCount: Int { max(0, Self.maxPinned - draft.count) }

    func beginEditing() {
        draft = pinned
        isEditing = true
    }

    func cancel() {
        isEditing = false
        draft = []
    }

    func done() {
        pinned = draft
        isEditing = false
    }

    func resetToEssentials() {
        draft = PhotoControl.essentials
    }

    /// Adds `control` to the bar, or moves it if it is already there.
    /// When `target` is given the control is placed just before it; otherwise at the end.
    @discardableResult
    func place(_ control: PhotoControl, before target: PhotoControl? = nil) -> Bool {
        guard control != target else { return true }
        if let existing = draft.firstIndex(of: control) {
            draft.remove(at: existing)
        } else if !canAddMore {
            return false
        }
        if let target, let index = draft.firstIndex(of: target) {
            draft.insert(control, at: index)
        } else {
            draft.append(control)
        }
        return true
    }

    func remove(_ control: PhotoControl) {
        draft.removeAll { $0 == control }
    }

    /// Tap alternative to dragging, so the panel also works without drag and drop.
    func toggle(_ control: PhotoControl) {
        if draft.contains(control) {
            remove(control)
        } else {
            place(control)
        }
    }
}

/// Round Liquid Glass icon used for a control in both the top bar and the panel.
/// The top bar passes the live camera state; the panel uses the defaults.
struct ControlIcon: View {
    let control: PhotoControl
    var size: CGFloat = 44
    var systemImage: String?
    /// Short text such as "16:9" shown instead of the symbol.
    var text: String?
    /// Highlights the icon in yellow when the control is in a non-default state.
    var isActive = false

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            } else {
                Image(systemName: systemImage ?? control.systemImage)
                    .font(.title3)
            }
        }
        .foregroundStyle(isActive ? .yellow : .white)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .frame(width: size, height: size)
        // Frosted, slightly darkened glass so icons stay readable over bright scenes.
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .circle)
    }
}
