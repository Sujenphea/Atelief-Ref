// AtelierIngestion — image-utility errors (chunk 3, decision C7)
//
// The typed failures the pure image utilities raise when bytes can't be turned
// into a usable image source, metadata, or thumbnail. Kept deliberately narrow:
// these describe *why the bytes failed*, not pipeline concerns. Chunk 4's
// `IngestError` wraps these to add per-item ingestion context (decision C8).

import Foundation

/// A failure raised by the pure image utilities (metadata extraction /
/// thumbnail generation) — decision C7.
///
/// `Equatable` so tests can assert on the exact case. Cases are ordered from
/// "can't even read the container" to "read it but can't use it".
public enum ImageError: Error, Equatable {
    /// The bytes could not be opened as an image source at all — zero bytes, or
    /// data ImageIO cannot recognize as any container.
    case unreadable

    /// The container decoded, but its type is not a still image or video we
    /// accept (e.g. a PDF or plain data). `mime` is the detected UTI's MIME
    /// type when one exists, for diagnostics.
    case unsupportedType(mime: String?)

    /// A recognized image container that failed to decode — corrupt or
    /// truncated bytes, or missing the properties needed to read dimensions.
    case decodeFailed

    /// Thumbnail generation failed: no thumbnail could be produced from the
    /// source, or the resulting image could not be encoded.
    case thumbnailFailed
}
