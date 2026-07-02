// AtelierIngestion — image metadata extraction tests (chunk 3, decision T11)
//
// Dimensions / MIME / kind / extension across formats; EXIF-orientation dim
// swap; extension-independence (extraction has no filename input); and the
// degenerate inputs (corrupt, zero-byte, non-image) mapping to typed errors.

import Foundation
import Testing
@testable import AtelierIngestion
import AtelierCore

@Suite("ImageMetadata")
struct ImageMetadataTests {
    // MARK: - Format matrix (parameterized)

    struct FormatCase: CustomTestStringConvertible {
        let format: FixtureImages.Format
        let expectedMIME: String
        var testDescription: String { expectedMIME }
    }

    @Test("PNG and JPEG extract correct dims, MIME, kind, and extension",
          arguments: [
            FormatCase(format: .png, expectedMIME: "image/png"),
            FormatCase(format: .jpeg, expectedMIME: "image/jpeg"),
          ])
    func extractFormat(_ testCase: FormatCase) throws {
        let data = try FixtureImages.solidImage(width: 320, height: 200, format: testCase.format)
        let meta = try ImageMetadata.extract(from: data)

        #expect(meta.width == 320)
        #expect(meta.height == 200)
        #expect(meta.mimeType == testCase.expectedMIME)
        #expect(meta.kind == .image)
        #expect(!meta.fileExtension.isEmpty)
    }

    @Test("HEIC extracts correct dims + kind when encoding is available")
    func extractHEIC() throws {
        // HEIC encoding may be unavailable in some environments; skip gracefully.
        guard let data = try? FixtureImages.heicImage(width: 240, height: 160) else {
            return
        }
        let meta = try ImageMetadata.extract(from: data)
        #expect(meta.width == 240)
        #expect(meta.height == 160)
        #expect(meta.kind == .image)
        #expect(meta.mimeType == "image/heic")
    }

    // MARK: - EXIF orientation

    @Test("EXIF orientation 6 (90°) yields SWAPPED display dimensions")
    func exifOrientationSwapsDims() throws {
        // Stored pixels 100 × 60, orientation 6 ⇒ display 60 × 100.
        let data = try FixtureImages.orientedImage(pixelWidth: 100, pixelHeight: 60, orientation: 6)
        let meta = try ImageMetadata.extract(from: data)
        #expect(meta.width == 60)
        #expect(meta.height == 100)
    }

    @Test("pure display-dimension math swaps only for orientations 5–8")
    func displayDimensionMath() {
        for o in [1, 2, 3, 4] {
            #expect(ImageMetadata.displayDimensions(pixelWidth: 100, pixelHeight: 60, orientation: o)
                == (100, 60))
        }
        for o in [5, 6, 7, 8] {
            #expect(ImageMetadata.displayDimensions(pixelWidth: 100, pixelHeight: 60, orientation: o)
                == (60, 100))
        }
    }

    // MARK: - MIME from bytes, not extension

    @Test("MIME is derived from the bytes — extraction takes no filename at all")
    func mimeFromBytesNotExtension() throws {
        // `extract(from:)` has no name parameter, so its answer is inherently
        // extension-independent: PNG bytes always report image/png.
        let data = try FixtureImages.solidImage(width: 10, height: 10, format: .png)
        #expect(try ImageMetadata.extract(from: data).mimeType == "image/png")
    }

    // MARK: - Degenerate inputs → typed errors

    @Test("corrupt / truncated bytes throw decodeFailed or unreadable")
    func corruptThrows() throws {
        let data = try FixtureImages.corruptImage()
        #expect {
            try ImageMetadata.extract(from: data)
        } throws: { error in
            error as? ImageError == .decodeFailed || error as? ImageError == .unreadable
        }
    }

    @Test("zero bytes throw unreadable")
    func zeroBytesThrows() {
        #expect(throws: ImageError.unreadable) {
            try ImageMetadata.extract(from: FixtureImages.zeroBytes)
        }
    }

    @Test("non-image bytes throw an ImageError (unsupportedType or unreadable)")
    func nonImageThrows() {
        #expect {
            try ImageMetadata.extract(from: FixtureImages.nonImageBytes())
        } throws: { error in
            guard let imageError = error as? ImageError else { return false }
            switch imageError {
            case .unreadable, .unsupportedType:
                return true
            default:
                return false
            }
        }
    }
}
