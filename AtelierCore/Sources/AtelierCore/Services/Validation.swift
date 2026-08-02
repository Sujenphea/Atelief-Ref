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

    /// Disambiguate `desired` against its sibling names, Finder-style (043 · open
    /// item 2 · policy 2c). A name with no collision is returned unchanged; a
    /// collision appends the smallest ` N` (N ≥ 2) that is free — so a folder
    /// named "Refs" created three times under one parent becomes "Refs",
    /// "Refs 2", "Refs 3". An already-numbered desired name ("Refs 2") has its
    /// trailing index stripped first so families collapse onto one base rather
    /// than nesting ("Refs 2 2"). Matching is case-insensitive; the ORIGINAL
    /// casing of the base is preserved.
    ///
    /// `desired` must already be trimmed/non-empty (run `collectionName` first).
    /// `siblings` is the names of the folders the new/renamed folder will sit
    /// beside — for a rename, EXCLUDING the folder itself (else it collides with
    /// its own current name and drifts on every no-op rename).
    static func uniqueCollectionName(_ desired: String, among siblings: [String]) -> String {
        let taken = Set(siblings.map { $0.lowercased() })
        guard taken.contains(desired.lowercased()) else { return desired }
        let base = strippedTrailingIndex(desired)
        var k = 2
        while taken.contains("\(base) \(k)".lowercased()) { k += 1 }
        return "\(base) \(k)"
    }

    /// Drop a trailing " N" (N an integer ≥ 2) so "Refs 2" → "Refs"; leaves a
    /// name with no such suffix — and "Refs 0"/"Refs 1" (below the numbering
    /// floor) — unchanged. Whitespace-only bases can't occur: `desired` is
    /// pre-trimmed, so a match always leaves a non-empty base.
    private static func strippedTrailingIndex(_ name: String) -> String {
        guard let r = name.range(of: #"\s+\d+$"#, options: .regularExpression),
              let n = Int(name[r].trimmingCharacters(in: .whitespaces)), n >= 2
        else { return name }
        return String(name[..<r.lowerBound])
    }

    /// Normalize a tag name for persist/lookup: trim, drop a single leading `#`
    /// (a UI affordance — the search prompt reads "…or #tag" — not part of the
    /// stored name), then trim again (handles "# sf"). Non-throwing; may return
    /// empty. Keeps case (search LIKE/FTS are ASCII-case-insensitive).
    static func normalizedTagName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Trim + normalize a tag name and reject empty/whitespace-only
    /// (`.invalidName`). Strips a leading `#` so `#sf` and `sf` are one tag and
    /// the `sf` search-vocabulary prefix resolves it. Returns the name to persist.
    @discardableResult
    static func tagName(_ name: String) throws -> String {
        let trimmed = normalizedTagName(name)
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

    /// Trim a saved-search name and reject empty/whitespace-only (`.invalidName`).
    /// Returns the trimmed name to persist (mirrors ``collectionName``).
    @discardableResult
    static func savedSearchName(_ name: String) throws -> String {
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

    /// Normalize + validate a media-less content draft (003 · O1), returning a
    /// draft with a canonical payload and DERIVED `dedupKey` / `searchText`
    /// (server-authoritative). Rejects a byte-backed or not-yet-modelled kind
    /// (`.invalidContentKind`), a missing payload (`.missingPayload`), or a
    /// malformed color (`.invalidColor`). One place, run in the funnel before any
    /// row is written — the media-less analogue of the `ingest` dimension/blob
    /// checks.
    static func contentDraft(_ draft: AssetContentDraft) throws -> AssetContentDraft {
        switch draft.kind {
        case .image, .video:
            // Byte kinds use the blob `ingest` path, not the content path.
            throw AtelierError.invalidContentKind
        case .color:
            guard let color = draft.payload.color else { throw AtelierError.missingPayload }
            let hex = try colorHex(color.hex)
            // Canonical hex is the payload, the dedup key, AND the FTS text
            // (v1 has no color name yet — 003 · C1).
            return AssetContentDraft(
                kind: .color,
                payload: AssetPayload(color: ColorPayload(hex: hex)),
                dedupKey: hex,
                searchText: hex)
        case .link:
            guard let link = draft.payload.link else { throw AtelierError.missingPayload }
            let url = try linkURL(link.url)
            // Canonical URL is the dedup key; the FTS text is title + description
            // + host so a link is findable by name or domain (003 · C2).
            let host = URLComponents(string: url)?.host ?? ""
            let searchText = [link.title, link.description, host]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return AssetContentDraft(
                kind: .link,
                payload: AssetPayload(link: LinkPayload(
                    url: url, title: link.title, description: link.description)),
                dedupKey: url,
                searchText: searchText.isEmpty ? nil : searchText)
        case .tweet:
            guard let tweet = draft.payload.tweet else { throw AtelierError.missingPayload }
            // The numeric tweet id is the identity + dedup key.
            let id = try tweetID(tweet.tweetID)
            let text = tweet.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let media = tweet.media.filter {
                !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // A usable tweet has substance: text OR at least one media reference.
            guard text?.isEmpty == false || !media.isEmpty else {
                throw AtelierError.emptyTweet
            }
            let handle = tweet.authorHandle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = tweet.authorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            // FTS text is the tweet text + author, so a tweet is findable by
            // content or by who wrote it (003 · C3).
            let searchText = [text, handle, name]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return AssetContentDraft(
                kind: .tweet,
                payload: AssetPayload(tweet: TweetPayload(
                    tweetID: id,
                    text: text?.isEmpty == false ? text : nil,
                    authorHandle: handle?.isEmpty == false ? handle : nil,
                    authorName: name?.isEmpty == false ? name : nil,
                    media: media)),
                dedupKey: id,
                searchText: searchText.isEmpty ? nil : searchText)
        }
    }

    /// Canonicalize a user-typed color to `#rrggbb` lowercase, or throw
    /// `.invalidColor` (003 · C1). Accepts an optional `#` and 3-digit shorthand
    /// so equal colors written differently share one dedup key.
    @discardableResult
    static func colorHex(_ raw: String) throws -> String {
        guard let canonical = ColorPayload.canonicalHex(raw) else {
            throw AtelierError.invalidColor
        }
        return canonical
    }

    /// Canonicalize a user-typed URL (003 · C2), or throw `.invalidLinkURL`.
    /// Prepends `https://` when scheme-less; the canonical form is the dedup key.
    @discardableResult
    static func linkURL(_ raw: String) throws -> String {
        guard let canonical = LinkPayload.canonicalURL(raw) else {
            throw AtelierError.invalidLinkURL
        }
        return canonical
    }

    /// Extract the numeric tweet id from a raw id or status URL (003 · C3), or
    /// throw `.emptyTweet`. The id is the identity + dedup key, so a tweet
    /// captured via `x.com` or `twitter.com` collapses to one asset.
    @discardableResult
    static func tweetID(_ raw: String) throws -> String {
        guard let id = TweetPayload.canonicalTweetID(raw) else {
            throw AtelierError.emptyTweet
        }
        return id
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
    /// (`.twitter/.pinterest/.instagram/.cosmos/.rednote/.web`); optional for the
    /// local capture paths (`.localPaste/.localDrag`), which have no canonical URL.
    static func originalURL(_ url: String?, platform: Platform) throws {
        switch platform {
        case .localPaste, .localDrag:
            return
        case .twitter, .pinterest, .instagram, .cosmos, .rednote, .web:
            let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                throw AtelierError.missingOriginalURL(platform: platform)
            }
        }
    }
}
