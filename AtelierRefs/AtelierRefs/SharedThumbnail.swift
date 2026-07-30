//
//  SharedThumbnail.swift
//  AtelierRefs
//
//  Thumbnail loading shared by the collection grid, the Collections gallery, and
//  the Spaces list (004-P1/P2, 005-E2). Extracted from the old `LibraryView` so
//  every surface decodes off the main render path via one process-wide cache.
//
//  036 §4 C3 — every surface here now draws from ``ThumbnailPipeline``: a
//  `CGImage` decoded to the slot's own PIXEL BUCKET, off the main thread, with
//  the pixels already forced. The old `ThumbnailCache` (`NSCache<NSString,
//  NSImage>`, countLimit 512, one 512 px bitmap for a 30 pt rail cover) is gone.
//  Two consequences worth stating because they are the point of the change:
//
//   • Every call site passes a bucket derived from ITS OWN analytic display
//     size via ``thumbnailPixelBucket(pointLongSide:scale:)``. A 30 pt rail
//     cover asks for 128 px, not 512 — a 16× smaller bitmap for the same pixels
//     on screen.
//   • The tile draws `Image(decorative:scale:orientation:)` over a `CGImage`,
//     NOT `Image(nsImage:)`. `NSImage` defers its pixel decode to first *draw*,
//     which lands on the main thread mid-scroll (measured 1.07 ms per newly
//     visible cell, `.change-log/176`). Round-tripping the pipeline's `CGImage`
//     back through `NSImage` to keep the old initializer would reintroduce
//     exactly the cost C1 measured away.
//

import AppKit
import AtelierCore
import SwiftUI

/// Loads a thumbnail's image asynchronously via ``ThumbnailPipeline``, so the
/// grid never decodes on the main render path.
///
/// Paints in up to two steps, which is what keeps a fast scroll from showing
/// holes: a bucket-TOLERANT synchronous cache hit draws immediately (any bucket
/// already decoded for this hash, preferring a larger one), and if that hit
/// wasn't the exact bucket the slot wants, the exact one is awaited and swapped
/// in. Keyed on `hash + bucket` so both cell reuse (scrolling) and a density
/// change (⌘±, which can cross a bucket boundary) re-run the load.
struct AsyncThumbnail: View {
    let hash: String
    let url: URL?
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8
    /// Forwarded to ``ThumbnailTile`` — `true` fills the ambient (aspect-sized)
    /// frame for the masonry grid (011-B1); `false` keeps the legacy square.
    var fill: Bool = false
    /// The pixel bucket to decode at, computed by the CALLER from its own
    /// analytic display size (036 §4 C3 — "the cell never guesses its own
    /// size"). Defaults to the 512 tier ceiling so any surface that hasn't been
    /// sized yet is merely wasteful, never blurry.
    var bucket: Int = thumbnailPixelBuckets[thumbnailPixelBuckets.count - 1]
    @State private var image: CGImage?

    var body: some View {
        ThumbnailTile(image: image, isSelected: isSelected, cornerRadius: cornerRadius, fill: fill)
            .task(id: ThumbnailKey(hash: hash, bucket: bucket)) {
                // Instant paint from ANY cached bucket (nil when nothing is
                // cached, which also clears a reused cell's stale image).
                let hit = ThumbnailPipeline.shared.cachedEntry(hash: hash, bucket: bucket)
                image = hit?.image
                // Exact bucket already in hand → nothing more to do.
                if hit?.bucket == bucket { return }
                guard let url else { return }
                if let exact = await ThumbnailPipeline.shared.image(
                    hash: hash, url: url, bucket: bucket) {
                    image = exact
                }
            }
    }
}

/// The grid cell for ANY asset kind (003 · O1): the single render seam over
/// ``AssetContent``. Byte kinds (`image` / `video`) load their thumbnail via
/// ``AsyncThumbnail``; a `color` draws a swatch; anything with no backing data
/// falls back to the neutral placeholder tile. Every surface that shows an asset
/// grid (collection, search results, add-from-library) uses this so a new kind
/// gets its cell in ONE place.
struct AssetContentThumbnail: View {
    let asset: Asset
    /// The byte kinds' on-disk thumbnail URL; ignored for media-less kinds.
    var url: URL?
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8
    /// `true` fills the ambient (aspect-sized) frame for the masonry grid
    /// (011-B1). Media-less kinds have no intrinsic dims → a square (aspect 1)
    /// frame, so their fixed-ratio cards render the same either way; the byte
    /// kinds crop-fill their aspect rect.
    var fill: Bool = false
    /// Forwarded to ``AsyncThumbnail`` — the caller's own analytic pixel bucket.
    var bucket: Int = thumbnailPixelBuckets[thumbnailPixelBuckets.count - 1]

    var body: some View {
        switch asset.content {
        case let .image(hash), let .video(hash):
            AsyncThumbnail(
                hash: hash, url: url, isSelected: isSelected,
                cornerRadius: cornerRadius, fill: fill, bucket: bucket)
        case let .color(hex):
            ColorSwatchTile(hex: hex, isSelected: isSelected, cornerRadius: cornerRadius)
        case let .link(link):
            // With a resolved og:image (blob) show the thumbnail; otherwise a card.
            if let hash = link.imageBlobHash {
                AsyncThumbnail(
                    hash: hash, url: url, isSelected: isSelected,
                    cornerRadius: cornerRadius, fill: fill, bucket: bucket)
            } else {
                LinkCardTile(link: link, isSelected: isSelected, cornerRadius: cornerRadius)
            }
        case let .tweet(tweet):
            // With a captured card image (blob) show it; otherwise a text card.
            if let hash = tweet.cardImageBlobHash {
                AsyncThumbnail(
                    hash: hash, url: url, isSelected: isSelected,
                    cornerRadius: cornerRadius, fill: fill, bucket: bucket)
            } else {
                TweetCardTile(tweet: tweet, isSelected: isSelected, cornerRadius: cornerRadius)
            }
        case .unknown:
            ThumbnailTile(image: nil, isSelected: isSelected, cornerRadius: cornerRadius, fill: fill)
        }
    }
}

