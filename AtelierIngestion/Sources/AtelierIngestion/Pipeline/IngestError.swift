// AtelierIngestion — the per-item pipeline error (chunk 4, decision C8)
//
// The typed failure a single ingestion can end in. Unlike `ImageError` (which
// describes only why the BYTES failed) or `AtelierError` (which describes only
// why the DB write failed), `IngestError` names the PIPELINE STAGE that failed,
// wrapping the lower-level error where it carries useful detail. This is what
// makes a batch partial-failure-tolerant (C8): one bad file becomes one
// `.failed(IngestError)` outcome, never an aborted batch.

import Foundation
import AtelierCore

/// A failure of a single item's ingestion, named by the pipeline stage that
/// produced it (decision C8).
///
/// `Equatable` so tests can assert on the exact stage. The `init(mapping:)`
/// initializer folds the lower-level `ImageError` / `AtelierError` into the
/// matching stage, so the pipeline body can `throw` freely and convert once.
public enum IngestError: Error, Equatable {
    /// The source bytes could not be read at all — a missing/unreadable file
    /// URL, zero bytes, or data ImageIO cannot recognize as any container.
    case unreadableSource

    /// The bytes decoded to a container whose type we do not ingest (e.g. a PDF
    /// or plain data). `mime` is the detected MIME when one exists, for
    /// diagnostics.
    case unsupportedType(mime: String?)

    /// A recognized image container that failed to decode — corrupt or
    /// truncated bytes, or missing the properties needed to read dimensions.
    case decodeFailed

    /// Thumbnail generation failed for one or more tiers.
    case thumbnailFailed

    /// Writing the content-addressed blob (or a thumbnail) to disk failed.
    case blobWriteFailed

    /// The metadata persistence (the `AppServices.ingest` transaction) failed;
    /// wraps the underlying ``AtelierError`` (P15/C8).
    case persistence(AtelierError)
}

extension IngestError {
    /// Fold an arbitrary thrown error into the matching pipeline stage (C8).
    ///
    /// - an existing `IngestError` passes through unchanged (a stage that has
    ///   already classified its failure survives intact);
    /// - an `ImageError` maps to its stage: `.unreadable` →
    ///   `.unreadableSource`, `.unsupportedType` → `.unsupportedType`,
    ///   `.decodeFailed` → `.decodeFailed`, `.thumbnailFailed` →
    ///   `.thumbnailFailed`;
    /// - an `AtelierError` becomes `.persistence`;
    /// - anything else (e.g. a raw file-IO error from reading a URL or writing a
    ///   blob) becomes `.blobWriteFailed`, the sensible IO-failure default.
    init(mapping error: Error) {
        if let ingestError = error as? IngestError {
            self = ingestError
            return
        }
        if let imageError = error as? ImageError {
            switch imageError {
            case .unreadable:
                self = .unreadableSource
            case .unsupportedType(let mime):
                self = .unsupportedType(mime: mime)
            case .decodeFailed:
                self = .decodeFailed
            case .thumbnailFailed:
                self = .thumbnailFailed
            }
            return
        }
        if let atelierError = error as? AtelierError {
            self = .persistence(atelierError)
            return
        }
        self = .blobWriteFailed
    }
}
