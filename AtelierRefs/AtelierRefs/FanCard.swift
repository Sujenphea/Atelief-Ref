//
//  FanCard.swift
//  AtelierRefs
//
//  009 · N4 — the Home overview card's "stack" preview: a Procreate-style fanned
//  pile of an entity's most-recent thumbnails, its name + count below. Shared by
//  the Collections and Spaces sections of `CollectionsGalleryView` (both draw the
//  same card from their respective `…StackPreview`). The fan tilt is SEEDED by the
//  entity's UUID so it is stable across refreshes (no jitter) — "random" only in
//  appearance.
//

import SwiftUI

/// Deterministic per-layer fan tilts (degrees, within ±`maxDegrees`) derived from
/// an entity's UUID (009 · N4). PURE and process-stable: it reads the raw uuid
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

/// A Home overview card that draws an entity's recent thumbnails as a fanned pile
/// (009 · N4), sized to fill the adaptive gallery grid cell. Matches ``CoverCard``'s
/// outer chrome (padding, background, title) so collections and spaces read as one
/// grid; the fan replaces the single flat cover. Entity-agnostic — the caller
/// supplies the title, count, seed, and hashes, so both the Collections and Spaces
/// sections share this one view.
struct FanCard: View {
    let title: String
    let itemCount: Int
    /// The entity's id — seeds the deterministic fan tilt.
    let seed: UUID
    /// Newest-first thumbnail hashes; empty ⇒ a single placeholder tile.
    let recentBlobHashes: [String]
    /// Resolve a blob hash to its on-disk thumbnail URL.
    let thumbnailURL: (String) -> URL?
    /// Tint the placeholder (the protected Unsorted collection).
    var accent: Bool = false
    /// SF Symbol for the empty placeholder tile (folder vs board glyph).
    var placeholderSymbol: String = "folder"

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fan
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("\(itemCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.controlBackgroundColor).opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The fanned pile: up to three thumbnails, back-to-front, each tilted by its
    /// seeded angle; the front (last) sits upright on top. No byte-backed items ⇒
    /// a single glyph placeholder.
    private var fan: some View {
        GeometryReader { geo in
            // The fanned tiles inset from the card so the outer tilts don't clip.
            let side = min(geo.size.width, geo.size.height) * 0.76
            fanStack(side: side)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func fanStack(side: CGFloat) -> some View {
        let angles = fanRotations(seed: seed, count: max(recentBlobHashes.count, 1))
        ZStack {
            if recentBlobHashes.isEmpty {
                placeholder(side: side)
                    .rotationEffect(.degrees(angles.first ?? 0))
            } else {
                ForEach(Array(recentBlobHashes.enumerated().reversed()), id: \.offset) { index, hash in
                    tile(hash: hash, side: side)
                        // The front tile (index 0) rides on top with no tilt.
                        .rotationEffect(.degrees(index == 0 ? 0 : angles[index]))
                        .zIndex(Double(recentBlobHashes.count - index))
                }
            }
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
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 30))
                    .foregroundStyle(accent ? Color.accentColor : .secondary)
            }
            .frame(width: side, height: side)
    }
}
