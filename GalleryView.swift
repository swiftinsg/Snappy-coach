//
//  GalleryView.swift
//  Grp 6pm Photo App
//

import SwiftUI
import Photos

/// Grid of every photo taken in the app. Tapping one opens it full screen.
struct GalleryView: View {
    let gallery: PhotoGallery
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

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
                                NavigationLink(value: asset) {
                                    GalleryThumbnail(asset: asset, gallery: gallery)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PHAsset.self) { asset in
                PhotoDetailView(asset: asset, gallery: gallery)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await gallery.load()
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
                    ShareLink(
                        item: Image(uiImage: image),
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
            try await gallery.delete(asset)
            dismiss()
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // The person tapped "Don't Allow" on the system confirmation; nothing to do.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
