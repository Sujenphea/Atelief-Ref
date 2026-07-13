// AtelierCore — centralized input validation (chunk 5, decision C8)
//
// Pure, side-effect-free helpers that THROW the right ``AtelierError`` on bad
// input. One place, run by the write funnel BEFORE any row is written (C8), so
// no mutation can bypass it. GRDB-free: these operate on plain values, so they
// are unit-testable in isolation.

import Foundation

/// The C8 validation rules, gathered into one namespace.
///
/// Each helper either returns the normalized value (names, hashes) or returns
/// `Void`, and throws a specific `AtelierError` case on rejection. The funnel
/// calls these before opening a write so a rejected mutation never touches the
/// database.
enum Validation {

    /// Trim a collection name and reject empty/whitespace-only (`.invalidName`).
    /// Returns the trimmed name to persist (explicit normalization).
    @discardableResult
    static func collectionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AtelierError.invalidName }
        return trimmed
    }

    /// Trim a tag name and reject empty/whitespace-only (`.invalidName`).
    /// Returns the trimmed name to persist (mirrors ``collectionName``).
    @discardableResult
    static func tagName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AtelierError.invalidName }
        return trimmed
    }

    /// Trim a space name and reject empty/whitespace-only (`.invalidName`).
    /// Returns the trimmed name to persist (mirrors ``collectionName``).
    @discardableResult
    static func spaceName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AtelierError.invalidName }
        return trimmed
    }

    /// Enforce the ``SpaceItem`` discriminator invariant (005 O1): an `.asset`
    /// row MUST carry an `assetID`; an element row (`.frame` / `.text`) must NOT
    /// (`.invalidSpaceItem`). Keeps the single discriminated table's two row
    /// shapes from ever crossing, whichever insert path builds the row.
    static func spaceItem(kind: SpaceItemKind, assetID: UUID?) throws {
        switch kind {
        case .asset:
            guard assetID != nil else { throw AtelierError.invalidSpaceItem }
        case .frame, .text:
            guard assetID == nil else { throw AtelierError.invalidSpaceItem }
        }
    }

    /// Reject non-positive intrinsic dimensions (`.invalidDimensions`).
    static func dimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw AtelierError.invalidDimensions }
    }

    /// Reject a negative byte count (`.invalidFileSize`). Zero is allowed (an
    /// empty blob is degenerate but not malformed).
    static func fileSize(_ fileSize: Int) throws {
        guard fileSize >= 0 else { throw AtelierError.invalidFileSize }
    }

    /// Require a non-empty, lowercased-hex content hash (`.invalidBlobHash`).
    /// Returns the normalized (lowercased) hash so dedup compares a canonical
    /// form.
    @discardableResult
    static func blobHash(_ hash: String) throws -> String {
        let normalized = hash.lowercased()
        guard !normalized.isEmpty,
              normalized.allSatisfy(\.isHexDigit) else {
            throw AtelierError.invalidBlobHash
        }
        return normalized
    }

    /// Reject a canvas placement with any non-finite (NaN/inf) coordinate, or a
    /// non-positive width/height (`.invalidPlacement`). Only supplied (non-nil)
    /// values are checked — a placement may leave any field unset. This closes
    /// the Phase-1 NaN/inf bug class (C8). `x`/`y` may be negative (the canvas
    /// is infinite); only `w`/`h` must be strictly positive.
    static func canvasPlacement(x: Double?, y: Double?, w: Double?, h: Double?) throws {
        for value in [x, y, w, h] {
            if let value, !value.isFinite { throw AtelierError.invalidPlacement }
        }
        if let w, w <= 0 { throw AtelierError.invalidPlacement }
        if let h, h <= 0 { throw AtelierError.invalidPlacement }
    }

    /// Enforce the per-platform `originalURL` rule (`.missingOriginalURL`):
    /// required (non-nil, non-empty) for the remote platforms
    /// (`.twitter/.pinterest/.instagram/.cosmos/.web`); optional for the local
    /// capture paths (`.localPaste/.localDrag`), which have no canonical URL.
    static func originalURL(_ url: String?, platform: Platform) throws {
        switch platform {
        case .localPaste, .localDrag:
            return
        case .twitter, .pinterest, .instagram, .cosmos, .web:
            let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                throw AtelierError.missingOriginalURL(platform: platform)
            }
        }
    }
}
