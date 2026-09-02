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
    /// A ``SpaceItem`` violated its discriminator invariant (005 O1): an
    /// `.asset` row without an `assetID`, or an element row that carried one.
    case invalidSpaceItem
    /// A content ingest (003 · O1) was handed a kind that isn't media-less — a
    /// byte-backed `.image`/`.video` must go through the blob ``AppServices/ingest``
    /// path, and a media-less kind not yet modelled (`.link`/`.tweet` before
    /// C2/C3) is rejected here too.
    case invalidContentKind
    /// A media-less content draft (003 · O1) had no payload for its kind (e.g. a
    /// `.color` draft with no color).
    case missingPayload
    /// A `.color` content draft's hex was not a valid 3- or 6-digit hex color
    /// (003 · C1).
    case invalidColor
    /// A `.link` content draft's URL was not a usable http(s) URL (003 · C2).
    case invalidLinkURL
    /// A `.tweet` content draft had no usable tweet id, or no substance at all
    /// (neither text nor media) — not a usable tweet (003 · C3).
    case emptyTweet
    /// A saved search's stored `rules` JSON could not be decoded (corrupt, or a
    /// blob so malformed even the tolerant `SearchRules` codec returns `nil`) —
    /// so it cannot be evaluated (015). Distinct from `.notFound`: the search row
    /// exists, its rules don't parse.
    case invalidSavedSearchRules(id: UUID)
    /// ``AppServices/searchAssets`` was asked for `.relevance` sort together with
    /// a keyset `after:` cursor (044/045 · 3A). The cursor is defined on the
    /// stable `(created_at, id)` recency order; relevance isn't that order, so a
    /// cursor into it is meaningless. Explicit over silently returning a wrong or
    /// duplicated page — relevance results are consumed whole (bounded by `limit`).
    case relevanceSortUnpageable
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

// MARK: - LocalizedError (6A)

/// Every case carries a sentence a person can read (6A).
///
/// Before this, every surface that could show a failure wrote its own `switch`
/// over these cases — `IngestionModel.message(for:)`, `SpaceModel.message(for:)`
/// and three controller copies — and each one had a `default:` arm. A case added
/// here therefore reached the user as whatever that arm said, in five places, and
/// nothing failed. The table below has **no `default`**: a new case does not
/// compile until someone has written its sentence, once, here.
///
/// These are USER-FACING sentences, not debug descriptions. They say what went
/// wrong in the terms of the thing the person was doing ("that folder", "this
/// smart collection"), name no table, no id and no SQLite code, and do not end in
/// a colon expecting an appended payload. `.persistenceFailure`'s detail is the
/// one exception, and it is deliberately kept out of the sentence: the diagnostic
/// belongs in a log, not in an alert.
extension AtelierError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let entity, _):
            "Couldn't find that \(Self.noun(for: entity))."
        case .invalidName:
            "A name can't be empty."
        case .invalidDimensions:
            "That image didn't report a usable width and height."
        case .invalidFileSize:
            "That file didn't report a usable size."
        case .invalidBlobHash:
            "That file's fingerprint was missing or malformed."
        case .invalidPlacement:
            "That position on the board isn't a place something can go."
        case .missingOriginalURL(let platform):
            "A capture from \(Self.noun(for: platform)) needs the address of the page it came from."
        case .protectedCollection:
            "Unsorted is built in — it can't be renamed, moved, or deleted."
        case .folderCycle:
            "A folder can't be moved inside itself."
        case .invalidSpaceItem:
            "That board element is neither a placed item nor a shape, so it can't be saved."
        case .invalidContentKind:
            "That kind of item can't be created this way."
        case .missingPayload:
            "That item had nothing in it to save."
        case .invalidColor:
            "That isn't a colour value the library can read."
        case .invalidLinkURL:
            "That isn't a web address the library can open."
        case .emptyTweet:
            "That post had no text and no media, so there was nothing to save."
        case .invalidSavedSearchRules:
            "This smart collection's search can't be read, so it can't be run."
        case .relevanceSortUnpageable:
            "Best-match results arrive all at once — they can't be loaded a page at a time."
        case .constraintViolation:
            "That change would have left the library inconsistent, so nothing was saved."
        case .persistenceFailure:
            "The library couldn't be written to. Nothing was saved."
        }
    }

    /// The human noun for a table-ish `entity` string. `.notFound` carries the
    /// storage name (`"collection_item"`, `"saved_search"`) because that is what
    /// the throwing site knows; a person has never seen those words. An entity
    /// with no mapping degrades to "item" — the sentence stays readable rather
    /// than leaking a table name, and this is a lookup, not the exhaustive table
    /// above, so a `default` here costs nothing.
    static func noun(for entity: String) -> String {
        switch entity {
        case "collection": "folder"
        case "collection_item": "item in that folder"
        case "asset": "item"
        case "source": "capture"
        case "space": "space"
        case "space_item": "element on that board"
        case "saved_search": "smart collection"
        case "job": "import"
        case "tag": "tag"
        default: "item"
        }
    }

    /// The human name of a ``Platform`` for the one sentence that needs it.
    static func noun(for platform: Platform) -> String {
        switch platform {
        case .twitter: "X"
        case .pinterest: "Pinterest"
        case .instagram: "Instagram"
        case .cosmos: "Cosmos"
        case .rednote: "RedNote"
        case .web: "the web"
        case .clipboard: "the clipboard"
        case .localPaste: "a paste"
        case .localDrag: "a drag"
        }
    }
}
