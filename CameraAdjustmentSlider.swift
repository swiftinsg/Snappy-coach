//
//  CameraAdjustmentSlider.swift
//  Grp 6pm Photo App
//

import SwiftUI

/// Glass slider shown under the top bar for controls with a range of values
/// (exposure, focus, shutter speed, white balance, aperture).
struct CameraAdjustmentSlider: View {
    let control: PhotoControl
    let camera: CameraManager

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(control.title)
                    .font(.subheadline.bold())

                Spacer()

                Text(camera.sliderLabel(for: control))
                    .font(.subheadline.monospacedDigit())

                Button(control == .exposure ? "Reset" : "Auto") {
                    camera.resetAdjustment(control)
                }
                .buttonStyle(.glass(.clear))
                .disabled(camera.isAuto(control))
            }

            Slider(
                value: Binding(
                    get: { camera.sliderValue(for: control) },
                    set: { camera.setAdjustment($0, for: control) }
                ),
                in: camera.sliderRange(for: control)
            )
            .accessibilityLabel(control.title)
            .accessibilityValue(camera.sliderLabel(for: control))
        }
        .foregroundStyle(.white)
        .tint(.yellow)
        .padding()
        .glassEffect(.clear, in: .rect(cornerRadius: 24))
    }
}
