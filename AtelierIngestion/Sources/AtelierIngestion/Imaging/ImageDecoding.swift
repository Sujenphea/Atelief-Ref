// AtelierIngestion — shared thumbnail decode (chunk 3 / feature 012)
//
// One home for the `CGImageSource` → `CGImageSourceCreateThumbnailAtIndex` dance
// that every byte-consuming image utility needs: thumbnail generation
// (``ThumbnailGenerator``), perceptual hashing (``PerceptualHash``), and color
// extraction (``ColorExtractor``) all decode the same way and differ only in what
// they do with the resulting `CGImage`. Keeping the decode in one place means the
// options (always-synthesize, EXIF-transform) and their error mapping can't drift
// between call sites.
//
// The decode always applies the EXIF orientation transform, so every consumer
// sees display-oriented pixels — the same guarantee ``ImageMetadata`` makes for
// dimensions. That is what lets an orientation-variant copy of an image hash and
// color-analyze identically to the original.

import CoreGraphics
import Foundation
import ImageIO

/// A decoded thumbnail plus the byte cost of its backing bitmap.
///
/// Callers that hold decoded images in a byte-budgeted cache (the app's
/// `ThumbnailPipeline`, 036 §4 C1) need `bytesPerRow * height` to charge an
/// `NSCache.totalCostLimit`; recovering it later from a bare `CGImage` works but
/// invites each call site to reinvent the arithmetic. Decode returns both.
///
/// Deliberately NOT `Sendable`: `CGImage` isn't, and pretending otherwise would
/// paper over the isolation question at every consumer. Decode where you use it.
public struct DecodedThumbnail {
    /// Display-oriented pixels — the EXIF transform is already applied.
    public let image: CGImage
    /// `bytesPerRow * height` of the decoded bitmap.
    public let byteCost: Int

    public init(image: CGImage) {
        self.image = image
        self.byteCost = image.bytesPerRow * image.height
    }
}

/// Shared image-decode helpers for the byte-consuming imaging utilities. A
/// stateless namespace — all members `static`.
///
/// `public` because the app target's thumbnail pipeline (036 §4 C1) decodes the
/// same way for the grid: one decoder, one set of options, no drift.
public enum ImageDecoding {
    /// Decode image `data` down to a display-oriented `CGImage` whose longest edge
    /// is at most `maxPixelSize` pixels.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` does the decode-to-size in one step
    /// (`kCGImageSourceThumbnailMaxPixelSize`), always synthesizes a thumbnail
    /// (`…FromImageAlways`), and applies the EXIF orientation transform
    /// (`…WithTransform`) — the full-resolution bitmap is never materialized.
    ///
    /// - Parameter cacheImmediately: force the pixel decode to happen HERE
    ///   (`kCGImageSourceShouldCacheImmediately`) instead of lazily at first
    ///   draw. Defaults to `false`, preserving the behavior every pre-existing
    ///   call site was written against — those consumers immediately draw the
    ///   result into their own bitmap context on the same background thread, so
    ///   the lazy decode costs them nothing. Pass `true` when the image will be
    ///   handed to the render server later (see ``DecodedThumbnail``): a lazy
    ///   decode there lands on the MAIN thread mid-scroll, which is the specific
    ///   stall 036 §5 predicts.
    ///
    ///   Measured caveat: for the `CGImageSourceCreateThumbnailAtIndex` path
    ///   below the flag is a **no-op** — thumbnail synthesis already returns a
    ///   rasterized bitmap, and create/first-draw times are identical with it on
    ///   and off. It is passed anyway because it states the requirement, and it
    ///   becomes load-bearing for any future full-size
    ///   `CGImageSourceCreateImageAtIndex` decode. Do not mistake it for the
    ///   thing that makes the grid smooth.
    /// - Throws: ``ImageError/unreadable`` for empty bytes or data that isn't an
    ///   image source at all; ``ImageError/decodeFailed`` for a recognized source
    ///   that yields no thumbnail (corrupt / truncated).
    public static func thumbnailCGImage(
        from data: Data,
        maxPixelSize: Int,
        cacheImmediately: Bool = false
    ) throws -> CGImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }
        return try thumbnail(from: source, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately)
    }

    /// Decode the image at `url` down to a display-oriented `CGImage` whose
    /// longest edge is at most `maxPixelSize` pixels.
    ///
    /// The `URL` overload exists so size-bounded consumers (the grid's thumbnail
    /// pipeline) don't read a whole file into memory only to hand it straight to
    /// ImageIO — `CGImageSourceCreateWithURL` maps the bytes and reads only what
    /// the thumbnail needs. Otherwise identical to the `Data` overload.
    ///
    /// - Throws: ``ImageError/unreadable`` if `url` isn't an image source at all
    ///   (missing, unreadable, or not an image); ``ImageError/decodeFailed`` for
    ///   a recognized source that yields no thumbnail.
    public static func thumbnailCGImage(
        from url: URL,
        maxPixelSize: Int,
        cacheImmediately: Bool = false
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageError.unreadable
        }
        return try thumbnail(from: source, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately)
    }

    /// ``thumbnailCGImage(from:maxPixelSize:cacheImmediately:)`` for a `URL`,
    /// paired with the decoded bitmap's byte cost. `cacheImmediately` defaults to
    /// `true` here: the only reason to want the byte cost is to put the image in
    /// a byte-budgeted cache and draw it later, which is exactly the case that
    /// must not defer its decode to the main thread.
    public static func decodedThumbnail(
        from url: URL,
        maxPixelSize: Int,
        cacheImmediately: Bool = true
    ) throws -> DecodedThumbnail {
        DecodedThumbnail(
            image: try thumbnailCGImage(
                from: url, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately))
    }

    /// ``decodedThumbnail(from:maxPixelSize:cacheImmediately:)`` over in-memory
    /// bytes.
    public static func decodedThumbnail(
        from data: Data,
        maxPixelSize: Int,
        cacheImmediately: Bool = true
    ) throws -> DecodedThumbnail {
        DecodedThumbnail(
            image: try thumbnailCGImage(
                from: data, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately))
    }

    /// The one place the thumbnail options are spelled out, shared by both source
    /// flavors so `Data` and `URL` decodes can't drift apart.
    private static func thumbnail(
        from source: CGImageSource,
        maxPixelSize: Int,
        cacheImmediately: Bool
    ) throws -> CGImage {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if cacheImmediately {
            options[kCGImageSourceShouldCacheImmediately] = true
        }

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // No thumbnail from a recognized source ⇒ the bytes wouldn't decode.
            throw ImageError.decodeFailed
        }
        return image
    }
}
