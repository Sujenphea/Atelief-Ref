// AtelierCaptureTestSupport — synthetic image fixtures (chunk 3, decision T9; moved
// here from AtelierIngestion's test target in 457).
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
//
// **Why it moved.** The JPEG builder had been copied verbatim into
// `AtelierArchive`'s and the Mac's inbox-archive suites, and the HEIC / oriented /
// corrupt builders were internal to one test target while the inbox, the archive and
// the import all wanted to be driven with the formats a phone actually produces
// (098 · finding 12). One builder, in the product every capture-side test target already
// links; `AtelierIngestionTests` reaches it through a typealias at the old path.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builders for synthetic image `Data` used across the imaging tests (T9).
public enum FixtureImages {
    /// The output container format for a synthetic fixture.
    public enum Format: Sendable {
        case png
        case jpeg
        case heic
        /// GIF — here because it is the one format a phone shares that carries
        /// something the library does not keep: frames (098 · finding 12).
        case gif

        /// The UTType whose identifier drives `CGImageDestination`.
        public var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .gif: return .gif
            }
        }
    }

    /// An error thrown when a fixture can't be synthesized (e.g. HEIC encoding
    /// isn't available in the test environment).
    public enum FixtureError: Error {
        case contextCreationFailed
        case encodingFailed(Format)
    }

    // MARK: - Solid / gradient images

    /// A `width × height` image filled with a simple horizontal gradient,
    /// encoded to `format`. Dimensions are known and, having no EXIF
    /// orientation, survive extraction unchanged.
    public static func solidImage(width: Int, height: Int, format: Format) throws -> Data {
        let image = try makeCGImage(width: width, height: height)
        return try encode(image, format: format, orientation: nil)
    }

    /// A `width × height` image of ONE flat sRGB color — every pixel identical.
    /// Unlike ``solidImage`` (which draws a gradient), this exercises flat-image
    /// behavior: a dHash of all-equal luminance samples, and a single dominant
    /// color. Defaults to PNG (lossless, so the decoded color is exact).
    public static func solidColorImage(
        width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, format: Format = .png
    ) throws -> Data {
        let image = try makeFilledCGImage(width: width, height: height) { context in
            context.setFillColor(
                red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try encode(image, format: format, orientation: nil)
    }

    /// A `width × height` image split left/right into two flat colors, `left`
    /// covering `leftFraction` of the width. Exercises multi-cluster color
    /// extraction with a known coverage split (default 50/50).
    public static func twoToneImage(
        width: Int, height: Int,
        left: (r: UInt8, g: UInt8, b: UInt8), right: (r: UInt8, g: UInt8, b: UInt8),
        leftFraction: Double = 0.5, format: Format = .png
    ) throws -> Data {
        let split = Int((Double(width) * leftFraction).rounded())
        let image = try makeFilledCGImage(width: width, height: height) { context in
            context.setFillColor(
                red: CGFloat(left.r) / 255, green: CGFloat(left.g) / 255,
                blue: CGFloat(left.b) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: split, height: height))
            context.setFillColor(
                red: CGFloat(right.r) / 255, green: CGFloat(right.g) / 255,
                blue: CGFloat(right.b) / 255, alpha: 1)
            context.fill(CGRect(x: split, y: 0, width: width - split, height: height))
        }
        return try encode(image, format: format, orientation: nil)
    }

    /// A `width × height` fully-transparent PNG (every pixel alpha 0). Used to
    /// assert color extraction drops transparent pixels (→ no swatches). PNG keeps
    /// the alpha channel losslessly; JPEG would flatten it.
    public static func transparentImage(width: Int, height: Int) throws -> Data {
        let image = try makeFilledCGImage(width: width, height: height) { _ in }
        return try encode(image, format: .png, orientation: nil)
    }

    // MARK: - EXIF-oriented image

    /// An image whose STORED pixels are `pixelWidth × pixelHeight` but which
    /// carries an EXIF `kCGImagePropertyOrientation` of `orientation`.
    ///
    /// For a 90°/270° orientation (5–8) the display dimensions are the swap of
    /// the stored ones — extraction and thumbnailing must both surface the
    /// swapped, display-oriented size. Encoded as JPEG (EXIF lives naturally in
    /// JPEG). Defaults to orientation 6 (90° CW).
    public static func orientedImage(
        pixelWidth: Int, pixelHeight: Int, orientation: Int = 6
    ) throws -> Data {
        let image = try makeCGImage(width: pixelWidth, height: pixelHeight)
        return try encode(image, format: .jpeg, orientation: orientation)
    }

    // MARK: - HEIC

    /// A `width × height` HEIC image. Throws ``FixtureError/encodingFailed(_:)``
    /// if HEIC encoding is unavailable in the environment, so callers can skip
    /// HEIC assertions gracefully.
    public static func heicImage(width: Int, height: Int) throws -> Data {
        let image = try makeCGImage(width: width, height: height)
        return try encode(image, format: .heic, orientation: nil)
    }

    // MARK: - The formats a phone shares (098 · finding 12)

    /// The payload shapes a share sheet on a phone can hand over, as one list.
    ///
    /// It lives here because two suites in two packages sweep over it — the drain in
    /// `AtelierIngestion` and the export in `AtelierArchive` — and a second copy of
    /// "these are the formats, and this is what each one must say afterwards" is the
    /// kind of copy that stays green while one of them stops covering a case. Every
    /// case is 40 × 30 as STORED, so a suite can assert one pair of numbers.
    ///
    /// ``heic`` is the case that can be unavailable: HEIC ENCODING is not present in
    /// every environment, so ``bytes()`` throws there and the caller is expected to say
    /// so out loud rather than pass quietly.
    public enum PhoneFormat: String, CaseIterable, Sendable, CustomStringConvertible {
        /// The web's lossless default, and what every fixture in this repo used to be.
        case png
        /// The web's lossy default, and what a share sheet hands over most often.
        case jpeg
        /// What the camera roll actually holds on this decade's iPhones.
        case heic
        /// A photograph taken sideways: 40 × 30 of stored pixels, EXIF orientation 6,
        /// and therefore 30 × 40 to look at. The only case where the two disagree.
        case rotatedJPEG
        /// The one format that carries something the library does not keep.
        case gif

        public var description: String { rawValue }

        /// The bytes, or a throw when this host cannot encode the format.
        public func bytes() throws -> Data {
            switch self {
            case .png: try FixtureImages.solidImage(width: 40, height: 30, format: .png)
            case .jpeg: try FixtureImages.solidImage(width: 40, height: 30, format: .jpeg)
            case .heic: try FixtureImages.heicImage(width: 40, height: 30)
            case .rotatedJPEG:
                try FixtureImages.orientedImage(
                    pixelWidth: 40, pixelHeight: 30, orientation: 6)
            case .gif: try FixtureImages.animatedGIF(width: 40, height: 30, frames: 3)
            }
        }

        /// The dimensions in the container's header, before any EXIF transform — what a
        /// header read reports.
        public var storedSize: (width: Int, height: Int) { (40, 30) }

        /// The dimensions after the EXIF transform — what will actually be drawn, and
        /// what a full decode reports.
        public var displaySize: (width: Int, height: Int) {
            self == .rotatedJPEG ? (30, 40) : (40, 30)
        }

        public var mimeType: String {
            switch self {
            case .png: "image/png"
            case .jpeg, .rotatedJPEG: "image/jpeg"
            case .heic: "image/heic"
            case .gif: "image/gif"
            }
        }
    }

    // MARK: - GIF

    /// A `width × height` animated GIF of `frames` frames, each a different flat colour,
    /// at 100 ms per frame.
    ///
    /// It exists to be asserted against rather than to be pretty: the point of the
    /// fixture is that it carries MORE than one image, so a test can say what the
    /// library keeps of it (the container, byte for byte, in the blob) and what it does
    /// not (the animation, in a thumbnail that is one still JPEG).
    public static func animatedGIF(width: Int, height: Int, frames: Int = 3) throws -> Data {
        let output = NSMutableData()
        guard frames > 0, let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.gif.identifier as CFString, frames, nil) else {
            throw FixtureError.encodingFailed(.gif)
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        for frame in 0 ..< frames {
            let shade = CGFloat(frame + 1) / CGFloat(frames + 1)
            let image = try makeFilledCGImage(width: width, height: height) { context in
                context.setFillColor(red: shade, green: 1 - shade, blue: 0.4, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encodingFailed(.gif)
        }
        return output as Data
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
    public static func corruptImage() throws -> Data {
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
    public static func nonImageBytes() -> Data {
        Data("this is not an image, just plain UTF-8 text".utf8)
    }

    /// Empty data — zero bytes.
    public static let zeroBytes = Data()

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

    /// Build a `width × height` RGBA `CGImage` by running `draw` against a fresh
    /// premultiplied-alpha context — the flexible primitive behind the solid /
    /// two-tone / transparent fixtures. The context starts fully transparent, so a
    /// `draw` that fills only part of the frame leaves the rest transparent.
    public static func makeFilledCGImage(
        width: Int, height: Int, draw: (CGContext) -> Void
    ) throws -> CGImage {
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
        draw(context)
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
