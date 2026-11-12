//
//  CameraSettings.swift
//  Grp 6pm Photo App
//
//  The options each multi-choice camera control cycles through, like the iOS Camera app.
//

import AVFoundation

extension CaseIterable where Self: Equatable {
    /// The next option, wrapping back to the first after the last.
    var next: Self {
        let all = Array(Self.allCases)
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

enum FlashSetting: CaseIterable {
    case auto, on, off

    var title: String {
        switch self {
        case .auto: "Auto"
        case .on: "On"
        case .off: "Off"
        }
    }

    var systemImage: String {
        switch self {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: .auto
        case .on: .on
        case .off: .off
        }
    }
}

enum AspectRatio: CaseIterable {
    case fourByThree, sixteenByNine, square

    var title: String {
        switch self {
        case .fourByThree: "4:3"
        case .sixteenByNine: "16:9"
        case .square: "1:1"
        }
    }
}

enum TimerSetting: CaseIterable {
    case off, three, ten

    var seconds: Int {
        switch self {
        case .off: 0
        case .three: 3
        case .ten: 10
        }
    }

    var title: String { self == .off ? "Off" : "\(seconds)s" }
}

/// Mirrors the iPhone's Photographic Styles presets.
enum PhotoStyle: CaseIterable {
    case standard, richContrast, vibrant, warm, cool

    var title: String {
        switch self {
        case .standard: "Standard"
        case .richContrast: "Rich Contrast"
        case .vibrant: "Vibrant"
        case .warm: "Warm"
        case .cool: "Cool"
        }
    }
}

enum PhotoFormat: CaseIterable {
    case heif, jpeg, proRAW

    var title: String {
        switch self {
        case .heif: "HEIF"
        case .jpeg: "JPEG"
        case .proRAW: "RAW"
        }
    }
}
