// AtelierCore — public input/output value types for App Services (chunk 5)
//
// The drafts a caller hands to the funnel, the optional canvas placement, and
// the ingest result. Drafts carry only the caller-supplied PROVENANCE FACTS:
// they hold no `id` / `created_at` / `source_id` — the service generates those
// (server-authoritative, A4/C6). All GRDB-free: the public surface exposes
// plain value types, never a record or a GRDB type (A2).

import Foundation

/// The caller-supplied facts about an asset to ingest. No `id`, no `createdAt`,
/// no `sourceId` — the service generates identity + timestamps and links the
/// source (server-authoritative).
public struct AssetDraft: Sendable, Equatable {
    public var kind: AssetKind
    public var blobHash: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var duration: Double?
    public var fileSize: Int
    public var downloadState: DownloadState

    public init(
        kind: AssetKind,
        blobHash: String,
        mimeType: String,
        width: Int,
        height: Int,
        duration: Double? = nil,
        fileSize: Int,
        downloadState: DownloadState
    ) {
        self.kind = kind
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
        self.fileSize = fileSize
        self.downloadState = downloadState
    }
}

/// The caller-supplied facts about a MEDIA-LESS asset to ingest (003 · O1) — a
/// `tweet` / `link` / `color`. The sibling of ``AssetDraft`` for the content
/// path: no `blobHash` / `mimeType` / dims / `fileSize` (there are no bytes),
/// just the `kind` and its ``AssetPayload``. The service normalizes the payload
/// and derives `dedupKey` / `searchText` (server-authoritative) — so a caller
/// supplies intent, not canonical form.
///
/// Build one via a kind factory (e.g. ``color(hex:)``) so the shape is always
/// valid for its kind; the funnel re-validates (C8) regardless.
public struct AssetContentDraft: Sendable, Equatable {
    /// A media-less kind (`.tweet` / `.link` / `.color`). A byte-backed kind is
    /// rejected by validation (`.invalidContentKind`).
    public var kind: AssetKind
    /// The kind's substance. The funnel normalizes this (e.g. canonical hex).
    public var payload: AssetPayload
    /// Optional caller-supplied dedup key; the funnel derives the canonical one
    /// per kind when omitted (color → canonical hex).
    public var dedupKey: String?
    /// Optional caller-supplied FTS text; the funnel derives a default per kind.
    public var searchText: String?

    public init(
        kind: AssetKind,
        payload: AssetPayload,
        dedupKey: String? = nil,
        searchText: String? = nil
    ) {
        self.kind = kind
        self.payload = payload
        self.dedupKey = dedupKey
        self.searchText = searchText
    }

    /// A `color` content draft from a user-typed hex. Not canonicalized here —
    /// the funnel's ``Validation`` normalizes to `#rrggbb` and rejects a
    /// malformed color (`.invalidColor`); this only shapes the payload.
    public static func color(hex: String) -> AssetContentDraft {
        AssetContentDraft(kind: .color, payload: AssetPayload(color: ColorPayload(hex: hex)))
    }

    /// A `link` content draft from a user-typed URL (+ optional metadata). Not
    /// canonicalized here — the funnel's ``Validation`` normalizes the URL and
    /// rejects a non-http(s) one (`.invalidLinkURL`); this only shapes the payload.
    public static func link(
        url: String, title: String? = nil, description: String? = nil
    ) -> AssetContentDraft {
        AssetContentDraft(
            kind: .link,
            payload: AssetPayload(link: LinkPayload(url: url, title: title, description: description)))
    }

    /// A `tweet` content draft (003 · C3). `tweetID` may be a bare id or a status
    /// URL — the funnel's ``Validation`` extracts the numeric id (the dedup key),
    /// rejects a tweet with no id / no substance (`.emptyTweet`), and derives the
    /// canonical provenance URL. This only shapes the payload.
    public static func tweet(
        tweetID: String, text: String? = nil,
        authorHandle: String? = nil, authorName: String? = nil,
        media: [TweetMedia] = []
    ) -> AssetContentDraft {
        AssetContentDraft(
            kind: .tweet,
            payload: AssetPayload(tweet: TweetPayload(
                tweetID: tweetID, text: text, authorHandle: authorHandle,
                authorName: authorName, media: media)))
    }
}

