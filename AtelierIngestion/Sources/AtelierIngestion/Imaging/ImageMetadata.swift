// AtelierIngestion — image metadata extraction (chunk 3, decision C7)
//
// Derive an asset's intrinsic facts — pixel dimensions, MIME type, medium
// (image/video), canonical file extension — purely from its BYTES via ImageIO
// and UniformTypeIdentifiers. Nothing here trusts a filename, an extension, or a
// pasteboard-claimed type: the extractor takes only `Data` and never sees a
// name, so its answers are, by construction, extension-independent.
//
// Two subtleties this file exists to get right:
//   • EXIF orientation. Stored pixels may be rotated relative to how the image
//     is meant to be displayed. For orientations 5–8 (a 90°/270° quarter turn)
//     the stored width/height are swapped versus display, so we SWAP them here —
//     the returned dims are always DISPLAY-oriented, matching what a thumbnail
//     (which also applies the transform) will look like.
//   • Type classification from the container, not the extension: UTType tells us
//     whether the bytes are a still image or a movie, and gives the canonical
//     MIME + extension.

import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

import AtelierCapture
import AtelierCore

/// The intrinsic, byte-derived facts about an image (or video container) —
/// decision C7. All fields come from the bytes; none from any filename.
///
/// `width`/`height` are **display-oriented** pixels: EXIF orientation has
/// already been applied, so a portrait photo stored as landscape+rotate reports
/// its portrait dimensions.
public struct ImageMetadata: Sendable, Equatable {
    /// Display-oriented pixel width (EXIF orientation applied).
    public let width: Int
    /// Display-oriented pixel height (EXIF orientation applied).
    public let height: Int
    /// The container's canonical MIME type (e.g. `image/png`, `image/jpeg`).
    public let mimeType: String
    /// The medium — `.image` or `.video` — classified from the container's UTI.
    public let kind: AssetKind
    /// The container's canonical filename extension (e.g. `png`, `jpeg`), no dot.
    public let fileExtension: String
    /// Playback duration in seconds for a `.video`; `nil` for a still image.
    public let duration: Double?

    public init(
        width: Int, height: Int, mimeType: String, kind: AssetKind,
        fileExtension: String, duration: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.kind = kind
        self.fileExtension = fileExtension
        self.duration = duration
    }
}

extension ImageMetadata {
    /// Extract metadata from raw image (or video-container) `data` (decision C7).
    ///
    /// The pipeline of failures, and the error each raises:
    ///   • zero bytes / unrecognized container → ``ImageError/unreadable``.
    ///   • recognized container but a type we don't accept (not conforming to
    ///     `.image`, `.movie`, or `.audiovisualContent`) →
    ///     ``ImageError/unsupportedType(mime:)``.
    ///   • recognized image container that won't yield dimensions (corrupt /
    ///     truncated) → ``ImageError/decodeFailed``.
    ///
    /// Dimensions are read from `kCGImagePropertyPixelWidth/Height`, then made
    /// display-oriented by swapping for EXIF orientations 5–8 (see
    /// ``displayDimensions(pixelWidth:pixelHeight:orientation:)``). MIME, kind,
    /// and extension come from `CGImageSourceGetType` → `UTType`.
    public static func extract(from data: Data) throws -> ImageMetadata {
        // Zero bytes can't be a container at all.
        guard !data.isEmpty else { throw ImageError.unreadable }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }

        // The container's type (a UTI string) tells us MIME / kind / extension.
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let utType = UTType(typeIdentifier) else {
            throw ImageError.unreadable
        }

        let kind = try classify(utType)
        // A MIME type should exist for any real image/video UTI; fall back to the
        // raw identifier only if the system has no registered MIME.
        let mimeType = utType.preferredMIMEType ?? typeIdentifier
        let fileExtension = utType.preferredFilenameExtension ?? ""

        // Dimensions come from the primary image's properties. Missing here means
        // a recognized-but-undecodable container (corrupt / truncated).
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ImageError.decodeFailed
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (width, height) = displayDimensions(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, orientation: orientation)

