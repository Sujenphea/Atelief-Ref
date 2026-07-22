//
//  CollectionStackCard.swift
//  AtelierRefs
//
//  009 · N4 — the Unsorted screen's "collection stack" drop target: a Procreate-
//  style fanned pile of a collection's most-recent thumbnails, its name + count
//  below, and a drop target that MOVES (⌥ copies) the dragged selection into that
//  collection. The fan tilt is SEEDED by the collection's UUID so it is stable
//  across refreshes (no jitter) — "random" only in appearance.
//

import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// Deterministic per-layer fan tilts (degrees, within ±`maxDegrees`) derived from
/// a collection's UUID (009 · N4). PURE and process-stable: it reads the raw uuid
/// bytes, NOT `hashValue` (whose seed varies per process and would re-jitter the
/// fan every launch). Same seed + count → same angles, every time.
func fanRotations(seed: UUID, count: Int, maxDegrees: Double = 8) -> [Double] {
    guard count > 0 else { return [] }
    let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }   // 16 bytes
    return (0..<count).map { i in
        let byte = bytes[(i * 5 + 3) % bytes.count]            // deterministic pick
        let unit = Double(byte) / 255.0                        // 0...1
        return (unit * 2 - 1) * maxDegrees                     // -max...+max
    }
}

struct CollectionStackCard: View {
    let preview: CollectionStackPreview
    /// Resolve a blob hash to its on-disk 512-tier thumbnail URL.
    let thumbnailURL: (String) -> URL?
    /// Highlighted because a drag is hovering (the Procreate "drop here" cue).
    var isTargeted: Bool = false

    @Environment(\.displayScale) private var displayScale

    private static let side: CGFloat = 92

    var body: some View {
        VStack(spacing: 6) {
            fan
                .frame(width: Self.side, height: Self.side)
                .scaleEffect(isTargeted ? 1.06 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
            Text(preview.collection.name)
                .font(.caption).fontWeight(.medium)
                .lineLimit(1)
            Text("\(preview.itemCount)")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 112)
        .padding(.vertical, 4)
    }

    /// The fanned pile: up to three thumbnails, back-to-front, each tilted by its
    /// seeded angle; the front (last) sits uprightish on top. An empty collection
    /// fans a single folder-glyph placeholder.
    @ViewBuilder
    private var fan: some View {
        let hashes = preview.recentBlobHashes
        let angles = fanRotations(seed: preview.collection.id, count: max(hashes.count, 1))
        ZStack {
            if hashes.isEmpty {
                placeholder
                    .rotationEffect(.degrees(angles.first ?? 0))
            } else {
                ForEach(Array(hashes.enumerated().reversed()), id: \.offset) { index, hash in
                    tile(hash: hash)
                        // The front tile (index 0) rides on top with the least tilt.
                        .rotationEffect(.degrees(index == 0 ? 0 : angles[index]))
                        .zIndex(Double(hashes.count - index))
                }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func tile(hash: String) -> some View {
        // 92 pt → 184 px at 2× → the 192 bucket. The `scaleEffect(1.06)` drop cue
        // is transient and well inside the round-up headroom, so it doesn't
        // warrant the next bucket up.
        AsyncThumbnail(
            hash: hash, url: thumbnailURL(hash), isSelected: false, cornerRadius: 10,
            bucket: thumbnailPixelBucket(pointLongSide: Self.side, scale: displayScale))
            .frame(width: Self.side, height: Self.side)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.windowBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "folder")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.side, height: Self.side)
    }
}

/// A stack card wired as a drop target (009 · N4): owns its own `isTargeted`
/// state (so only the hovered card scales), moves/copies the dragged payload on
/// drop, and navigates into the collection on a plain click.
struct StackDropTarget: View {
    let preview: CollectionStackPreview
    let thumbnailURL: (String) -> URL?
    let onNavigate: () -> Void
    /// Route + apply the drop; returns whether it was accepted.
    let onDrop: (AssetDragPayload) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Button(action: onNavigate) {
            CollectionStackCard(
                preview: preview, thumbnailURL: thumbnailURL, isTargeted: isTargeted)
        }
        .buttonStyle(.plain)
        .help("Move here — hold ⌥ to copy")
        // `.onDrop` (not `.dropDestination`) so the AppKit grid's NSDraggingSession
        // is actually recognised — the Transferable bridge silently never was.
        .onDrop(of: [.assetIDs], isTargeted: $isTargeted) { providers in
            AssetDragPayload.fromDrop(providers) { _ = onDrop($0) }
        }
    }
}
