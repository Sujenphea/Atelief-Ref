// AtelierIngestion — the pipeline's input + outcome value types (chunk 4)
//
// One image to ingest, expressed as bytes-plus-provenance, and the per-item
// result. The caller (chunk 5's paste/drag/browser adapters) already knows the
// bytes and has populated a `SourceDraft`; the pipeline only turns that into a
// stored blob + thumbnails + persisted asset. All `Sendable` so a batch can
// cross into the coordinator's off-main tasks (A3).

import Foundation
import AtelierCore

/// Where an item's raw bytes come from: already in memory (a paste) or a file on
/// disk (a drag). The pipeline reads both into a single `Data` (images are
/// modest); a file that can't be read maps to `.unreadableSource`.
public enum ByteSource: Sendable {
    /// Bytes already resident in memory — e.g. a pasteboard image.
    case data(Data)
    /// A file URL whose bytes are read at ingest time — e.g. a dragged file.
    case fileURL(URL)
}

/// One image to ingest: its bytes, its REQUIRED provenance, the target
/// collection, and an optional canvas placement.
///
/// The provenance (`SourceDraft`) is caller-supplied and non-optional, mirroring
/// AtelierCore's C6 "no asset with no origin" rule. Index-aligned with its
/// ``IngestOutcome`` in a batch.
public struct IngestInput: Sendable {
    /// The item's raw bytes (in-memory or a file URL).
    public let source: ByteSource
    /// Where the item came from — carried straight through to `AppServices`.
    public let provenance: SourceDraft
    /// The collection the ingested asset is added to.
    public let collectionID: UUID
    /// An optional canvas placement supplied at ingest time.
    public let placement: CanvasPlacement?

    public init(
        source: ByteSource,
        provenance: SourceDraft,
        collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) {
        self.source = source
        self.provenance = provenance
        self.collectionID = collectionID
        self.placement = placement
    }
}

/// The per-item result of an ingestion — exactly one per ``IngestInput``,
/// index-aligned in a batch (C8).
///
/// `.ingested` carries the resolved ``Asset`` and whether the 18A dedup rule
/// reused an existing one; `.failed` carries the typed ``IngestError`` naming
/// the pipeline stage that failed. One bad item never aborts the batch.
public enum IngestOutcome: Sendable {
    /// The item was ingested (or deduped): its blob + thumbnails are on disk and
    /// the asset is persisted. `deduplicated` is `true` when an existing
    /// asset+source was reused (18A).
    case ingested(asset: Asset, deduplicated: Bool)
    /// The item failed at the named pipeline stage; nothing partial persists.
    case failed(IngestError)
}
