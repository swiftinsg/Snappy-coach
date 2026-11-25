//
//  GalleryView.swift
//  Grp 6pm Photo App
//

import SwiftUI
import Photos

/// Grid of every photo taken in the app, split by the mode each was practised in. Chips along the
/// top show one mode at a time. Tapping a photo opens it full screen; "Select" lets the person
/// tick several photos to share or delete together.
struct GalleryView: View {
    let gallery: PhotoGallery
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isSelecting = false
    /// Identifiers of the ticked photos.
    @State private var selection: Set<String> = []
    @State private var errorMessage: String?
    /// The photo opened full screen, if any.
    @State private var path: [PHAsset] = []
    /// The mode the grid is showing, or nil for all of them.
    @State private var filter: AdviceTopic?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var selectedAssets: [PHAsset] {
        gallery.assets.filter { selection.contains($0.localIdentifier) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !gallery.hasAccess {
                    ContentUnavailableView {
                        Label("No Access to Photos", systemImage: "lock")
                    } description: {
                        Text("Allow Photos access in Settings to see the photos you've taken.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if gallery.assets.isEmpty && gallery.hiddenCount > 0 {
                    // Limited access is hiding every photo taken here; they're kept, just not visible.
                    ContentUnavailableView {
                        Label("Photos Hidden", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Photos access is limited, so \(hiddenPhotosText) taken here can't be shown. Choose them, or allow full access.")
                    } actions: {
                        limitedAccessButtons
                    }
                } else if gallery.assets.isEmpty {
                    // Prompts the first photo: back to the camera, where the coach helps take it.
                    ContentUnavailableView {
                        Label("No Photos Yet", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Photos you take in this app will appear here, along with what the coach told you.")
                    } actions: {
                        Button("Take a Photo", systemImage: "camera") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        // Headers stay pinned while scrolling everything, so it's clear which mode you're in.
                        LazyVGrid(columns: columns, spacing: 2, pinnedViews: filter == nil ? [.sectionHeaders] : []) {
                            ForEach(gallery.sections(filter: filter)) { section in
                                Section {
                                    ForEach(section.assets, id: \.localIdentifier) { asset in
                                        gridItem(for: asset)
                                    }
                                } header: {
                                    if filter == nil {
                                        sectionHeader(section)
                                    }
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            if gallery.hiddenCount > 0 {
                                limitedAccessBanner
                            }
                            // Only worth showing once some photos have a mode to filter by.
                            if !gallery.countsByTopic.isEmpty {
                                filterChips
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PHAsset.self) { asset in
                PhotoDetailView(asset: asset, gallery: gallery) { topic in
                    // "See all <mode> photos": back to the grid, showing that mode.
                    filter = topic
                    path.removeAll()
                }
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
        // Drop ticks for photos that no longer exist, and a filter whose last photo was deleted.
        .onChange(of: gallery.assets) {
            selection.formIntersection(gallery.assets.map(\.localIdentifier))
            if let filter, gallery.countsByTopic[filter] == nil {
                self.filter = nil
            }
        }
        .animation(.snappy, value: filter)
    }

    private var hiddenPhotosText: String {
        gallery.hiddenCount == 1 ? "1 photo" : "\(gallery.hiddenCount) photos"
    }

    /// Says some photos are hidden by limited Photos access, with ways to show them.
    private var limitedAccessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Limited Photos access: \(hiddenPhotosText) hidden", systemImage: "photo.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
            HStack {
                limitedAccessButtons
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var limitedAccessButtons: some View {
        Button("Choose Photos") {
            Task { await gallery.chooseMorePhotos() }
        }
        .buttonStyle(.borderedProminent)
        Button("Allow Full Access") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .buttonStyle(.bordered)
    }

    /// "All", then one chip per mode that has photos, each with how many.
    private var filterChips: some View {
        let counts = gallery.countsByTopic
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(title: "All", systemImage: nil, count: gallery.assets.count, isSelected: filter == nil) {
                    filter = nil
                }
                ForEach(AdviceTopic.allCases.filter { counts[$0] != nil }) { topic in
                    chip(title: topic.displayTitle, systemImage: topic.systemImage, count: counts[topic] ?? 0, isSelected: filter == topic) {
                        filter = topic
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(title: String, systemImage: String?, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.black.opacity(0.6) : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? .black : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(isSelected ? .regular.tint(.yellow).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) photos")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sectionHeader(_ section: GallerySection) -> some View {
        HStack(spacing: 6) {
            if let topic = section.topic {
                Image(systemName: topic.systemImage)
            }
            Text(section.title)
            Text("· \(section.assets.count)")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.headline)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityAddTraits(.isHeader)
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
    /// One button for both, so the thumbnail (and its loaded image) stays put when Select is tapped.
    private func gridItem(for asset: PHAsset) -> some View {
        let isSelected = isSelecting && selection.contains(asset.localIdentifier)
        return Button {
            if isSelecting {
                toggle(asset)
            } else {
                path.append(asset)
            }
        } label: {
            GalleryThumbnail(asset: asset, gallery: gallery)
                .overlay {
                    if isSelected {
                        Color.white.opacity(0.25)
                    }
                }
                // In "All", every mode the photo was improved in, so it's clear even mid-scroll.
                .overlay(alignment: .topLeading) {
                    if filter == nil, let topics = gallery.record(for: asset)?.topics, !topics.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(topics) { topic in
                                Image(systemName: topic.systemImage)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: .capsule)
                        .padding(5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(topics.map(\.title).formatted(.list(type: .and)))
                    }
                }
                // The coach said this shot was ready in the mode it's filed under.
                .overlay(alignment: .topTrailing) {
                    if !isSelecting, gallery.record(for: asset)?.filedWasReady == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(5)
                            .accessibilityLabel("Ready shot")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : .clear)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    /// True once the sharp thumbnail is showing, rather than Photos' quick preview.
    @State private var isSharp: Bool

    init(asset: PHAsset, gallery: PhotoGallery) {
        self.asset = asset
        self.gallery = gallery
        // Never start grey: use the thumbnail loaded ahead of time, or Photos' instant preview.
        let cached = gallery.hasThumbnail(for: asset)
        _image = State(initialValue: gallery.instantThumbnail(for: asset))
        _isSharp = State(initialValue: cached)
    }

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
                guard !isSharp else { return }
                if let sharp = await gallery.thumbnail(for: asset) {
                    image = sharp
                    isSharp = true
                }
            }
            .accessibilityLabel(Text("Photo, \(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")"))
    }
}

/// One photo shown full screen, with Share and Delete in the bottom toolbar.
struct PhotoDetailView: View {
    let asset: PHAsset
    let gallery: PhotoGallery
    /// Goes back to the grid showing only this mode's photos.
    var onShowMode: (AdviceTopic) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var errorMessage: String?
    /// True once the high-resolution copy for zooming has been asked for, so it's only loaded once.
    @State private var hasLoadedFullSize = false
    /// The story card over the bottom of the photo: how it was made and what the coach said.
    @State private var isStoryShown = false
    /// How far the story card is being dragged down, while the finger is down.
    @State private var storyDrag: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image {
                ZoomableImage(image: image) { isZoomed in
                    if isZoomed {
                        loadFullSize()
                        // Zooming in is about the photo, so the card steps aside.
                        isStoryShown = false
                    }
                }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if isStoryShown {
                storyCard
                    .offset(y: max(storyDrag, 0))
                    .gesture(
                        DragGesture()
                            .onChanged { storyDrag = $0.translation.height }
                            .onEnded { value in
                                if value.translation.height > 60 || value.predictedEndTranslation.height > 180 {
                                    isStoryShown = false
                                }
                                storyDrag = 0
                            }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isStoryShown)
        .animation(.snappy, value: storyDrag == 0)
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
                Button("Story", systemImage: isStoryShown ? "info.circle.fill" : "info.circle") {
                    isStoryShown.toggle()
                }
                .accessibilityLabel(isStoryShown ? "Hide photo story" : "Show photo story")
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

    /// How the photo was made: the mode, what the coach said, what was fixed and what it liked.
    private var storyCard: some View {
        // As tall as the story needs, scrolling only if it's longer than the space allowed.
        ViewThatFits(in: .vertical) {
            storyContent
            ScrollView { storyContent }
        }
        .frame(maxHeight: 360)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var storyContent: some View {
        if let record = gallery.record(for: asset) {
            PhotoStory(record: record, onShowMode: onShowMode)
        } else {
            Text("Taken before shot stories were saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Zooming in shows more detail than the screen-sized copy has, so swap in a bigger one.
    private func loadFullSize() {
        guard !hasLoadedFullSize else { return }
        hasLoadedFullSize = true
        Task {
            if let full = await gallery.image(for: asset, size: CGSize(width: 2400, height: 2400), contentMode: .aspectFit) {
                image = full
            }
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

/// The inside of the story card. Sections with nothing to say are left out.
private struct PhotoStory: View {
    let record: ShotRecord
    let onShowMode: (AdviceTopic) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(record.topics.isEmpty ? "Photo" : record.topics.map(\.displayTitle).joined(separator: " · "))
                } icon: {
                    Image(systemName: record.filedTopic?.systemImage ?? "camera")
                }
                .font(.headline)
                if let scene = record.scene {
                    Text(scene)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // One mode reads as before; several get a block each, in shooting order.
            let results = record.results
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                modeBlock(result, showsTitle: results.count > 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func modeBlock(_ result: ModeResult, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Label {
                    Text(([result.topic?.displayTitle ?? "Earlier mode"] + [result.styles.map(\.keptTogether).formatted(.list(type: .and))].filter { !$0.isEmpty })
                        .joined(separator: " · "))
                } icon: {
                    Image(systemName: result.topic?.systemImage ?? "camera")
                }
                .font(.subheadline.weight(.bold))
            } else if !result.styles.isEmpty {
                Text(result.styles.map(\.keptTogether).formatted(.list(type: .and)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if result.wasReady {
                Label {
                    Text(showsTitle ? "Coach said this was ready" : "Coach said this shot was ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                }
                .font(.subheadline.weight(.semibold))
            } else if result.topicID == record.topicID, let suggestion = record.suggestion {
                // Only the mode at the shutter had a tip showing.
                Label {
                    Text("Coach was still suggesting: \(suggestion)")
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                }
                .font(.subheadline)
            }

            list("You fixed", result.fixed)
            list("Coach liked", result.praised)

            if let topic = result.topic {
                Button {
                    onShowMode(topic)
                } label: {
                    HStack {
                        Text("See all \(topic.displayTitle) photos")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(showsTitle ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(showsTitle ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ForEach(items, id: \.self) { item in
                    Label {
                        // Stored lower-case to fit the coach's sentences; capitalised for a list.
                        Text(item.prefix(1).uppercased() + item.dropFirst())
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// A photo that can be pinched to zoom, dragged around while zoomed, and double-tapped to zoom in or out.
private struct ZoomableImage: View {
    let image: UIImage
    /// Called when the photo is zoomed in or back out to normal size.
    var onZoomChange: (Bool) -> Void = { _ in }

    private let maxScale: CGFloat = 5
    private let doubleTapScale: CGFloat = 2.5

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    // Where the current gesture started from.
    @State private var startScale: CGFloat = 1
    @State private var startOffset: CGSize = .zero
    @State private var isPinching = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(offset)
                // The gestures sit on the untransformed frame, so finger positions are in screen terms.
                .contentShape(.rect)
                .gesture(magnify(in: size))
                // Dragging only pans while zoomed in, so the back swipe still works at normal size.
                .simultaneousGesture(pan(in: size), including: scale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { location in
                    withAnimation(.snappy) {
                        if scale > 1 {
                            reset()
                        } else {
                            zoom(to: doubleTapScale, around: location, in: size, from: 1, offset: .zero)
                            commit()
                        }
                    }
                }
                .accessibilityLabel("Photo")
                .accessibilityZoomAction { action in
                    withAnimation(.snappy) {
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let target = action.direction == .zoomIn ? scale * 1.5 : scale / 1.5
                        zoom(to: target, around: center, in: size, from: scale, offset: offset)
                        commit()
                    }
                }
        }
        .onChange(of: scale > 1) { _, isZoomed in
            onZoomChange(isZoomed)
        }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                zoom(to: startScale * value.magnification, around: value.startLocation, in: size, from: startScale, offset: startOffset)
            }
            .onEnded { _ in
                isPinching = false
                withAnimation(.snappy) {
                    if scale <= 1.02 { reset() } else { commit() }
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isPinching else { return }
                offset = clamped(
                    CGSize(width: startOffset.width + value.translation.width, height: startOffset.height + value.translation.height),
                    scale: scale, in: size
                )
            }
            .onEnded { _ in
                guard !isPinching else { return }
                startOffset = offset
            }
    }

    /// Zooms so the point under `location` stays under the finger.
    private func zoom(to target: CGFloat, around location: CGPoint, in size: CGSize, from base: CGFloat, offset baseOffset: CGSize) {
        // A little give past the limits while pinching; it settles back on release.
        let newScale = min(max(target, 0.8), maxScale)
        let point = CGSize(width: location.x - size.width / 2, height: location.y - size.height / 2)
        let ratio = newScale / max(base, 0.01)
        let moved = CGSize(
            width: point.width - (point.width - baseOffset.width) * ratio,
            height: point.height - (point.height - baseOffset.height) * ratio
        )
        scale = newScale
        offset = clamped(moved, scale: newScale, in: size)
    }

    /// Keeps the zoomed photo covering the screen, so it can't be dragged off into the black.
    private func clamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let aspect = image.size.width / max(image.size.height, 1)
        let fitted = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let maxY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    /// The current zoom becomes the starting point for the next gesture.
    private func commit() {
        scale = min(max(scale, 1), maxScale)
        startScale = scale
        startOffset = offset
    }

    private func reset() {
        scale = 1
        offset = .zero
        startScale = 1
        startOffset = .zero
    }
}
