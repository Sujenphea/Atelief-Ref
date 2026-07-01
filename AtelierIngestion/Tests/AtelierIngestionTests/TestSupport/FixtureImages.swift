// AtelierIngestion — synthetic image fixtures (chunk 3, decision T9)
//
// No committed binary fixtures: every test image is generated deterministically
// at runtime from a `CGContext`, then encoded via `CGImageDestination` — the
// same approach as the canvas spike. This keeps the repo free of opaque blobs
// and makes each fixture's intent (its dimensions, orientation, format,
// corruption) explicit in code.
//
// IMPORTANT: JPEG and HEIC encodings are NOT byte-deterministic across OS
// versions / hardware, so tests MUST assert on DECODED properties (dimensions,
// decodability, MIME) — never on exact bytes. PNG is lossless but tests still
// assert on decoded facts for uniformity.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builders for synthetic image `Data` used across the imaging tests (T9).
enum FixtureImages {
    /// The output container format for a synthetic fixture.
    enum Format {
        case png
        case jpeg
        case heic

        /// The UTType whose identifier drives `CGImageDestination`.
        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }
    }

    /// An error thrown when a fixture can't be synthesized (e.g. HEIC encoding
    /// isn't available in the test environment).
    enum FixtureError: Error {
        case contextCreationFailed
        case encodingFailed(Format)
    }

    // MARK: - Solid / gradient images

    /// A `width × height` image filled with a simple horizontal gradient,
    /// encoded to `format`. Dimensions are known and, having no EXIF
    /// orientation, survive extraction unchanged.
    static func solidImage(width: Int, height: Int, format: Format) throws -> Data {
        let image = try makeCGImage(width: width, height: height)
        return try encode(image, format: format, orientation: nil)
    }

    // MARK: - EXIF-oriented image

    /// An image whose STORED pixels are `pixelWidth × pixelHeight` but which
    /// carries an EXIF `kCGImagePropertyOrientation` of `orientation`.
    ///
    /// For a 90°/270° orientation (5–8) the display dimensions are the swap of
    /// the stored ones — extraction and thumbnailing must both surface the
    /// swapped, display-oriented size. Encoded as JPEG (EXIF lives naturally in
    /// JPEG). Defaults to orientation 6 (90° CW).
    static func orientedImage(
        pixelWidth: Int, pixelHeight: Int, orientation: Int = 6
    ) throws -> Data {
        let image = try makeCGImage(width: pixelWidth, height: pixelHeight)
        return try encode(image, format: .jpeg, orientation: orientation)
    }

    // MARK: - HEIC

    /// A `width × height` HEIC image. Throws ``FixtureError/encodingFailed(_:)``
    /// if HEIC encoding is unavailable in the environment, so callers can skip
    /// HEIC assertions gracefully.
    static func heicImage(width: Int, height: Int) throws -> Data {
        let image = try makeCGImage(width: width, height: height)
        return try encode(image, format: .heic, orientation: nil)
    }

    // MARK: - Degenerate inputs

    /// A valid JPEG truncated just before its Start-Of-Frame marker — a
    /// recognized JPEG container (the SOI marker survives, so
    /// `CGImageSourceGetType` still reports `public.jpeg`) whose frame header and
    /// scan data are gone, so it yields NO dimensions and NO thumbnail
    /// (undecodable).
    ///
    /// Note: modern ImageIO (macOS 26) is lenient enough to read dimensions from
    /// a JPEG truncated by a fixed *fraction* — the SOF marker sits early and
    /// high-frequency content inflates the tail — so we cut deterministically at
    /// the SOF marker instead, which is what actually carries the dimensions.
    static func corruptImage() throws -> Data {
        let full = try solidImage(width: 256, height: 256, format: .jpeg)
        return truncatedBeforeSOF(full)
    }

    /// The SOFn marker second bytes that carry frame dimensions (baseline,
    /// progressive, extended, lossless — excluding DHT `C4` / JPG `C8` / DAC
    /// `CC`, which are not frame headers).
    private static let sofMarkers: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    ]

    /// Return the prefix of `jpeg` up to (not including) its first SOFn marker,
    /// so the frame's width/height are absent. Falls back to a short prefix if no
    /// SOF is found (keeps the SOI so the type is still recognized).
    private static func truncatedBeforeSOF(_ jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0xFF, sofMarkers.contains(bytes[i + 1]) {
                return jpeg.prefix(i)
            }
            i += 1
        }
        return jpeg.prefix(min(64, jpeg.count))
    }

    /// Arbitrary non-image bytes (UTF-8 text) — a valid byte string that is not
    /// any image/video container.
    static func nonImageBytes() -> Data {
        Data("this is not an image, just plain UTF-8 text".utf8)
    }

    /// Empty data — zero bytes.
    static let zeroBytes = Data()

    // MARK: - Primitives

    /// Build a `width × height` RGB `CGImage` with a horizontal gradient so the
    /// content is non-trivial (not a single flat color).
    private static func makeCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FixtureError.contextCreationFailed
        }

        // Horizontal gradient of vertical bars for a bit of structure.
        let bars = max(width, 1)
        for x in 0 ..< bars {
            let t = CGFloat(x) / CGFloat(bars)
            context.setFillColor(red: t, green: 1 - t, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }

        guard let image = context.makeImage() else {
            throw FixtureError.contextCreationFailed
        }
        return image
    }

    /// Encode `image` to `format`, optionally tagging an EXIF `orientation`.
    private static func encode(_ image: CGImage, format: Format, orientation: Int?) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, format.utType.identifier as CFString, 1, nil) else {
            throw FixtureError.encodingFailed(format)
        }

        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encodingFailed(format)
        }
        return output as Data
    }
}
