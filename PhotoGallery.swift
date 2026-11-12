//
//  PhotoGallery.swift
//  Grp 6pm Photo App
//
//  Keeps track of the photos taken in this app. The photos live in the Photos library;
//  the app remembers their identifiers so the gallery shows only its own photos.
//

import SwiftUI
import Photos
import Observation

@Observable
final class PhotoGallery {
    private static let storageKey = "capturedAssetIdentifiers"

    /// Photos taken in the app, newest first.
    private(set) var assets: [PHAsset] = []
    /// Small image of the newest photo, used on the gallery button.
    private(set) var coverImage: UIImage?
    /// False when the person has denied Photos access.
    private(set) var hasAccess = true

    /// Saved identifiers, newest first.
    private var identifiers: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    func add(_ identifier: String) async {
        identifiers.insert(identifier, at: 0)
        await load()
    }

    /// Fetches the app's photos from the Photos library.
    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined && !identifiers.isEmpty {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        hasAccess = status != .denied && status != .restricted
        guard status == .authorized || status == .limited, !identifiers.isEmpty else {
            assets = []
            coverImage = nil
            return
        }

        let ids = identifiers
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let found = Dictionary(uniqueKeysWithValues: (0..<result.count).map {
            let asset = result.object(at: $0)
            return (asset.localIdentifier, asset)
        })
        assets = ids.compactMap { found[$0] }
        // Forget photos that were deleted outside the app, e.g. in the Photos app.
        identifiers = assets.map(\.localIdentifier)

        if let newest = assets.first {
            coverImage = await image(for: newest, size: CGSize(width: 160, height: 160))
        } else {
            coverImage = nil
        }
    }

    /// Deletes the photo from the Photos library. iOS asks the person to confirm.
    func delete(_ asset: PHAsset) async throws {
        let ids = [asset.localIdentifier]
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
        identifiers.removeAll { $0 == asset.localIdentifier }
        await load()
    }

    /// Loads an image of the photo at roughly `size` points.
    func image(for asset: PHAsset, size: CGSize, contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let options = PHImageRequestOptions()
        // One high-quality callback instead of a blurry one first.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let scale = UITraitCollection.current.displayScale
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
