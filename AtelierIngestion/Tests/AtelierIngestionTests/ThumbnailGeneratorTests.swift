// AtelierIngestion — thumbnail generator tests (chunk 3, decisions A4 / P13)
//
// Downscale-to-tier, per-tier max-dimension bound, EXIF-transform application in
// the thumbnail path, and corrupt-input failure. Asserts on DECODED thumbnail
// dimensions — never exact JPEG bytes (encodings aren't byte-deterministic).

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AtelierIngestion

@Suite("ThumbnailGenerator")
struct ThumbnailGeneratorTests {
    /// Decode a thumbnail's pixel dimensions from its bytes.
    private func decodedDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return (width, height)
    }

    // MARK: - Downscale + aspect ratio

    @Test("a large image at tier .medium bounds max dim ≤ 512 and keeps aspect ratio")
    func downscalesLargeImage() throws {
        let data = try FixtureImages.solidImage(width: 2000, height: 1500, format: .png)
        let thumb = try ThumbnailGenerator.makeThumbnail(from: data, tier: .medium)
        let (w, h) = try decodedDimensions(thumb)

        #expect(max(w, h) <= 512)
        // Source aspect 2000:1500 = 4:3 ≈ 1.333; allow small rounding slack.
        let sourceAspect = 2000.0 / 1500.0
        let thumbAspect = Double(w) / Double(h)
        #expect(abs(thumbAspect - sourceAspect) < 0.05)
    }

    // MARK: - Per-tier bound

    @Test("every tier bounds the thumbnail's max dimension ≤ the tier size",
          arguments: ThumbnailTier.allCases)
    func eachTierBounds(_ tier: ThumbnailTier) throws {
        let data = try FixtureImages.solidImage(width: 3000, height: 2000, format: .jpeg)
        let thumb = try ThumbnailGenerator.makeThumbnail(from: data, tier: tier)
        let (w, h) = try decodedDimensions(thumb)
        #expect(max(w, h) <= tier.rawValue)
    }

    // MARK: - EXIF transform in thumbnail path

    @Test("thumbnail of an EXIF-oriented image has display-oriented dims (transform applied)")
    func appliesExifTransform() throws {
        // Stored 400 × 240, orientation 6 ⇒ display is portrait (taller than wide).
        let data = try FixtureImages.orientedImage(pixelWidth: 400, pixelHeight: 240, orientation: 6)
        let thumb = try ThumbnailGenerator.makeThumbnail(from: data, tier: .small)
        let (w, h) = try decodedDimensions(thumb)
        #expect(max(w, h) <= 128)
        // Transform applied ⇒ portrait: height exceeds width.
        #expect(h > w)
    }

    // MARK: - Failure

    @Test("thumbnail of a corrupt image throws")
    func corruptThrows() throws {
        let data = try FixtureImages.corruptImage()
        #expect(throws: ImageError.self) {
            try ThumbnailGenerator.makeThumbnail(from: data, tier: .small)
        }
    }

    @Test("thumbnail of zero bytes throws unreadable")
    func zeroBytesThrows() {
        #expect(throws: ImageError.unreadable) {
            try ThumbnailGenerator.makeThumbnail(from: FixtureImages.zeroBytes, tier: .small)
        }
    }
}
