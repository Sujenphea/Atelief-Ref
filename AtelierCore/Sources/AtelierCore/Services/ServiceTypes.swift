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