/// A square grid card for a media-less `link` asset (003 · C2) with no og:image
/// yet: a globe glyph over the link's title (or host), so a saved link reads as
/// a link. Replaced by the og:image thumbnail once a resolver stores one.
struct LinkCardTile: View {
    let link: LinkContent
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(link.displayHeading)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
            }
            .background(Color(.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A square grid card for a media-less `tweet` asset (003 · C3) with no captured
/// card image yet: a speech-bubble glyph over the author `@handle` and a text
/// snippet, with a small media-count badge when the tweet carries images / video.
/// Replaced by the card image once one is captured.
struct TweetCardTile: View {
    let tweet: TweetContent
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(tweet.displayByline)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let text = tweet.text, !text.isEmpty {
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if !tweet.media.isEmpty {
                    Label("\(tweet.media.count)", systemImage: "photo.on.rectangle")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .background(Color(.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A square color swatch cell (003 · C1) — a media-less `color` asset's grid
/// representation. A hairline border keeps a light swatch (e.g. white) legible
/// against the grid background; the selection ring matches ``ThumbnailTile``.
struct ColorSwatchTile: View {
    let hex: String
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Color(hexString: hex) ?? Color(.quaternaryLabelColor) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// One thumbnail cell — the loaded image, or a placeholder tile. A selection ring
/// marks the item currently selected.
///
/// `fill` picks the sizing mode: the default (`false`) takes a SQUARE via the
/// tile's own aspect ratio (the covers / drag-preview / gallery surfaces that
/// want a uniform square); `true` FILLS the ambient frame instead (011-B1 — the
/// masonry column cell sizes the tile by the item's aspect via an explicit
/// `.frame(width:height:)`, and the image crop-fills that rect).
struct ThumbnailTile: View {
    /// A fully decoded bitmap from ``ThumbnailPipeline`` — deliberately a
    /// `CGImage`, not an `NSImage`, so the pixels are already rasterized when
    /// this draws (036 §4 C1/C3; see the file header).
    let image: CGImage?
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 8
    var fill: Bool = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        sized
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// The image/placeholder layer sized to its host: a square (`Color.clear`
    /// adopts the column width via `aspectRatio(1)`) or the full ambient frame
    /// (`Color.clear` with no ratio flexes to fill), with the crop-fill overlay
    /// clipped to it in both cases.
    @ViewBuilder
    private var sized: some View {
        if fill {
            Color.clear.overlay { imageLayer }
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit).overlay { imageLayer }
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            // `decorative:` because the tile carries no meaning of its own — the
            // accessibility label lives on the CELL (`CollectionCell`), and a
            // second label here would double-announce every grid item. `scale:`
            // is the backing scale, so the bitmap's nominal point size matches
            // the bucket that produced it; `.resizable()` makes the exact value
            // cosmetic, but a wrong one would fight the layout on a rescale.
            Image(decorative: image, scale: displayScale, orientation: .up)
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
    /// The cover's drawn side in POINTS, for the pixel bucket (036 §4 C3). The
    /// default is the widest a cover actually gets on the two surfaces that use
    /// this card: both lay out `GridItem(.adaptive(minimum: 150, maximum: 220))`
    /// and this card insets by 8 pt on each side, so 220 − 16 = 204.
    var coverPointSide: CGFloat = 204
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let coverHash {
                    AsyncThumbnail(
                        hash: coverHash, url: coverURL, cornerRadius: 12,
                        bucket: thumbnailPixelBucket(
                            pointLongSide: coverPointSide, scale: displayScale))
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

extension Color {
    /// A SwiftUI `Color` from a hex string; `nil` for anything unparseable. Kept in
    /// the view layer — the domain stores the hex string, the UI renders it.
    ///
    /// Accepts the same grammar as `ElementRendering.rgba(fromHex:)` and
    /// `AtelierExport`'s `RGBA.init(hex:)` — `#`-optional, whitespace-tolerant,
    /// case-insensitive, 3/4/6/8 digits (see `HexGrammarTests`). It used to take 6
    /// digits only, which was safe for a `ColorPayload` (canonicalised to `#rrggbb`
    /// on write) but wrong for anything else that reached it.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        switch s.count {
        case 3, 4: s = s.map { "\($0)\($0)" }.joined()
        case 6, 8: break
        default: return nil
        }
        guard let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(
                .sRGB,
                red: Double((v >> 24) & 0xff) / 255,
                green: Double((v >> 16) & 0xff) / 255,
                blue: Double((v >> 8) & 0xff) / 255,
                opacity: Double(v & 0xff) / 255)
            return
        }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255)
    }

    /// Canonical `#rrggbb` for this color (via sRGB), or `nil` if it can't be
    /// resolved to RGB — the inverse of ``init(hexString:)``, used to turn a
    /// `ColorPicker` selection into a storable hex (003 · C1).
    func toHexString() -> String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
