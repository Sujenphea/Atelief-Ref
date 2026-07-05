// AtelierIngestion — per-ingest phase timing (015 · Phase 8, [16A]).
//
// A lightweight measurement to REVEAL a thumbnail stall — the trigger for the P16
// lazy-tier lever (which is added only IF measured, not pre-emptively). The pipeline
// stamps each successful ingest with its phase durations and hands it to an optional
// sink (the app logs slow ones — see IngestionModel). Nil sink ⇒ the timing is still
// gathered from a monotonic clock (a handful of cheap reads) but never emitted.

import Foundation

/// One successful ingest's phase breakdown. `thumbnails` is the phase of interest:
/// generating the 128/512/1280 tiers is the decode-heavy step that stalls a bulk
/// sweep, so `tiersGenerated == 0` (the P14 short-circuit) should be ~free and a
/// large `thumbnailMillis` is the signal to make the big tier lazy (P16).
public struct IngestTiming: Sendable, Equatable {
    /// The content hash of the ingested bytes (correlates the log to the asset).
    public let hash: String
    /// Whether the blob already existed (dedup) — its bytes weren't re-written.
    public let blobExisted: Bool
    /// How many thumbnail tiers were actually generated this ingest (0 = fully
    /// short-circuited by P14).
    public let tiersGenerated: Int
    /// Pre-thumbnail prepare work: obtain bytes + content-hash + byte-metadata
    /// decode (dims/mime/kind). The cheap part; isolated so `thumbnails` is clean.
    public let metadata: Duration
    /// Thumbnail generation + store for the missing tiers (the P16 stall candidate).
    public let thumbnails: Duration
    /// The single persistence transaction (P15).
    public let persist: Duration
    /// End-to-end (bytes → persisted).
    public let total: Duration

    public init(
        hash: String, blobExisted: Bool, tiersGenerated: Int,
        metadata: Duration, thumbnails: Duration, persist: Duration, total: Duration
    ) {
        self.hash = hash
        self.blobExisted = blobExisted
        self.tiersGenerated = tiersGenerated
        self.metadata = metadata
        self.thumbnails = thumbnails
        self.persist = persist
        self.total = total
    }

    /// Milliseconds of the thumbnail phase (the stall metric).
    public var thumbnailMillis: Double { Self.millis(thumbnails) }
    /// Milliseconds end-to-end.
    public var totalMillis: Double { Self.millis(total) }

    /// A `Duration` in milliseconds (seconds + attoseconds → ms).
    static func millis(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
}
