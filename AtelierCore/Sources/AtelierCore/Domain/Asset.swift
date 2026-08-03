// AtelierCore — Asset
//
// Mirrors 003 §data-model · Asset exactly. A plain value type: no persistence,
// no validation (GRDB conformance and the App Services funnel land later).

import Foundation

/// A single captured item and its provenance (003 §data-model · multi-kind).
///
/// Provenance is required: every asset references a ``Source`` — even a pasted
/// image (`local_paste`), a dragged file (`local_drag`), or a media-less color
/// (decision C6); `sourceId` is not optional.
///
/// **Byte columns are nullable (003 · O1).** `image` / `video` are byte-backed
/// (a `blobHash` + `mimeType` + dims + `fileSize`); the media-less kinds
/// (`tweet` / `link` / `color`) leave those nil and carry their substance in
/// ``payload``. Never nil-check bytes directly — read ``content`` (the
/// ``AssetContent`` render seam), which is total over every `(kind, blobHash,
/// payload)` combination.
public struct Asset: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// `image` | `video` | `tweet` | `link` | `color` (extensible).
    public var kind: AssetKind
    /// Content hash → file in `blobs/`. `nil` for a media-less kind (003 · O1).
    /// Enables dedup (non-unique: one blob, many asset rows).
    public var blobHash: String?
    /// e.g. `image/jpeg`. `nil` for a media-less kind.
    public var mimeType: String?
    /// Intrinsic width — layout without decoding. `nil` for a media-less kind.
    public var width: Int?
    /// Intrinsic height — layout without decoding. `nil` for a media-less kind.
    public var height: Int?
    /// Playback duration, for video.
    public var duration: Double?
    /// Bytes on disk. `nil` for a media-less kind.
    public var fileSize: Int?
    /// `pending` | `downloaded` | `failed` — lets a failed download resume.
    public var downloadState: DownloadState
    /// When captured.
    public var createdAt: Date
    /// A user-given display name for the item (041 · Details). `nil` until the
    /// user names it — the UI falls back to the source title / kind. Added by
    /// migration v10.
    public var name: String?
    /// A free-form user note on the item (041 · Details). `nil` until written.
    /// Added by migration v10.
    public var note: String?
    /// Whether the user starred this item (011 · U5). A property of the ASSET,
    /// not of a membership: an asset in three collections is favorited in all
    /// three. `false` for every row that predates the flag. Added by migration
    /// v19, `DEFAULT 0`.
    public var isFavorite: Bool
    /// FK → ``Source``. **Required** — where the asset came from.
    public var sourceId: UUID
    /// How many times this asset's detail page has been opened (007 · sort). A
    /// global per-asset counter (one asset, many memberships) — the "most
    /// viewed" ranking key. Added by migration v5, `DEFAULT 0`.
    public var viewCount: Int
    /// When the detail page was last opened (007 · sort). `nil` until first
    /// viewed; makes a future "recently viewed" sort free. Added by v5.
    public var lastViewedAt: Date?
    /// The media-less kind's structured substance as JSON TEXT (003 · O1); `nil`
    /// for byte-backed kinds. Decode via ``payloadValue`` — do not parse raw.
    public var payload: String?
    /// The kind-aware dedup key (003 · O1): canonical hex for `color`, normalized
    /// URL for `link`, tweet-id for `tweet`; `nil` for byte-backed kinds (which
    /// dedup on `blobHash` + source). Indexed.
    public var dedupKey: String?
    /// Denormalized content text for `asset_fts` (003 · O1): tweet text, a link's
    /// title+description, a color's name; `nil` when there is nothing to index.
    public var searchText: String?

    /// Explicit snake_case column/coding names (the persistence layer binds
    /// these as SQLite columns; chosen explicitly so acronym mapping is exact).
    public enum CodingKeys: String, CodingKey {
        case id, kind
        case blobHash = "blob_hash"
        case mimeType = "mime_type"
        case width, height, duration
        case fileSize = "file_size"
        case downloadState = "download_state"
        case createdAt = "created_at"
        case name, note
        case isFavorite = "is_favorite"
        case sourceId = "source_id"
        case viewCount = "view_count"
        case lastViewedAt = "last_viewed_at"
        case payload
        case dedupKey = "dedup_key"
        case searchText = "search_text"
    }

    public init(
        id: UUID,
        kind: AssetKind,
        blobHash: String?,
        mimeType: String?,
        width: Int?,
        height: Int?,
        duration: Double? = nil,
        fileSize: Int?,
        downloadState: DownloadState,
        createdAt: Date,
        name: String? = nil,
        note: String? = nil,
        isFavorite: Bool = false,
        sourceId: UUID,
        viewCount: Int = 0,
        lastViewedAt: Date? = nil,
        payload: String? = nil,
        dedupKey: String? = nil,
        searchText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
        self.fileSize = fileSize
        self.downloadState = downloadState
        self.createdAt = createdAt
        self.name = name
        self.note = note
        self.isFavorite = isFavorite
        self.sourceId = sourceId
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
        self.payload = payload
        self.dedupKey = dedupKey
        self.searchText = searchText
    }
}
