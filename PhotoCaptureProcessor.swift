//
//  PhotoCaptureProcessor.swift
//  Grp 6pm Photo App
//
//  Handles one photo capture from start to finish: collects the image (plus RAW and
//  Live Photo movie when enabled), crops to the chosen aspect ratio, and saves to Photos.
//

import UIKit
@preconcurrency import AVFoundation
import Photos
import CoreImage

enum CaptureError: LocalizedError {
    case noPhotoData

    var errorDescription: String? { "The camera didn't return a photo." }
}

nonisolated final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private static let context = CIContext()

    private let aspectRatio: AspectRatio
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
         encodeAsJPEG: Bool,
         willCapture: @escaping @Sendable () -> Void,
         completion: @escaping @Sendable (Result<String?, Error>) -> Void) {
        self.aspectRatio = aspectRatio
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
        // The sensor shoots 4:3, so other ratios are a centre crop of the processed image.
        // RAW files are left uncropped.
        if aspectRatio != .fourByThree, photoData != nil,
           let cropped = Self.crop(mainData, to: aspectRatio, asJPEG: encodeAsJPEG) {
            mainData = cropped
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

    /// Centre-crops the image to `ratio`, keeping it upright, and re-encodes it.
    private static func crop(_ data: Data, to ratio: AspectRatio, asJPEG: Bool) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

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

        let cropped = image
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))

        if asJPEG {
            return context.jpegRepresentation(of: cropped, colorSpace: colorSpace)
        }
        return context.heifRepresentation(of: cropped, format: .RGBA8, colorSpace: colorSpace)
    }
}

/// Carries the new asset's identifier out of the Photos change block.
nonisolated private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}
