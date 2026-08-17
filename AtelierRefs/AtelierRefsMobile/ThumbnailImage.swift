// AtelierRefsMobile — getting a thumbnail onto a tile without blocking a scroll.
//
// The Mac's grid decodes off the main thread at the cell's own pixel bucket
// (`IngestionModel.thumbnailURL(for:)`'s note, and `ThumbnailPipeline`), so the render
// path never pays a disk read or a lazy decode at first draw. The phone needs the same
// property for the same reason and gets a much smaller version of it: the tiers on
// disk are already small JPEGs, so there is no pyramid to choose from and no eviction
// policy to design — `CGImageSourceCreateThumbnailAtIndex` to the cell's pixel size,
// an `NSCache` keyed by path and size, and nothing else.
//
// `AsyncImage` is deliberately not used: it is built around `URLSession`, and a
// content-addressed file on disk is not a network resource. It also gives no control
// over decode size, which is the one thing that matters when a screen holds a dozen
// live bitmaps.

import SwiftUI
import ImageIO
import UIKit

/// A decoded-thumbnail cache, keyed by `path#pixels`.
///
/// `@unchecked Sendable` over an `NSCache`, which is itself thread-safe — the
/// unchecked part is the promise that nothing else here is mutable, and nothing is.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // A generous count rather than a byte budget: these are display tiers, a phone
        // screen holds a dozen, and the memory ceiling that matters on iOS belongs to
        // the share extension (091 · D2), not to the app.
        cache.countLimit = 240
    }

    /// The image at `url`, decoded so its longest edge is at most `maxPixel`, or `nil`
    /// when the file is absent or unreadable — which is a normal outcome, not an error:
    /// a library whose thumbnails have not been generated yet has rows and no files.
    func image(at url: URL?, maxPixel: Int) async -> UIImage? {
        guard let url else { return nil }
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixel: maxPixel)
        }.value
        if let decoded { cache.setObject(decoded, forKey: key) }
        return decoded
    }

    /// Decode straight to size — the full-resolution bitmap is never materialised, the
    /// same property `ThumbnailGenerator` relies on when it writes these files.
    private nonisolated static func decode(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A tile's image: the decoded thumbnail, or nothing.
///
/// Nothing, rather than a spinner or a broken-image glyph. A grid full of placeholders
/// competing for attention is worse than a grid of quiet dark rectangles that fill in;
/// `mediaBackdrop` is behind every one of them and is the art's ground anyway.
struct ThumbnailImage: View {
    let url: URL?
    /// The cell's width in points; the decode target is this at the screen's scale.
    let width: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: taskKey) {
            image = await ThumbnailCache.shared.image(at: url, maxPixel: maxPixel)
        }
    }

    /// Re-decode when the file OR the bucket changes; the bucket is rounded so a
    /// rotation that nudges the width by a point does not throw the cache away.
    private var taskKey: String {
        "\(url?.path ?? "")#\(maxPixel)"
    }

    private var maxPixel: Int {
        let scale = UIScreen.main.scale
        let pixels = Int((width * scale).rounded(.up))
        // Round up to a 128 bucket so a handful of widths share cache entries.
        return max(128, ((pixels + 127) / 128) * 128)
    }
}