        return ImageMetadata(
            width: width, height: height,
            mimeType: mimeType, kind: kind, fileExtension: fileExtension)
    }

    /// Extract metadata from a MOVIE container's `data` via AVFoundation — the
    /// video counterpart to ``extract(from:)`` (which can't, since `CGImageSource`
    /// won't open movie containers). AVFoundation needs a URL, so the bytes are
    /// written to a temp file for the read.
    ///
    /// Dimensions are DISPLAY-oriented: the video track's `naturalSize` is run
    /// through its `preferredTransform` (which encodes any rotation), matching how
    /// the poster thumbnail — and a player — present it.
    ///
    /// Throws ``ImageError/unsupportedType(mime:)`` if the container has no video
    /// track, or ``ImageError/unreadable`` if the bytes can't be staged/opened.
    public static func videoMetadata(from data: Data) async throws -> ImageMetadata {
        let (mime, fileExtension) = MediaProbe.movieContainer(data)

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
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ImageError.unsupportedType(mime: mime)
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let displayed = naturalSize.applying(transform)
            let width = Int(abs(displayed.width).rounded())
            let height = Int(abs(displayed.height).rounded())

            let seconds = try await CMTimeGetSeconds(asset.load(.duration))
            let duration = seconds.isFinite && seconds > 0 ? seconds : nil

            return ImageMetadata(
                width: width, height: height, mimeType: mime, kind: .video,
                fileExtension: fileExtension, duration: duration)
        } catch let error as ImageError {
            throw error
        } catch {
            throw ImageError.unreadable
        }
    }

    /// Classify a container UTI into an ``AssetKind``, or throw
    /// ``ImageError/unsupportedType(mime:)`` for anything we don't ingest.
    ///
    /// Still images (`.image`) → `.image`; movies / audiovisual containers
    /// (`.movie`, `.audiovisualContent`) → `.video`. Everything else (PDF, plain
    /// data, …) is unsupported.
    private static func classify(_ utType: UTType) throws -> AssetKind {
        if utType.conforms(to: .image) {
            return .image
        }
        if utType.conforms(to: .movie) || utType.conforms(to: .audiovisualContent) {
            return .video
        }
        throw ImageError.unsupportedType(mime: utType.preferredMIMEType)
    }

    /// The canonical filename extension a stored blob of `mimeType` uses — the
    /// inverse of ``extract(from:)``'s `fileExtension` derivation.
    ///
    /// `extract` stores a blob under `utType.preferredFilenameExtension` and
    /// persists `utType.preferredMIMEType` as the asset's `mimeType`. An ``Asset``
    /// keeps only the MIME type, so to rebuild the blob's content-addressed URL
    /// (``MediaStore/blobURL(hash:fileExtension:)``) a reader maps the MIME back to
    /// the SAME canonical extension here. Because both directions resolve the one
    /// canonical `UTType` for the type, the round-trip is exact (e.g.
    /// `image/jpeg` ⇄ `jpeg`, `image/png` ⇄ `png`).
    ///
    /// Returns `""` for a MIME the system can't resolve — matching the empty
    /// extension `extract` would have stored (``MediaStore`` then uses a dotless
    /// path), so the URL still round-trips.
    public static func fileExtension(forMIMEType mimeType: String) -> String {
        // Delegated, not spelled twice: the mapping moved to `AtelierCapture` with the
        // rest of the path math when 092 · S6 gave the phone an archive to write, and
        // this package does not build for iOS. Kept here as the name every caller in
        // this package already uses.
        LibraryMediaPaths.fileExtension(forMIMEType: mimeType)
    }

    /// Apply an EXIF orientation to stored pixel dimensions, returning
    /// DISPLAY-oriented `(width, height)`.
    ///
    /// EXIF orientation values 5–8 encode a 90°/270° quarter-turn, so the stored
    /// axes are swapped relative to display — for those we swap width/height.
    /// Orientations 1–4 (identity, flips, 180°) leave the axes as-is. An
    /// out-of-range value is treated as identity.
    static func displayDimensions(
        pixelWidth: Int, pixelHeight: Int, orientation: Int
    ) -> (width: Int, height: Int) {
        switch orientation {
        case 5, 6, 7, 8:
            return (pixelHeight, pixelWidth)
        default:
            return (pixelWidth, pixelHeight)
        }
    }
}
