// AtelierCore — Asset
//
// Mirrors 003 §data-model · Asset exactly. A plain value type: no persistence,
// no validation (GRDB conformance and the App Services funnel land later).

import Foundation

/// A single piece of captured media and its provenance (003 §data-model).
///
/// Provenance is required: every asset references a ``Source`` — even a pasted
/// image (`local_paste`) or dragged file (`local_drag`). There is no
/// asset-with-no-origin (decision C6); the `sourceId` parameter is not optional.
public struct Asset: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// `image` | `video` (extensible).
    public var kind: AssetKind
    /// Content hash → file in `blobs/`. Enables dedup (non-unique: one blob,
    /// many asset rows).
    public var blobHash: String
    /// e.g. `image/jpeg`.
    public var mimeType: String
    /// Intrinsic width — layout without decoding.
    public var width: Int
    /// Intrinsic height — layout without decoding.
    public var height: Int
    /// Playback duration, for video.
    public var duration: Double?
    /// Bytes on disk.
    public var fileSize: Int
    /// `pending` | `downloaded` | `failed` — lets a failed download resume.
    public var downloadState: DownloadState
    /// When captured.
    public var createdAt: Date
    /// FK → ``Source``. **Required** — where the asset came from.
    public var sourceId: UUID

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
        case sourceId = "source_id"
    }

    public init(
        id: UUID,
        kind: AssetKind,
        blobHash: String,
        mimeType: String,
        width: Int,
        height: Int,
        duration: Double? = nil,
        fileSize: Int,
        downloadState: DownloadState,
        createdAt: Date,
        sourceId: UUID
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
        self.sourceId = sourceId
    }
}
