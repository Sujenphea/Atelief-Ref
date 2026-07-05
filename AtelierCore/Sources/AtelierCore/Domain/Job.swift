// AtelierCore — bulk-import job ledger (015 · decision 3A)
//
// A bulk import ("scrape all my bookmarks / boards") is the single-item ingest
// pipeline run many times, orchestrated durably. The `job` / `job_item` tables
// are the app-side half of the two-tier state (the extension owns the scroll/
// cursor state in chrome.storage): a durable record of what actually landed, so
// the sweep is resumable, progress is truthful, and the extension can query
// already-ingested source ids to skip RE-DOWNLOADING them (P14) — SHA-256
// content-addressing stays the authoritative dedup backstop.
//
// Plain value types, mirroring `Source`: no persistence, no validation here; the
// GRDB conformance lives in `Persistence/Job+GRDB.swift` (A1) and the mutation
// funnel in `AppServices` (A4).

import Foundation

/// The lifecycle of a bulk-import ``Job`` (decision 3A / 7A). `open` while the
/// sweep runs; `paused`/`halted` when the extension checkpointed and stopped
/// (user pause vs a fatal auth / rate-limit wall — 7A); `complete` when the
/// cursor reached its terminator. String rawValue = the on-disk encoding (C5).
public enum JobStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case open
    case paused
    case complete
    case halted
}

/// The outcome of one enumerated item in a sweep (decision 7A — the typed
/// per-item taxonomy). `ingested`/`deduped` = the bytes are now in the store (so
/// the source is "known" and skippable next time); `skipped` = it was already
/// known and never re-downloaded; `retryableFailed` (429/timeout/5xx) is requeued
/// by the engine; `permanentFailed` (404/unsupported/decode) is recorded and
/// moved past. One bad item never aborts the sweep. String rawValue = on-disk (C5).
public enum JobItemStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case ingested
    case deduped
    case skipped
    case retryableFailed = "retryable_failed"
    case permanentFailed = "permanent_failed"
}

/// One bulk-import sweep. `ingestedCount` is a denormalized progress counter kept
/// exactly in sync with the `job_item` rows inside the same transaction that
/// records an item (no drift — see ``AppServices/recordJobItem``); UI reads it for
/// progress. `totalEstimate` is the extension's best guess (often known up front,
/// e.g. a board's pin count) and may be nil / revised.
public struct Job: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Server-generated stable identity (the extension tags each item POST with it).
    public var id: UUID
    /// Which platform this sweep pulls from.
    public var platform: Platform
    /// What within the platform is being swept, e.g. `"bookmarks"`, `"board:<id>"`.
    /// Free-form (nullable) — the ledger doesn't interpret it.
    public var scope: String?
    /// Where the sweep is in its lifecycle (3A / 7A).
    public var status: JobStatus
    /// The extension's up-front estimate of the total item count, or nil.
    public var totalEstimate: Int?
    /// Items whose bytes have landed (`ingested` + `deduped`), recomputed in-txn.
    public var ingestedCount: Int
    /// When the sweep was opened.
    public var createdAt: Date
    /// Last progress/status change.
    public var updatedAt: Date

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case id, platform, scope, status
        case totalEstimate = "total_estimate"
        case ingestedCount = "ingested_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        platform: Platform,
        scope: String? = nil,
        status: JobStatus = .open,
        totalEstimate: Int? = nil,
        ingestedCount: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.platform = platform
        self.scope = scope
        self.status = status
        self.totalEstimate = totalEstimate
        self.ingestedCount = ingestedCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One enumerated item's ledger row, keyed by `(job_id, source_id)` — no id of
/// its own (like `asset_tag`). `sourceID` is the PLATFORM's stable id (tweet id /
/// pin id), NOT the DB `source.id`; it's the key the download-skip (P14) and
/// dedup are expressed in. `blobHash` is set once the bytes are ingested, linking
/// the ledger row to the content-addressed store.
public struct JobItem: Sendable, Equatable, Hashable, Codable {
    /// The owning ``Job`` (FK → `job.id`, CASCADE).
    public var jobID: UUID
    /// The platform's stable item id (tweet id / pin id).
    public var sourceID: String
    /// The item's canonical URL (provenance / debugging), or nil.
    public var sourceURL: String?
    /// This item's outcome (decision 7A).
    public var status: JobItemStatus
    /// The ingested blob's SHA-256, once landed (nil for skipped/failed).
    public var blobHash: String?
    /// Last change to this item.
    public var updatedAt: Date

    /// Explicit snake_case column/coding names.
    public enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case sourceID = "source_id"
        case sourceURL = "source_url"
        case status
        case blobHash = "blob_hash"
        case updatedAt = "updated_at"
    }

    public init(
        jobID: UUID,
        sourceID: String,
        sourceURL: String? = nil,
        status: JobItemStatus,
        blobHash: String? = nil,
        updatedAt: Date
    ) {
        self.jobID = jobID
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.status = status
        self.blobHash = blobHash
        self.updatedAt = updatedAt
    }
}
