//
//  CollectionDropRail.swift
//  AtelierRefs
//
//  009 · N5 — the floating drop rail shown on every collection screen EXCEPT
//  Unsorted (which has the stack row; one screen, one metaphor). Pinned to the
//  trailing edge, always visible but MINIMIZED (a column of tiny covers). A drag
//  approaching the rail expands it into named drop rows; each row moves (⌥ copies)
//  the selection into that collection. With no drag in flight, clicking a row
//  NAVIGATES — the rail doubles as quick-switch.
//
//  Proximity without a separate gesture strip (009 · 3A): the rail's OWN footprint
//  is the drop-proximity target — an outer `dropDestination` whose `isTargeted`
//  flips the expanded state, with the per-row targets taking the real drop. No
//  transparent full-height overlay, so trailing grid cells keep their clicks.
//

import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

struct CollectionDropRail: View {
    let targets: MoveTargets
    /// The collection's cover blob hash, if one is known (nil → folder glyph).
    let coverHash: (UUID) -> String?
    /// Resolve a blob hash to its on-disk thumbnail URL.
    let thumbnailURL: (String) -> URL?
    let onNavigate: (UUID) -> Void
    /// Route + apply a drop onto `collectionID`; returns whether it was accepted.
    let onDrop: (AssetDragPayload, _ collectionID: UUID) -> Bool

    @State private var isExpanded = false
    @State private var targetedRow: UUID?
    @Environment(\.displayScale) private var displayScale

    private static let miniWidth: CGFloat = 44
    private static let expandedWidth: CGFloat = 220
    private static let coverSide: CGFloat = 30

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                if !targets.subfolders.isEmpty {
                    ForEach(targets.subfolders) { row(for: $0) }
                    if !targets.roots.isEmpty { divider }
                }
                ForEach(targets.roots) { row(for: $0) }
            }
            .padding(6)
        }
        .frame(width: isExpanded ? Self.expandedWidth : Self.miniWidth)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, x: -1, y: 2)
        .padding(.trailing, 10)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
        // Proximity trigger (3A): a drag anywhere over the rail expands it; the
        // per-row targets below take the actual drop. Accepts nothing itself (a
        // drop on the rail's padding, not a row, is refused). `.onDrop` (not
        // `.dropDestination`) so the AppKit grid drag is recognised at all.
        .onDrop(of: [.assetIDs], isTargeted: Binding(
            get: { isExpanded },
            set: { over in
                isExpanded = over
                if !over { targetedRow = nil }
            })) { _ in false }
    }

    private var divider: some View {
        Divider().padding(.vertical, 2).opacity(isExpanded ? 1 : 0.4)
    }

    @ViewBuilder
    private func row(for collection: Collection) -> some View {
        Button { onNavigate(collection.id) } label: {
            HStack(spacing: 8) {
                cover(collection.id)
                if isExpanded {
                    Text(collection.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(targetedRow == collection.id
                        ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Move here — hold ⌥ to copy" : collection.name)
        .onDrop(of: [.assetIDs], isTargeted: Binding(
            get: { targetedRow == collection.id },
            set: { over in
                targetedRow = over ? collection.id : (targetedRow == collection.id ? nil : targetedRow)
            })) { providers in
            AssetDragPayload.fromDrop(providers) { payload in
                _ = onDrop(payload, collection.id)
                targetedRow = nil
            }
        }
    }

    private func cover(_ id: UUID) -> some View {
        Group {
            if let hash = coverHash(id) {
                // 30 pt → 60 px at 2× → the 128 bucket (036 §4 C3). This was the
                // most wasteful site under the old cache: a full 512 px bitmap
                // for a 30 pt swatch, ~16× the pixels it can possibly show.
                AsyncThumbnail(
                    hash: hash, url: thumbnailURL(hash), isSelected: false, cornerRadius: 6,
                    bucket: thumbnailPixelBucket(
                        pointLongSide: Self.coverSide, scale: displayScale))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: id == Collection.unsortedID ? "tray" : "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: Self.coverSide, height: Self.coverSide)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
