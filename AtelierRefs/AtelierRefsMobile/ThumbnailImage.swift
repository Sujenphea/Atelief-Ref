// AtelierRefsMobile — getting a thumbnail onto a tile without blocking a scroll.
//
// The Mac's grid decodes off the main thread at the cell's own pixel bucket
// (`IngestionModel.thumbnailURL(for:)`'s note, and `ThumbnailPipeline`), so the render
// path never pays a disk read or a lazy decode at first draw. The phone needs the same
// property for the same reason and gets a much smaller version of it: the tiers on disk
// are already small JPEGs, so there is no pyramid to choose from — a decode straight to
// the cell's pixel size, a bounded cache, and nothing else.
//
// **What is in this file is now only the wiring** (098 · finding 15). The cache itself is
// `AtelierBrowse.DecodeCache` — keyed, byte- and count-bounded, ONE decode per key however
// many views ask, cancellation observed before a decode starts and before an insert. The
// version that lived here had none of the last two, and it also re-implemented two things
// that already existed elsewhere in the program: `ImageDecoding`'s option dictionary,
// option for option, and `DecodedThumbnail`'s `bytesPerRow * height`. Both are asked for
// by name now, so the phone and the Mac's thumbnail pipeline cannot decode differently or
// charge differently for the same file.
//
// `AsyncImage` is deliberately not used: it is built around `URLSession`, and a
// content-addressed file on disk is not a network resource. It also gives no control over
// decode size, which is the one thing that matters when a screen holds a dozen live
// bitmaps.

import AtelierBrowse
import AtelierIngestion
import SwiftUI
import UIKit

/// What a decode is asked for: a file, at a pixel size.
///
/// A struct rather than the interpolated `"\(path)#\(pixels)"` the old cache keyed on.
/// The string had to be built twice per tile — once for the cache and once for the
/// SwiftUI `task(id:)` — and two spellings of one key is how a cache quietly stops
/// hitting.
/// `nonisolated` because this target defaults its isolation to the main actor, and a
/// main-actor-isolated `Hashable` conformance cannot satisfy a `Sendable` type parameter
/// — which is what a cache key crossing into an actor is.
nonisolated struct ThumbnailKey: Hashable, Sendable {
    let url: URL
    let maxPixel: Int
}

/// The app's decoded-thumbnail cache: one ``DecodeCache`` over `ImageDecoding`.
nonisolated enum ThumbnailCache {
    /// The budgets are `DecodeBudget`'s, with 440's argument for them carried there.
    static let shared = DecodeCache<ThumbnailKey, UIImage>(
        // `bytesPerRow * height` of the decoded bitmap — the real allocation, not a guess
        // from the point size, so a wide panorama and a tall skyscraper at the same pixel
        // size are charged what they each actually cost. Asked of `DecodedThumbnail`
        // rather than restated; a `UIImage` with no backing `CGImage` (nothing here
        // produces one) is charged nothing rather than crashing the accounting.
        cost: { image in image.cgImage.map { DecodedThumbnail(image: $0).byteCost } ?? 0 },
        decode: { key in
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                // Decode straight to size — the full-resolution bitmap is never
                // materialised, the same property `ThumbnailGenerator` relies on when it
                // writes these files. `cacheImmediately` defaults to `true` on this
                // overload, which is what keeps the pixel decode off the main thread
                // instead of deferring it to first draw.
                guard let decoded = try? ImageDecoding.decodedThumbnail(
                    from: key.url, maxPixelSize: key.maxPixel) else { return nil }
                return UIImage(cgImage: decoded.image)
            }.value
            TileBodyLog.recordDecode()
            return image
        })

    /// The image at `url`, decoded so its longest edge is at most `maxPixel`, or `nil`
    /// when the file is absent or unreadable — which is a normal outcome, not an error: a
    /// library whose thumbnails have not been generated yet has rows and no files.
    static func image(at url: URL?, maxPixel: Int) async -> UIImage? {
        // Forces the observer below into existence on the first decode of the launch.
        // A `static let` is lazy and thread-safe, so this is one atomic load per tile and
        // there is nothing to remember to call at startup.
        _ = memoryWarningObserver
        guard let url else { return nil }
        return await shared.value(for: ThumbnailKey(url: url, maxPixel: maxPixel))
    }

    /// Drop the whole cache when the system says it is short.
    ///
    /// **This is the one thing `NSCache` did for free** and the one thing the explicit
    /// LRU in `DecodeCache` does not: it purges itself under memory pressure. The trade
    /// was deliberate — `NSCache`'s eviction rules are unspecified, which makes 440's byte
    /// bound a claim no test can make — and this is the other half of it, in the target
    /// that already has UIKit and can hear the notification.
    ///
    /// Dropping everything rather than trimming: the app is being told it is about to be
    /// killed, the files on disk are small JPEGs, and re-decoding a screenful is cheap
    /// next to being jetsammed with a backlog of captures half drained.
    /// A `Bool` rather than the `NSObjectProtocol` token `addObserver` hands back: the
    /// token is not `Sendable` and there is nothing to do with it anyway — this observer
    /// lives for the process, exactly like the cache it purges.
    private nonisolated static let memoryWarningObserver: Bool = {
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            Task { await shared.purge() }
        }
        return true
    }()
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
        // Re-decode when the file OR the bucket changes. Cancelling this task now
        // cancels the decode's INSERT as well — see `DecodeCache.value(for:)`.
        .task(id: key) {
            image = await ThumbnailCache.image(at: url, maxPixel: maxPixel)
        }
    }

    private var key: ThumbnailKey? {
        url.map { ThumbnailKey(url: $0, maxPixel: maxPixel) }
    }

    /// The bucket is rounded so a rotation that nudges the width by a point does not
    /// throw the cache entry away — `DecodeSize`, where it is tested.
    private var maxPixel: Int {
        DecodeSize.maxPixel(width: Double(width), scale: Double(displayScale))
    }
}

/// The art's stable dark ground with a thumbnail on it.
///
/// One recipe rather than four: the grid tile draws it for an image, a video and a link or
/// post with a card image, and the detail screen draws the same thing at the width it is
/// given. `mediaBackdrop` is behind every one of them so a light image and a dark one sit
/// on the same tone instead of the image's own edges reading as chrome — 093 § 6's second
/// reason for dark-only.
struct MediaThumbnail: View {
    let url: URL?
    /// The decode target in points, when the caller knows it — a grid column does.
    /// `nil` means "as wide as the space you are given", which is the detail screen: it
    /// has no column width to hand down and must measure.
    var width: CGFloat?

    var body: some View {
        ZStack {
            MobileTheme.Colors.mediaBackdrop
            if let width {
                ThumbnailImage(url: url, width: width)
            } else {
                GeometryReader { geometry in
                    ThumbnailImage(url: url, width: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}