/// The card-image bytes a MEDIA-LESS asset may ALSO carry (003 · C3, Option 3):
/// a tweet keeps its `kind`/`payload` content identity AND stores its card image
/// as a real blob, so the grid shows the picture instead of a text card. The
/// byte-derived facts the pipeline already extracted (hash / mime / dims / size);
/// the funnel validates them and fills the asset's blob columns. `nil` ⇒ the pure
/// media-less path (no bytes). Dedup is UNAFFECTED — a tweet's identity is its
/// tweet-id, not these bytes, so two captures with different card images still
/// resolve to one tweet.
public struct ContentBlobFacts: Sendable, Equatable {
    public var blobHash: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var fileSize: Int

    public init(
        blobHash: String, mimeType: String,
        width: Int, height: Int, fileSize: Int
    ) {
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.fileSize = fileSize
    }
}

/// The caller-supplied provenance of an asset. Carries `capturedAt` (a
/// provenance fact the caller owns) but no `id` — the service generates the
/// source identity. `rawMetadata` defaults to an empty object.
public struct SourceDraft: Sendable, Equatable {
    public var platform: Platform
    public var originalURL: String?
    public var authorHandle: String?
    public var authorName: String?
    public var title: String?
    public var capturedAt: Date
    public var rawMetadata: JSONValue

    public init(
        platform: Platform,
        originalURL: String? = nil,
        authorHandle: String? = nil,
        authorName: String? = nil,
        title: String? = nil,
        capturedAt: Date,
        rawMetadata: JSONValue = .object([:])
    ) {
        self.platform = platform
        self.originalURL = originalURL
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.title = title
        self.capturedAt = capturedAt
        self.rawMetadata = rawMetadata
    }
}

/// An optional canvas placement supplied at ingest time. Any field may be unset
/// (the canvas view assigns one later); supplied fields are validated finite,
/// with `w`/`h` strictly positive (C8).
public struct CanvasPlacement: Sendable, Equatable {
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?
    public var z: Int?

    public init(
        x: Double? = nil, y: Double? = nil,
        w: Double? = nil, h: Double? = nil, z: Int? = nil
    ) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.z = z
    }
}

// MARK: - Query inputs (GRDB-free, A2)

/// How a multi-tag filter combines (007 · search). A query-only value (never
/// persisted, so it lives here rather than in the on-disk `Enums`).
///
/// - `.all`: an asset must carry EVERY listed tag (progressive narrowing — the
///   reference-library default).
/// - `.any`: an asset carrying ANY listed tag matches (additive).
/// A `String` rawValue so a multi-tag combine mode can be persisted inside a
/// saved search's rules JSON (015) — `.all`/`.any` survive reordering (the
/// open-ended-enum discipline). The rawValue is the stable on-disk token.
public enum TagMatch: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case all
    case any
}

// MARK: - Read outputs (GRDB-free, A2)

/// One membership of a collection joined to its full ``Asset`` and that asset's
/// ``Source`` — the public, GRDB-free projection of the P14 joined read.
///
/// The persistence layer fetches an internal `CollectionItemRow`
/// (`FetchableRecord`); the read API maps it to this value type so no GRDB type
/// crosses the public boundary (A2). Metadata only — never blob bytes (P16).
public struct CollectionItemDetail: Sendable, Equatable {
    /// The membership row (placement / order live here).
    public let item: CollectionItem
    /// The asset the membership points at.
    public let asset: Asset
    /// The asset's required provenance.
    public let source: Source

    public init(item: CollectionItem, asset: Asset, source: Source) {
        self.item = item
        self.asset = asset
        self.source = source
    }
}

