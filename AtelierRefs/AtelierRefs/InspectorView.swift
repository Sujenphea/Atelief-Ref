//
//  InspectorView.swift
//  AtelierRefs
//
//  Chunk 4 (inspector) — the per-asset detail panel (build-order #7). Presented
//  as a native trailing `.inspector()` in ``LibraryView``. Shows a large preview,
//  the asset's intrinsic metadata, its provenance (platform / author / title /
//  original URL), and the always-reachable source actions (open source, open the
//  full-resolution blob, reveal in Finder, copy the source link).
//
//  All metadata comes from the already-loaded `CollectionItemDetail` — no new
//  read — so selecting an item never hits the database.
//

import AppKit
import AtelierCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: IngestionModel

    var body: some View {
        Group {
            if let detail = model.selectedItem {
                content(for: detail)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.right",
            description: Text("Select an image to see its details and source."))
    }

    // MARK: - Content

    private func content(for detail: CollectionItemDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                metadataSection(for: detail)
                provenanceSection(for: detail)
                actions(for: detail)
            }
            .padding()
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // No preview yet: still loading, or the tier can't be decoded.
                ProgressView()
            }
        }
        .frame(height: 240)
    }

    // MARK: - Metadata

    private func metadataSection(for detail: CollectionItemDetail) -> some View {
        let asset = detail.asset
        return section("Details") {
            row("Kind", asset.kind == .image ? "Image" : "Video")
            row("Dimensions", "\(asset.width) × \(asset.height)")
            row("Size", Self.formattedSize(asset.fileSize))
            row("Type", asset.mimeType)
            row("Captured", Self.formattedDate(asset.createdAt))
        }
    }

    // MARK: - Provenance

    private func provenanceSection(for detail: CollectionItemDetail) -> some View {
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

    private func actions(for detail: CollectionItemDetail) -> some View {
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
