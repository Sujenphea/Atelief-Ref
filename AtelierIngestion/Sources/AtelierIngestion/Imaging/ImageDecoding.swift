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

/// Shared image-decode helpers for the byte-consuming imaging utilities. A
/// stateless namespace — all members `static`.
enum ImageDecoding {
    /// Decode image `data` down to a display-oriented `CGImage` whose longest edge
    /// is at most `maxPixelSize` pixels.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` does the decode-to-size in one step
    /// (`kCGImageSourceThumbnailMaxPixelSize`), always synthesizes a thumbnail
    /// (`…FromImageAlways`), and applies the EXIF orientation transform
    /// (`…WithTransform`) — the full-resolution bitmap is never materialized.
    ///
    /// - Throws: ``ImageError/unreadable`` for empty bytes or data that isn't an
    ///   image source at all; ``ImageError/decodeFailed`` for a recognized source
    ///   that yields no thumbnail (corrupt / truncated).
    static func thumbnailCGImage(from data: Data, maxPixelSize: Int) throws -> CGImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // No thumbnail from a recognized source ⇒ the bytes wouldn't decode.
            throw ImageError.decodeFailed
        }
        return image
    }
}