/// One root collection's Unsorted-screen stack card (009 · N4): the collection,
/// its DIRECT item count, and the blob hashes of its most recently added
/// byte-backed items (newest first, at most the read's `limit`) — enough to
/// draw the fanned drop target without another round-trip. `Equatable` so the
/// view model can skip republishing an unchanged row set (15A).
public struct CollectionStackPreview: Sendable, Equatable {
    /// The root collection this card represents (drop target for a move).
    public let collection: Collection
    /// The collection's DIRECT item count (media-less kinds included).
    public let itemCount: Int
    /// Newest-first thumbnail hashes for the fan; media-less items are skipped,
    /// so this can be shorter than the limit (or empty — no fan).
    public let recentBlobHashes: [String]

    public init(collection: Collection, itemCount: Int, recentBlobHashes: [String]) {
        self.collection = collection
        self.itemCount = itemCount
        self.recentBlobHashes = recentBlobHashes
    }
}

/// One Home "Spaces" card (009 · N4), the space analog of
/// ``CollectionStackPreview``: the space, its placed-item count, and the blob
/// hashes of its most recently added asset items (newest first, at most the
/// read's `limit`) for the fanned pile. `Equatable` so the view model can skip
/// republishing an unchanged set.
public struct SpaceStackPreview: Sendable, Equatable {
    /// The space this card represents.
    public let space: Space
    /// The space's placed-item count (element rows included).
    public let itemCount: Int
    /// Newest-first thumbnail hashes for the fan; element rows and media-less
    /// assets are skipped, so this can be shorter than the limit (or empty).
    public let recentBlobHashes: [String]

    public init(space: Space, itemCount: Int, recentBlobHashes: [String]) {
        self.space = space
        self.itemCount = itemCount
        self.recentBlobHashes = recentBlobHashes
    }
}

/// One row of a ``Space`` board joined to its media (005). For an ASSET row the
/// `asset` + `source` are present; for a freeform ELEMENT row (`kind ==
/// .frame/.text`) both are `nil` and the row's ``ElementStyle`` lives in
/// `item.style`. The public, GRDB-free projection of the space read. Metadata
/// only — never blob bytes (P16).
public struct SpaceItemDetail: Sendable, Equatable {
    /// The board row (placement / kind / style live here).
    public let item: SpaceItem
    /// The asset an `.asset` row draws; `nil` for element rows.
    public let asset: Asset?
    /// The asset's provenance; `nil` for element rows.
    public let source: Source?

    public init(item: SpaceItem, asset: Asset?, source: Source?) {
        self.item = item
        self.asset = asset
        self.source = source
    }
}

/// An ``Asset`` joined to its required ``Source`` — the unit of the read/search
/// API. Metadata only (P16): provenance facts, never the blob bytes.
public struct AssetDetail: Sendable, Equatable {
    /// The captured media's metadata.
    public let asset: Asset
    /// Where it came from (required — C6).
    public let source: Source

    public init(asset: Asset, source: Source) {
        self.asset = asset
        self.source = source
    }
}

/// An opaque keyset (seek) cursor for paging ``AppServices/searchAssets`` (P16).
///
/// Carries the sort key of the LAST row of the previous page — the asset's
/// `createdAt` and `id`. The next call returns only rows strictly after it in
/// the `(created_at DESC, id DESC)` order, so paging never drifts or repeats
/// even as new assets are ingested (no OFFSET).
public struct AssetPageCursor: Sendable, Equatable {
    /// `createdAt` of the last row returned.
    public let createdAt: Date
    /// `id` of the last row returned (breaks ties on equal `createdAt`).
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
}

/// The outcome of an ``AppServices/ingest(_:from:into:placement:)``: the
/// resolved ``Asset`` (newly inserted or reused) and whether the 18A dedup rule
/// reused an existing asset.
public struct IngestResult: Sendable, Equatable {
    /// The asset now backing the membership — freshly created or deduped.
    public let asset: Asset
    /// `true` when an existing asset+source were reused (18A); `false` when a
    /// new asset was inserted.
    public let wasDeduplicated: Bool

    public init(asset: Asset, wasDeduplicated: Bool) {
        self.asset = asset
        self.wasDeduplicated = wasDeduplicated
    }
}
