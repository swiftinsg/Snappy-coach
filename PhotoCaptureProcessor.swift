//
//  PhotoCaptureProcessor.swift
//  Grp 6pm Photo App
//
//  Handles one photo capture from start to finish: collects the image (plus RAW and
//  Live Photo movie when enabled), blurs the background for Portrait, crops to the chosen
//  aspect ratio, applies the style, and saves to Photos.
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
    /// Blur the background from the photo's depth, like the Camera app's Portrait mode.
    private let portrait: Bool
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
         portrait: Bool,
         willCapture: @escaping @Sendable () -> Void,
         completion: @escaping @Sendable (Result<String?, Error>) -> Void) {
        self.aspectRatio = aspectRatio
        self.style = style
        self.encodeAsJPEG = encodeAsJPEG
        self.portrait = portrait
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error != nil {
            // The capture then finishes without photo data and reports that as a failure.
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
        guard let capturedData = photoData ?? rawData else {
            completion(.failure(CaptureError.noPhotoData))
            return
        }

        // The sensor shoots 4:3, so other ratios are a centre crop; styles are a colour grade;
        // Portrait blurs the background. All edit the processed image only; RAW files are left untouched.
        let needsEdit = Self.needsEdit(ratio: aspectRatio, style: style, portrait: portrait) && photoData != nil
        // Only keep the DNG alongside a processed image; a RAW-only capture is already mainData.
        let alternateRAW = photoData != nil ? rawData : nil
        let originalMovieURL = livePhotoMovieURL
        let completion = completion
        let ratio = aspectRatio, style = style, asJPEG = encodeAsJPEG, portrait = portrait

        // Editing a full-size photo takes a moment, so it happens here rather than in this
        // callback, which would hold up the camera's next capture.
        Task {
            var mainData = capturedData
            var movieURL = originalMovieURL
            if needsEdit, let edited = Self.edit(mainData, ratio: ratio, style: style, portrait: portrait, asJPEG: asJPEG) {
                mainData = edited
                // A re-encoded still no longer pairs with its Live Photo movie, so save it as a still.
                movieURL = nil
            }
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

    /// Whether the processed photo has to be edited before saving.
    static func needsEdit(ratio: AspectRatio, style: PhotoStyle, portrait: Bool) -> Bool {
        ratio != .fourByThree || style != .standard || portrait
    }

    /// Blurs the background for Portrait, centre-crops the image to `ratio`, applies the style,
    /// keeps it upright, and re-encodes it.
    private static func edit(_ data: Data, ratio: AspectRatio, style: PhotoStyle, portrait: Bool, asJPEG: Bool) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Without depth in the file (a far-away scene, say) the photo is kept sharp rather than lost.
        let base = portrait ? (portraitBlur(data) ?? image) : image
        let cropped = crop(base, to: ratio)
        // Filters drop the photo's metadata, so put it back: date, place, camera and lens.
        let styled = apply(style, to: cropped).settingProperties(metadata(from: image.properties))

        if asJPEG {
            return context.jpegRepresentation(of: styled, colorSpace: colorSpace)
        }
        return context.heifRepresentation(of: styled, format: .RGBA8, colorSpace: colorSpace)
    }

    /// The original photo's metadata, fixed up for the edited image: it's already turned
    /// upright, and cropping changed its size, so those fields are reset or dropped.
    static func metadata(from properties: [String: Any]) -> [String: Any] {
        var metadata = properties
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        metadata.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }
        // The TIFF orientation must agree with the main one.
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return metadata
    }

    /// The photo with its background blurred from the depth saved in it, like the Camera app's
    /// Portrait mode, turned upright. Nil when the photo has no depth to work from.
    private static func portraitBlur(_ data: Data) -> CIImage? {
        guard let image = CIImage(data: data),
              let disparity = CIImage(data: data, options: [.auxiliaryDisparity: true]) else { return nil }
        // The person matte sharpens hair and edges when there's someone in the shot.
        let matte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true])
        let orientation = (image.properties[kCGImagePropertyOrientation as String] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        guard let filter = context.depthBlurEffectFilter(
            for: image, disparityImage: disparity, portraitEffectsMatte: matte, orientation: orientation, options: nil
        ) else { return nil }
        // Like the Camera app's default f/2.8: a soft background that still shows where it is.
        filter.setValue(portraitAperture, forKey: "inputAperture")
        // The filter works on the sensor's own orientation, so turn the result upright like the rest.
        return filter.outputImage?.cropped(to: image.extent).oriented(orientation)
    }

    /// How strong the Portrait blur is, as an f-number: lower is blurrier.
    private static let portraitAperture: Float = 2.8

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
