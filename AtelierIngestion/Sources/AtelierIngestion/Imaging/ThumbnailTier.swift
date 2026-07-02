// AtelierIngestion — thumbnail tiers + generation (chunk 3, decisions A4 / P13)
//
// Eager, fixed-size thumbnails generated at ingest. The tiers mirror the canvas
// LOD levels (128 / 512 / 1280 px), so a rendered tile can pick the smallest
// thumbnail that still covers its on-screen size without upscaling.
//
// The generation path is the whole point of P13: `CGImageSourceCreateThumbnail-
// AtIndex` decodes STRAIGHT to the requested max pixel size — the full-resolution
// bitmap is never materialized — and applies the EXIF transform on the way, so
// the thumbnail is display-oriented for free (matching `ImageMetadata`'s dims).
// The result is re-encoded to JPEG: thumbnails are display-only derivatives, and
// JPEG keeps them small and fast to write.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The fixed thumbnail sizes generated at ingest (decision A4).
///
/// The `rawValue` is the **max pixel size** (longest edge) of the tier. These
/// mirror the canvas LOD tiers — keep them in sync with the renderer's LOD
/// thresholds so a tile can select a thumbnail without upscaling.
public enum ThumbnailTier: Int, CaseIterable, Sendable {
    /// 128 px — smallest LOD (distant / densely packed tiles).
    case small = 128
    /// 512 px — mid LOD.
    case medium = 512
    /// 1280 px — largest LOD (a tile filling much of the viewport).
    case large = 1280
}

/// Generates display-oriented JPEG thumbnails from image bytes (decisions
/// A4 / P13). A stateless namespace — all members are `static`.
public enum ThumbnailGenerator {
    /// JPEG quality for encoded thumbnails. 0.8 is visually clean while keeping
    /// derivative files small.
    private static let jpegCompressionQuality: CGFloat = 0.8

    /// Generate a JPEG thumbnail from `data`, decoded directly so its longest
    /// edge is at most `maxPixelSize` pixels (decision P13).
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` does the decode-to-size in one step
    /// (`kCGImageSourceThumbnailMaxPixelSize`), always synthesizes a thumbnail
    /// (`…FromImageAlways`), and applies the EXIF orientation transform
    /// (`…WithTransform`) so the output is display-oriented — the full-res bitmap
    /// is never allocated.
    ///
    /// Throws ``ImageError/unreadable`` for bytes that aren't an image source,
    /// ``ImageError/thumbnailFailed`` if no thumbnail can be produced or it can't
    /// be encoded, and ``ImageError/decodeFailed`` for a corrupt/truncated
    /// source that yields no thumbnail.
    public static func makeThumbnail(from data: Data, maxPixelSize: Int) throws -> Data {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // No thumbnail from a recognized source ⇒ the bytes wouldn't decode.
            throw ImageError.decodeFailed
        }

        return try encodeJPEG(thumbnail)
    }

    /// Convenience over ``makeThumbnail(from:maxPixelSize:)`` using a
    /// ``ThumbnailTier``'s pixel size.
    public static func makeThumbnail(from data: Data, tier: ThumbnailTier) throws -> Data {
        try makeThumbnail(from: data, maxPixelSize: tier.rawValue)
    }

    /// Render a poster frame from a MOVIE container's `data` as a display-oriented
    /// JPEG whose longest edge is at most `maxPixelSize` — the video counterpart to
    /// ``makeThumbnail(from:maxPixelSize:)`` (which can't, since `CGImageSource`
    /// won't open movies). The pipeline generates this ONCE at the largest tier and
    /// feeds it back through the image thumbnail path for every smaller tier.
    ///
    /// The frame is taken slightly into the clip (0.0s is often black/letterboxed)
    /// via `AVAssetImageGenerator`, which applies the track transform
    /// (`appliesPreferredTrackTransform`) and bounds output to `maximumSize`.
    ///
    /// Throws ``ImageError/unreadable`` if the bytes can't be staged/opened and
    /// ``ImageError/thumbnailFailed`` if no frame can be produced.
    public static func makeVideoPoster(from data: Data, maxPixelSize: Int) async throws -> Data {
        let (_, fileExtension) = MediaProbe.movieContainer(data)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: tempURL)
        } catch {
            throw ImageError.unreadable
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let asset = AVURLAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Tolerate seeking to a nearby frame — exactness is pointless for a poster.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // A frame ~1s in (clamped to the clip) avoids a leading black/blank frame.
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(duration)
        let target = seconds.isFinite && seconds > 0
            ? CMTime(seconds: min(1.0, seconds / 2), preferredTimescale: 600)
            : .zero

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: target).image
        } catch {
            throw ImageError.thumbnailFailed
        }
        return try encodeJPEG(cgImage)
    }

    /// Encode a `CGImage` to JPEG `Data`. Throws ``ImageError/thumbnailFailed``
    /// if a JPEG destination can't be created or finalized.
    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.thumbnailFailed
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.thumbnailFailed
        }
        return output as Data
    }
}
