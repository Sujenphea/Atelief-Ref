//
//  CollectionStackCard.swift
//  AtelierRefs
//
//  009 · N4 — the Collections gallery card's "stack" preview: a Procreate-style
//  fanned pile of a collection's most-recent thumbnails, its name + count below.
//  Drawn in `CollectionsGalleryView` in place of the flat cover when the
//  collection has a fan preview. The fan tilt is SEEDED by the collection's UUID
//  so it is stable across refreshes (no jitter) — "random" only in appearance.
//

import AtelierCore
import SwiftUI

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

/// A Collections gallery card that draws a collection's recent thumbnails as a
/// fanned pile (009 · N4), sized to fill the adaptive gallery grid cell. Matches
/// ``CoverCard``'s outer chrome (padding, background, title) so the two read as
/// one grid; the fan replaces the single flat cover.
struct CollectionFanCard: View {
    let preview: CollectionStackPreview
    /// Resolve a blob hash to its on-disk thumbnail URL.
    let thumbnailURL: (String) -> URL?
    /// The protected Unsorted card, tinted like ``CoverCard``'s accent.
    var accent: Bool = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fan
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(preview.collection.name)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("\(preview.itemCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.controlBackgroundColor).opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The fanned pile: up to three thumbnails, back-to-front, each tilted by its
    /// seeded angle; the front (last) sits upright on top. A collection with no
    /// byte-backed items fans a single folder-glyph placeholder.
    private var fan: some View {
        GeometryReader { geo in
            let box = min(geo.size.width, geo.size.height)
            // The fanned tiles inset from the card so the outer tilts don't clip.
            let tile = box * 0.76
            let hashes = preview.recentBlobHashes
            let angles = fanRotations(seed: preview.collection.id, count: max(hashes.count, 1))
            ZStack {
                if hashes.isEmpty {
                    placeholder(side: tile)
                        .rotationEffect(.degrees(angles.first ?? 0))
                } else {
                    ForEach(Array(hashes.enumerated().reversed()), id: \.offset) { index, hash in
                        tile(hash: hash, side: tile)
                            // The front tile (index 0) rides on top with no tilt.
                            .rotationEffect(.degrees(index == 0 ? 0 : angles[index]))
                            .zIndex(Double(hashes.count - index))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func tile(hash: String, side: CGFloat) -> some View {
        AsyncThumbnail(
            hash: hash, url: thumbnailURL(hash), cornerRadius: 12,
            bucket: thumbnailPixelBucket(pointLongSide: side, scale: displayScale))
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.windowBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
    }

    private func placeholder(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(accent ? Color.accentColor.opacity(0.12) : Color(.quaternaryLabelColor).opacity(0.4))
            .overlay {
                Image(systemName: accent ? "tray" : "folder")
                    .font(.system(size: 30))
                    .foregroundStyle(accent ? Color.accentColor : .secondary)
            }
            .frame(width: side, height: side)
    }
}
