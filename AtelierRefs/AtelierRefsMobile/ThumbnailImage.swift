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

    /// The ceiling on decoded bytes held at once — **96 MB**.
    ///
    /// **A count limit alone stopped being a bound once the detail screen shared this
    /// cache.** The original reasoning was that these are display tiers and a phone
    /// screen holds a dozen, so 240 was generous rather than dangerous. That describes
    /// what is VISIBLE; the cache retains 240 whatever is on screen, and it now holds
    /// two populations four times apart in size:
    ///
    ///   · a grid tile is the 512 tier decoded to a column width — ~570px on a 2-column
    ///     phone layout, so roughly 1.3 MB of RGBA;
    ///   · a detail image is the 1280 tier decoded to the full screen width — ~1170px,
    ///     so roughly 5.5 MB.
    ///
    /// 240 of the second is well over a gigabyte. Nothing but `NSCache`'s own
    /// memory-pressure eviction stood between a browse-heavy session and that, and
    /// relying on pressure eviction alone is how a scroll ends up decoding, evicting
    /// and re-decoding the same tiles.
    ///
    /// 96 MB holds several screenfuls of tiles plus a handful of detail images — the
    /// working set of actually paging around a library — and leaves the rest to be
    /// re-decoded, which is cheap because the files on disk are already small JPEGs.
    private static let byteBudget = 96 * 1024 * 1024

    private init() {
        // The count limit stays as the coarse bound; the cost limit is the real one.
        // `NSCache` enforces whichever is reached first, and they answer different
        // questions — 240 caps how many keys can pile up, `byteBudget` caps what those
        // keys can weigh, which is the number that actually matters on a phone.
        cache.countLimit = 240
        cache.totalCostLimit = Self.byteBudget
    }

    /// What one decoded image weighs, for the cost limit above.
    ///
    /// `bytesPerRow * height` — the bitmap's real allocation, not a guess from the
    /// point size, so a wide panorama and a tall skyscraper at the same `maxPixel` are
    /// charged what they each actually cost. A `UIImage` with no backing `CGImage`
    /// (nothing here produces one) is charged nothing rather than crashing the accounting.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
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
        if let decoded { cache.setObject(decoded, forKey: key, cost: Self.cost(of: decoded)) }
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

    /// The scale of the screen this view is actually on — `UIScreen.main` is deprecated
    /// in iOS 26 in favour of a scale found through context, and this is that context.
    /// It also happens to be the correct answer rather than the usually-correct one:
    /// `main` is the device's built-in screen even when the window is on an external
    /// display, and the decode wants the pixels the picture will be drawn at.
    @Environment(\.displayScale) private var displayScale

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
        let pixels = Int((width * displayScale).rounded(.up))
        // Round up to a 128 bucket so a handful of widths share cache entries.
        return max(128, ((pixels + 127) / 128) * 128)
    }
}
