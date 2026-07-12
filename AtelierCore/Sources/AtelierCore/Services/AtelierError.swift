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
    /// An attempt to rename / delete / move the protected "Unsorted" folder
    /// (decision F3). Its id is `Collection.unsortedID`.
    case protectedCollection(id: UUID)
    /// A reparent that would make a folder its own ancestor/descendant — a
    /// cycle in the folder tree (decision F6).
    case folderCycle
    /// A database constraint (FK / NOT NULL / UNIQUE) was violated — mapped from
    /// GRDB so the raw `DatabaseError` never leaks (A2/C7).
    case constraintViolation
    /// Any other persistence failure. `detail` carries the SQLite result code +
    /// message when mapped from GRDB so disk-full / corruption aren't opaque (G10).
    case persistenceFailure(detail: String? = nil)
}

extension AtelierError {
    /// Maps an arbitrary thrown error into an `AtelierError` (C7). Used by the
    /// write funnel so GRDB types never cross the public boundary (A2):
    ///
    /// - an existing `AtelierError` passes through unchanged (validation /
    ///   `.notFound` thrown inside the funnel survive intact);
    /// - a GRDB `DatabaseError` whose primary result code is a constraint
    ///   violation (FK / NOT NULL / UNIQUE) becomes `.constraintViolation`;
    /// - everything else becomes `.persistenceFailure` with the SQLite detail.
    init(mapping error: Error) {
        if let atelierError = error as? AtelierError {
            self = atelierError
            return
        }
        if let dbError = error as? DatabaseError,
           dbError.resultCode.primaryResultCode == .SQLITE_CONSTRAINT {
            self = .constraintViolation
        } else if let dbError = error as? DatabaseError {
            let code = dbError.resultCode.rawValue
            let message = dbError.message ?? dbError.expandedDescription
            self = .persistenceFailure(detail: "SQLite \(code): \(message)")
        } else {
            self = .persistenceFailure(detail: String(describing: error))
        }
    }
}
