//
//  GalleryView.swift
//  Grp 6pm Photo App
//

import SwiftUI
import Photos

/// Grid of every photo taken in the app. Tapping one opens it full screen; "Select"
/// lets the person tick several photos to share or delete together.
struct GalleryView: View {
    let gallery: PhotoGallery
    @Environment(\.dismiss) private var dismiss

    @State private var isSelecting = false
    /// Identifiers of the ticked photos.
    @State private var selection: Set<String> = []
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var selectedAssets: [PHAsset] {
        gallery.assets.filter { selection.contains($0.localIdentifier) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !gallery.hasAccess {
                    ContentUnavailableView(
                        "No Access to Photos",
                        systemImage: "lock",
                        description: Text("Allow Photos access in Settings to see the photos you've taken.")
                    )
                } else if gallery.assets.isEmpty {
                    ContentUnavailableView(
                        "No Photos Yet",
                        systemImage: "photo.on.rectangle",
                        description: Text("Photos you take in this app will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(gallery.assets, id: \.localIdentifier) { asset in
                                gridItem(for: asset)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PHAsset.self) { asset in
                PhotoDetailView(asset: asset, gallery: gallery)
            }
            .toolbar { toolbarContent }
            .alert(
                "Couldn't Delete Photos",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            await gallery.load()
        }
        // Drop ticks for photos that no longer exist.
        .onChange(of: gallery.assets) {
            selection.formIntersection(gallery.assets.map(\.localIdentifier))
        }
    }

    private var title: String {
        guard isSelecting else { return "Gallery" }
        switch selection.count {
        case 0: return "Select Photos"
        case 1: return "1 Photo Selected"
        default: return "\(selection.count) Photos Selected"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    endSelecting()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                ShareLink(items: selection.sorted().map(SharedPhoto.init(assetIdentifier:))) { _ in
                    SharePreview("Photo")
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await deleteSelected() }
                }
                .disabled(selection.isEmpty)
            }
        } else {
            if !gallery.assets.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select") {
                        isSelecting = true
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    /// While selecting, a tap ticks the photo; otherwise it opens the photo.
    @ViewBuilder
    private func gridItem(for asset: PHAsset) -> some View {
        if isSelecting {
            let isSelected = selection.contains(asset.localIdentifier)
            Button {
                toggle(asset)
            } label: {
                GalleryThumbnail(asset: asset, gallery: gallery)
                    .overlay {
                        if isSelected {
                            Color.white.opacity(0.25)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : .clear)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: asset) {
                GalleryThumbnail(asset: asset, gallery: gallery)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ asset: PHAsset) {
        if selection.contains(asset.localIdentifier) {
            selection.remove(asset.localIdentifier)
        } else {
            selection.insert(asset.localIdentifier)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    private func deleteSelected() async {
        do {
            try await gallery.delete(selectedAssets)
            endSelecting()
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // The person tapped "Don't Allow" on the system confirmation; keep their selection.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Square, cropped thumbnail for one photo in the grid.
private struct GalleryThumbnail: View {
    let asset: PHAsset
    let gallery: PhotoGallery
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .contentShape(.rect)
            .task(id: asset.localIdentifier) {
                image = await gallery.image(for: asset, size: CGSize(width: 140, height: 140))
            }
            .accessibilityLabel(Text("Photo, \(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")"))
    }
}

/// One photo shown full screen, with Share and Delete in the bottom toolbar.
struct PhotoDetailView: View {
    let asset: PHAsset
    let gallery: PhotoGallery
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Photo")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                if let image {
                    // Shares the full-resolution original, not the on-screen preview.
                    ShareLink(
                        item: SharedPhoto(assetIdentifier: asset.localIdentifier),
                        preview: SharePreview("Photo", image: Image(uiImage: image))
                    )
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await delete() }
                }
            }
        }
        .alert(
            "Couldn't Delete Photo",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            image = await gallery.image(for: asset, size: CGSize(width: 1200, height: 1200), contentMode: .aspectFit)
        }
    }

    private func delete() async {
        do {
            try await gallery.delete([asset])
            dismiss()
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // The person tapped "Don't Allow" on the system confirmation; nothing to do.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
