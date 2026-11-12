//
//  AutoRenderingView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import SwiftUI

struct AutoRenderingView: View {
    @State private var controls = PhotoControlsModel()
    @State private var camera = CameraManager()
    @State private var activeAdjustment: PhotoControl?
    @State private var statusMessage: String?

    var body: some View {
        ZStack {
            // Placeholder until the live camera preview layer is built.
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                PhotoControlsBar(model: controls, camera: camera, activeAdjustment: $activeAdjustment) { message in
                    statusMessage = message
                }

                if !controls.isEditing {
                    if let activeAdjustment {
                        CameraAdjustmentSlider(control: activeAdjustment, camera: camera)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if camera.isHistogramOn {
                        HistogramView(bins: camera.histogram)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Spacer()

                if controls.isEditing {
                    PhotoControlsSheet(model: controls)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
        }
        // Brief banner confirming what a tap changed, e.g. "Flash Auto".
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.clear, in: .capsule)
                    .padding(.top, 72)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task {
            await camera.start()
        }
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            statusMessage = nil
        }
        .onChange(of: controls.isEditing) {
            if controls.isEditing {
                activeAdjustment = nil
            }
        }
        .animation(.spring, value: controls.isEditing)
        .animation(.snappy, value: controls.draft)
        .animation(.snappy, value: activeAdjustment)
        .animation(.easeInOut, value: statusMessage)
        .sensoryFeedback(.impact, trigger: controls.draft)
        .sensoryFeedback(.selection, trigger: statusMessage)
        .environment(\.colorScheme, .dark)
    }
}

#Preview {
    AutoRenderingView()
}
