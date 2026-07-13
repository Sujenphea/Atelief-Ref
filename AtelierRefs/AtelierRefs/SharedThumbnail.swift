//
//  SharedThumbnail.swift
//  AtelierRefs
//
//  Thumbnail loading shared by the collection grid, the Collections gallery, and
//  the Spaces list (004-P1/P2, 005-E2). Extracted from the old `LibraryView` so
//  every surface decodes off the main render path via one process-wide cache.
//

import AppKit
import SwiftUI

/// A process-wide, thread-safe cache of decoded thumbnails, keyed by blob hash.
/// The synchronous `cached(_:)` hit is read on the main render path; the disk
/// read + decode in `load(hash:url:)` run OFF the main thread and populate the
/// cache — so scrolling a large grid never blocks the UI on `NSImage(contentsOf:)`
/// I/O. Returning nothing from `load` keeps any non-Sendable `NSImage` from
/// crossing an isolation boundary; the caller re-reads via `cached`.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 512 }

    /// A synchronous cache hit (NSCache is thread-safe), or nil if not yet loaded.
    func cached(_ hash: String) -> NSImage? { cache.object(forKey: hash as NSString) }

    /// Read + decode the thumbnail off the main thread and store it under `hash`.
    func load(hash: String, url: URL) async {
        if cache.object(forKey: hash as NSString) != nil { return }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return }
        cache.setObject(image, forKey: hash as NSString)
    }
}

/// Loads a thumbnail's image asynchronously via ``ThumbnailCache``, so the grid
/// never decodes on the main render path. Shows a cached image immediately;
/// otherwise a placeholder while it loads off-main, keyed by `hash` so cell reuse
/// (scrolling) reloads for the new item.
struct AsyncThumbnail: View {
    let hash: String
    let url: URL?
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        ThumbnailTile(image: image, isSelected: isSelected, cornerRadius: cornerRadius)
            .task(id: hash) {
                if let hit = ThumbnailCache.shared.cached(hash) {
                    image = hit
                    return
                }
                image = nil
                guard let url else { return }
                await ThumbnailCache.shared.load(hash: hash, url: url)
                image = ThumbnailCache.shared.cached(hash)
            }
    }
}

/// One square thumbnail cell — the loaded image, or a placeholder tile. A
/// selection ring marks the item currently selected.
struct ThumbnailTile: View {
    let image: NSImage?
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        // A square cell sized by the adaptive column, not a fixed frame — a fixed
        // size overflowed narrow columns and overlapped neighbors. `Color.clear`
        // adopts the column width; the overlay fills and is clipped to it.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A cover card for the Collections gallery / Spaces list: a large square cover
/// thumbnail (or an SF-symbol placeholder) with a title and optional subtitle
/// beneath. Tapping is handled by the caller wrapping this in a `Button`.
struct CoverCard: View {
    let title: String
    var subtitle: String?
    /// The cover asset's blob hash + on-disk thumbnail URL, if the entity has one.
    var coverHash: String?
    var coverURL: URL?
    /// SF Symbol drawn when there is no cover (folder vs board).
    var placeholderSymbol: String = "folder"
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let coverHash {
                    AsyncThumbnail(hash: coverHash, url: coverURL, cornerRadius: 12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent ? Color.accentColor.opacity(0.12) : Color(.quaternaryLabelColor).opacity(0.4))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 34))
                                .foregroundStyle(accent ? Color.accentColor : .secondary)
                        }
                }
            }
            Text(title)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.controlBackgroundColor).opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
