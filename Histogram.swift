//
//  Histogram.swift
//  Grp 6pm Photo App
//

import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns camera frames into a brightness histogram. Runs on the video output's queue.
nonisolated final class HistogramProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let binCount = 64
    /// Minimum time between updates, so the histogram doesn't redraw on every frame.
    private static let interval: TimeInterval = 0.25

    var onUpdate: (@Sendable ([Float]) -> Void)?

    private let context = CIContext()
    private var lastUpdate = Date.distantPast

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= Self.interval,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastUpdate = now

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = image.extent
        filter.count = Self.binCount
        filter.scale = 1
        guard let histogramImage = filter.outputImage else { return }

        // Each bin comes back as an RGBA float pixel.
        var rgba = [Float](repeating: 0, count: Self.binCount * 4)
        context.render(histogramImage,
                       toBitmap: &rgba,
                       rowBytes: Self.binCount * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: Self.binCount, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)

        // Average the colour channels into brightness, then scale so the tallest bin is 1.
        var luminance = (0..<Self.binCount).map { (rgba[$0 * 4] + rgba[$0 * 4 + 1] + rgba[$0 * 4 + 2]) / 3 }
        if let peak = luminance.max(), peak > 0 {
            luminance = luminance.map { $0 / peak }
        }
        onUpdate?(luminance)
    }
}

/// Small glass panel drawing the brightness histogram, dark tones on the left and bright on the right.
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(bins.count - 1)
                let y = size.height * (1 - CGFloat(value))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.8)))
        }
        .padding(8)
        .frame(width: 128, height: 64)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 12))
        .accessibilityLabel("Histogram")
    }
}
