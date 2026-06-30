// AtelierCore — typed domain errors (chunk 5, decisions C7/A2)
//
// The single public error type the App Services surface throws. GRDB / SQLite
// errors are mapped to these cases at the persistence boundary (the write
// funnel) so a GRDB type NEVER escapes the package's public API (A2). The
// mapping initializer is `internal`; the cases are `public`.

import Foundation
import GRDB

/// Every failure the public ``AppServices`` surface can surface (C7).
///
/// Explicit, exhaustive cases — callers switch on intent (`.notFound`,
/// `.invalidName`, …), never on an opaque SQLite code. GRDB's `DatabaseError`
/// is collapsed into `.constraintViolation` / `.persistenceFailure` by
/// ``init(mapping:)`` so the toolkit stays confined to the package (A2).
public enum AtelierError: Error, Equatable {
    /// A required entity was absent. `entity` is the table-ish name (e.g.
    /// `"collection"`, `"asset"`, `"collection_item"`); `id` is what was looked
    /// up.
    case notFound(entity: String, id: UUID)
    /// A collection name was empty (or whitespace-only) after trimming.
    case invalidName
    /// `width`/`height` were not both strictly positive.
    case invalidDimensions
    /// `fileSize` was negative.
    case invalidFileSize
    /// `blobHash` was empty or not lowercased hex.
    case invalidBlobHash
    /// A canvas placement carried a non-finite (NaN/inf) coordinate, or a
    /// non-positive width/height — the Phase-1 NaN/inf bug class (C8).
    case invalidPlacement
    /// A platform that requires provenance was missing its `originalURL`.
    case missingOriginalURL(platform: Platform)
    /// A database constraint (FK / NOT NULL / UNIQUE) was violated — mapped from
    /// GRDB so the raw `DatabaseError` never leaks (A2/C7).
    case constraintViolation
    /// Any other persistence failure, mapped from a non-constraint GRDB error.
    case persistenceFailure
}

extension AtelierError {
    /// Maps an arbitrary thrown error into an `AtelierError` (C7). Used by the
    /// write funnel so GRDB types never cross the public boundary (A2):
    ///
    /// - an existing `AtelierError` passes through unchanged (validation /
    ///   `.notFound` thrown inside the funnel survive intact);
    /// - a GRDB `DatabaseError` whose primary result code is a constraint
    ///   violation (FK / NOT NULL / UNIQUE) becomes `.constraintViolation`;
    /// - everything else becomes `.persistenceFailure`.
    init(mapping error: Error) {
        if let atelierError = error as? AtelierError {
            self = atelierError
            return
        }
        if let dbError = error as? DatabaseError,
           dbError.resultCode.primaryResultCode == .SQLITE_CONSTRAINT {
            self = .constraintViolation
        } else {
            self = .persistenceFailure
        }
    }
}
