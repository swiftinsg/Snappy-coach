//
//  PhotoCaptureProcessor.swift
//  Grp 6pm Photo App
//
//  Handles one photo capture from start to finish: collects the image (plus RAW and
//  Live Photo movie when enabled), crops to the chosen aspect ratio, applies the style,
//  and saves to Photos.
//

import UIKit
@preconcurrency import AVFoundation
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins

enum CaptureError: LocalizedError {
    case noPhotoData

    var errorDescription: String? { "The camera didn't return a photo." }
}

nonisolated final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private static let context = CIContext()

    private let aspectRatio: AspectRatio
    private let style: PhotoStyle
    private let encodeAsJPEG: Bool
    private let willCapture: @Sendable () -> Void
    private let completion: @Sendable (Result<String?, Error>) -> Void

    private var photoData: Data?
    private var rawData: Data?
    private var livePhotoMovieURL: URL?

    /// - Parameters:
    ///   - willCapture: Called the moment the sensor fires, for the shutter blink.
    ///   - completion: Called once the photo is saved, with its Photos library identifier.
    init(aspectRatio: AspectRatio,
         style: PhotoStyle,
         encodeAsJPEG: Bool,
         willCapture: @escaping @Sendable () -> Void,
         completion: @escaping @Sendable (Result<String?, Error>) -> Void) {
        self.aspectRatio = aspectRatio
        self.style = style
        self.encodeAsJPEG = encodeAsJPEG
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            print("Photo processing failed: \(error)")
            return
        }
        // RAW captures deliver the DNG and the processed image as separate photos.
        if photo.isRawPhoto {
            rawData = photo.fileDataRepresentation()
        } else {
            photoData = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if error == nil {
            livePhotoMovieURL = outputFileURL
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard var mainData = photoData ?? rawData else {
            completion(.failure(CaptureError.noPhotoData))
            return
        }

        var movieURL = livePhotoMovieURL
        // The sensor shoots 4:3, so other ratios are a centre crop; styles are a colour grade.
        // Both edit the processed image only; RAW files are left untouched.
        if aspectRatio != .fourByThree || style != .standard, photoData != nil,
           let edited = Self.edit(mainData, ratio: aspectRatio, style: style, asJPEG: encodeAsJPEG) {
            mainData = edited
            // A re-encoded still no longer pairs with its Live Photo movie, so save it as a still.
            movieURL = nil
        }
        // Only keep the DNG alongside a processed image; a RAW-only capture is already mainData.
        let alternateRAW = photoData != nil ? rawData : nil
        let originalMovieURL = livePhotoMovieURL
        let completion = completion

        Task {
            do {
                let identifier = try await Self.save(photo: mainData, raw: alternateRAW, livePhotoMovie: movieURL)
                completion(.success(identifier))
            } catch {
                completion(.failure(error))
            }
            // Clean up the temporary movie if Photos didn't take it.
            if let originalMovieURL {
                try? FileManager.default.removeItem(at: originalMovieURL)
            }
        }
    }

    // MARK: - Helpers

    /// Saves to the Photos library and returns the new asset's identifier, so the app's gallery can find it.
    private static func save(photo: Data, raw: Data?, livePhotoMovie: URL?) async throws -> String? {
        let createdIdentifier = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            createdIdentifier.value = request.placeholderForCreatedAsset?.localIdentifier
            request.addResource(with: .photo, data: photo, options: nil)
            if let raw {
                request.addResource(with: .alternatePhoto, data: raw, options: nil)
            }
            if let livePhotoMovie {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: livePhotoMovie, options: options)
            }
        }
        return createdIdentifier.value
    }

    /// Centre-crops the image to `ratio`, applies the style, keeps it upright, and re-encodes it.
    private static func edit(_ data: Data, ratio: AspectRatio, style: PhotoStyle, asJPEG: Bool) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let cropped = crop(image, to: ratio)
        let styled = apply(style, to: cropped)

        if asJPEG {
            return context.jpegRepresentation(of: styled, colorSpace: colorSpace)
        }
        return context.heifRepresentation(of: styled, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Approximates the iPhone's Photographic Styles with a simple colour grade.
    private static func apply(_ style: PhotoStyle, to image: CIImage) -> CIImage {
        switch style {
        case .standard:
            return image
        case .richContrast:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = 1.15
            filter.saturation = 1.05
            filter.brightness = -0.02
            return filter.outputImage ?? image
        case .vibrant:
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = 0.6
            return filter.outputImage ?? image
        case .warm, .cool:
            // Nudge red up and blue down for warm, the reverse for cool.
            let shift: CGFloat = style == .warm ? 0.06 : -0.06
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.rVector = CIVector(x: 1 + shift, y: 0, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: 1 - shift, w: 0)
            return filter.outputImage ?? image
        }
    }

    /// Centre-crops an upright image to `ratio`. 4:3 is returned unchanged.
    private static func crop(_ image: CIImage, to ratio: AspectRatio) -> CIImage {
        guard ratio != .fourByThree else { return image }

        let extent = image.extent
        // Width ÷ height of the result, matching the photo's own orientation.
        let target = extent.width >= extent.height ? ratio.longToShort : 1 / ratio.longToShort
        var rect = extent
        if extent.width / extent.height > target {
            rect.size.width = extent.height * target
        } else {
            rect.size.height = extent.width / target
        }
        rect.origin.x = extent.midX - rect.width / 2
        rect.origin.y = extent.midY - rect.height / 2
        rect = rect.integral

        return image
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
    }
}

/// Carries the new asset's identifier out of the Photos change block.
nonisolated private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}
