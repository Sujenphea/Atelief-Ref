//
//  ItemDetailView.swift
//  AtelierRefs
//
//  The full-window detail page for a single library item (replaces the old
//  trailing `.inspector()` panel). Clicking a grid cell in ``LibraryView`` opens
//  this over the whole Library tab: the media fills most of the width — a
//  full-resolution image, or an inline `VideoPlayer` for video — with the item's
//  metadata / provenance / source actions docked on the right (ported from the
//  former `InspectorView`).
//
//  The current item is read from `model.selectedItem`, so ← / → prev-next just
//  call `model.select` and reuse the app's centralized selection; the media is
//  (re)loaded off-main whenever `selectedItemID` changes.
//

import AVKit
import AppKit
import AtelierCore
import SwiftUI

struct ItemDetailView: View {
    @ObservedObject var model: IngestionModel
    /// Dismiss the page back to the grid (Back button / Escape).
    let onClose: () -> Void

    /// The full-resolution decoded image (image assets only), loaded off-main.
    @State private var fullImage: NSImage?
    /// The inline player (video assets only), rebuilt when the item changes.
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.selectedItem {
                topBar(for: detail)
                Divider()
                HStack(spacing: 0) {
                    mediaArea(for: detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    DetailSidebar(model: model, detail: detail)
                        .frame(width: 300)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // Reload media whenever the selected item changes (open + prev/next).
        .task(id: model.selectedItemID) { await loadMedia() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Top bar

    private func topBar(for detail: CollectionItemDetail) -> some View {
        let index = currentIndex
        let count = model.items.count
        return HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled((index ?? 0) <= 0)

            Text(index.map { "\($0 + 1) / \(count)" } ?? "—")
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled((index ?? 0) >= count - 1)

            Spacer()

            Text(detail.source.title ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding()
    }

    // MARK: - Media

    @ViewBuilder
    private func mediaArea(for detail: CollectionItemDetail) -> some View {
        Group {
            switch detail.asset.kind {
            case .video:
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            case .image:
                // Show the already-loaded 1280 preview instantly, then swap to
                // the full-resolution decode when it lands.
                if let image = fullImage ?? model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
        }
        .padding()
    }

    /// Decode the full-resolution image off-main, or build the video player, for
    /// the currently-selected item. No caching — full-res images are large, so we
    /// decode on demand and drop the previous one on navigation.
    private func loadMedia() async {
        fullImage = nil
        player?.pause()
        player = nil
        guard let detail = model.selectedItem,
              let url = model.blobURL(for: detail) else { return }
        switch detail.asset.kind {
        case .video:
            player = AVPlayer(url: url)
        case .image:
            let targetID = detail.item.id
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            // Publish only if this item is still on screen.
            if model.selectedItemID == targetID {
                fullImage = image
            }
        }
    }

    // MARK: - Prev / next

    /// Index of the selected item within the folder's `items`, or `nil`.
    private var currentIndex: Int? {
        guard let id = model.selectedItemID else { return nil }
        return model.items.firstIndex { $0.item.id == id }
    }

    /// Step the selection by `delta` (clamped to the folder), reusing the app's
    /// centralized `select` (which also refreshes the 1280 preview placeholder).
    private func step(_ delta: Int) {
        guard let index = currentIndex else { return }
        let target = index + delta
        guard model.items.indices.contains(target) else { return }
        model.select(model.items[target])
    }
}

/// The right-hand details column: metadata, provenance, and source actions for a
/// single item — ported verbatim from the former `InspectorView` (minus the small
/// preview, since the media is shown large on the left).
private struct DetailSidebar: View {
    @ObservedObject var model: IngestionModel
    let detail: CollectionItemDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection
                provenanceSection
                actions
            }
            .padding()
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        let asset = detail.asset
        return section("Details") {
            row("Kind", asset.kind == .image ? "Image" : "Video")
            row("Dimensions", "\(asset.width) × \(asset.height)")
            if asset.kind == .video, let duration = asset.duration {
                row("Duration", Self.formattedDuration(duration))
            }
            row("Size", Self.formattedSize(asset.fileSize))
            row("Type", asset.mimeType)
            row("Captured", Self.formattedDate(asset.createdAt))
        }
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        let source = detail.source
        return section("Source") {
            row("Platform", Self.platformLabel(source.platform))
            if let name = source.authorName, !name.isEmpty {
                row("Author", name)
            }
            if let handle = source.authorHandle, !handle.isEmpty {
                row("Handle", handle)
            }
            if let title = source.title, !title.isEmpty {
                row("Title", title)
            }
            if let url = source.originalURL, !url.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original URL").foregroundStyle(.secondary).font(.callout)
                    Text(url)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            } else {
                row("Original URL", "—")
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        let hasSource = !(detail.source.originalURL ?? "").isEmpty
        return VStack(spacing: 8) {
            Button {
                model.openSource(detail)
            } label: {
                Label("Open Original Source", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!hasSource)

            Button {
                model.openBlob(detail)
            } label: {
                Label("Open Full Resolution", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }

            Button {
                model.revealInFinder(detail)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }

            Button {
                model.copySourceLink(detail)
            } label: {
                Label("Copy Source Link", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!hasSource)

            Divider().padding(.vertical, 2)

            // Membership-only (reversible) vs library-wide (destructive) delete.
            Button {
                model.removeFromFolder(assetIDs: [detail.asset.id])
            } label: {
                Label("Remove from Folder", systemImage: "minus.circle")
                    .frame(maxWidth: .infinity)
            }

            Button(role: .destructive) {
                model.requestDelete(assetIDs: [detail.asset.id])
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    // MARK: - Building blocks

    private func section(
        _ title: String, @ViewBuilder _ rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            rows()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - Formatting

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `m:ss` for a video's playback duration (seconds).
    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A human-facing label for a capture platform.
    private static func platformLabel(_ platform: Platform) -> String {
        switch platform {
        case .twitter: "Twitter / X"
        case .pinterest: "Pinterest"
        case .instagram: "Instagram"
        case .cosmos: "Cosmos"
        case .web: "Web"
        case .localPaste: "Pasted"
        case .localDrag: "Dragged in"
        }
    }
}
