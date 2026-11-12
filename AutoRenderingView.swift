//
//  AutoRenderingView.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import SwiftUI

struct AutoRenderingView: View {
    @State private var camera = CameraManager()

    var body: some View {
        CameraPreview(session: camera.session)
            .ignoresSafeArea()
            .task {
                await camera.start()
            }
    }
}

#Preview {
    AutoRenderingView()
}
