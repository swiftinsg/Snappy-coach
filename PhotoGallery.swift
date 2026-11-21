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
import UniformTypeIdentifiers

/// A photo to share. The image data is only loaded when the share sheet asks for it,
/// so selecting many photos stays fast.
nonisolated struct SharedPhoto: Transferable {
    let assetIdentifier: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { photo in
            try await photo.jpegData()
        }
    }

    private func jpegData() async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        // Re-encode as JPEG so any app can open it (originals may be HEIF).
        guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return jpeg
    }
}

/// How a photo was made: what the coach knew when the shutter fired. Shown as the photo's story
/// in the gallery, and used to group photos by the mode they were practised in.
nonisolated struct ShotRecord: Codable, Equatable, Sendable {
    /// `AdviceTopic.rawValue`, kept as text so a renamed or removed mode can't break old records.
    var topicID: String
    /// Composition style titles, empty for the other modes.
    var styles: [String] = []
    /// What kind of scene it was, like "Food".
    var scene: String?
    /// The coach said the shot was ready.
    var wasReady: Bool
    /// Past-tense wins since the previous photo, like "levelled the phone".
    var fixed: [String] = []
    /// What the coach liked.
    var praised: [String] = []
    /// The tip still showing when the shot wasn't ready.
    var suggestion: String?
    var date: Date
}

extension ShotRecord {
    var topic: AdviceTopic? { AdviceTopic(rawValue: topicID) }
}

/// One run of photos in the gallery grid: a mode, or nil for photos taken before stories were saved.
struct GallerySection: Identifiable {
    let topic: AdviceTopic?
    let assets: [PHAsset]

    var id: String { topic?.rawValue ?? "earlier" }
    var title: String { topic?.displayTitle ?? "Earlier photos" }

    /// Splits photos (newest first) by the mode they were taken in, in the modes' menu order,
    /// keeping each section newest first. With `filter`, only that mode's photos.
    static func group(_ assets: [PHAsset], topicOf: (PHAsset) -> AdviceTopic?, filter: AdviceTopic? = nil) -> [GallerySection] {
        grouped(assets, topicOf: topicOf, filter: filter).map { GallerySection(topic: $0.topic, assets: $0.items) }
    }

    /// The grouping itself, for any kind of item, so it can be tested without the Photos library.
    static func grouped<Item>(_ items: [Item], topicOf: (Item) -> AdviceTopic?, filter: AdviceTopic? = nil) -> [(topic: AdviceTopic?, items: [Item])] {
        let byTopic = Dictionary(grouping: items, by: topicOf)
        if let filter {
            return [(filter, byTopic[filter] ?? [])]
        }
        let topics: [AdviceTopic?] = AdviceTopic.allCases.map(Optional.some) + [nil]
        return topics.compactMap { topic in
            guard let found = byTopic[topic], !found.isEmpty else { return nil }
            return (topic, found)
        }
    }
}

@Observable
final class PhotoGallery {
    private static let storageKey = "capturedAssetIdentifiers"
    private static let recordsKey = "shotRecords"

    /// Photos taken in the app, newest first.
    private(set) var assets: [PHAsset] = []
    /// Small image of the newest photo, used on the gallery button.
    private(set) var coverImage: UIImage?
    /// False when the person has denied Photos access.
    private(set) var hasAccess = true

    /// The size of a thumbnail in the gallery grid, in points.
    static let thumbnailSize = CGSize(width: 140, height: 140)
    /// Grid thumbnails loaded ahead of time, by asset identifier, so the gallery opens already filled in.
    @ObservationIgnored private var thumbnails: [String: UIImage] = [:]
    /// How many of the newest photos get their thumbnail loaded ahead of time.
    private static let preloadCount = 60

    /// Each photo's story, by asset identifier. Photos taken before stories were saved have none.
    private(set) var records: [String: ShotRecord] = PhotoGallery.loadRecords() {
        didSet { Self.save(records) }
    }

    private static func loadRecords() -> [String: ShotRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ShotRecord].self, from: data)) ?? [:]
    }

    private static func save(_ records: [String: ShotRecord]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recordsKey)
    }

    func record(for asset: PHAsset) -> ShotRecord? {
        records[asset.localIdentifier]
    }

    /// The gallery's sections, newest photos first in each.
    func sections(filter: AdviceTopic? = nil) -> [GallerySection] {
        GallerySection.group(assets, topicOf: { record(for: $0)?.topic }, filter: filter)
    }

    /// How many photos each mode has, for the filter chips.
    var countsByTopic: [AdviceTopic: Int] {
        Dictionary(grouping: assets.compactMap { record(for: $0)?.topic }, by: \.self).mapValues(\.count)
    }

    /// Saved identifiers, newest first.
    private var identifiers: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    func add(_ identifier: String, record: ShotRecord? = nil) async {
        identifiers.insert(identifier, at: 0)
        if let record {
            records[identifier] = record
        }
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
        let kept = Set(identifiers)
        if records.keys.contains(where: { !kept.contains($0) }) {
            records = records.filter { kept.contains($0.key) }
        }

        if let newest = assets.first {
            coverImage = await image(for: newest, size: CGSize(width: 160, height: 160))
        } else {
            coverImage = nil
        }

        // Forget thumbnails of photos that are gone, then load the newest ones that aren't ready yet.
        let current = Set(assets.map(\.localIdentifier))
        thumbnails = thumbnails.filter { current.contains($0.key) }
        // All at once rather than one by one, so they're ready even if the gallery is opened right away.
        let missing = assets.prefix(Self.preloadCount).filter { thumbnails[$0.localIdentifier] == nil }
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for asset in missing {
                group.addTask { (asset.localIdentifier, await self.image(for: asset, size: Self.thumbnailSize)) }
            }
            for await (identifier, image) in group {
                // Decoded now, so showing it later doesn't have to wait.
                thumbnails[identifier] = image?.preparingForDisplay() ?? image
            }
        }
    }

    /// Whether the sharp grid thumbnail is already loaded.
    func hasThumbnail(for asset: PHAsset) -> Bool {
        thumbnails[asset.localIdentifier] != nil
    }

    /// Something to show in the grid straight away: the loaded thumbnail, or else the small
    /// preview Photos keeps on hand, which is instant. Nil only if Photos has neither.
    func instantThumbnail(for asset: PHAsset) -> UIImage? {
        if let cached = thumbnails[asset.localIdentifier] { return cached }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        var preview: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: options) { image, _ in
            preview = image
        }
        return preview
    }

    /// The grid thumbnail, loaded and kept for next time.
    func thumbnail(for asset: PHAsset) async -> UIImage? {
        if let cached = thumbnails[asset.localIdentifier] { return cached }
        let loaded = await image(for: asset, size: Self.thumbnailSize)
        let image = loaded?.preparingForDisplay() ?? loaded
        thumbnails[asset.localIdentifier] = image
        return image
    }

    /// Deletes photos from the Photos library in one go. iOS asks the person to confirm once.
    func delete(_ assets: [PHAsset]) async throws {
        let ids = assets.map(\.localIdentifier)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
        identifiers.removeAll { ids.contains($0) }
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
