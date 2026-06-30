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
