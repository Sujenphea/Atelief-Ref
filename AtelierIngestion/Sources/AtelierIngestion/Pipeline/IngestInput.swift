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

/// What an ``IngestInput`` carries (003 · O1 · C3): either the bytes of a
/// byte-backed asset (`image` / `video`) or the ``AssetContentDraft`` of a
/// MEDIA-LESS one (`tweet` / `link` / `color`). Both flow through the SAME
/// ``IngestCoordinator`` batch — so a bulk capture of media-less items gets the
/// same bounded concurrency, ledger recording, and live-refresh as an image
/// sweep (P2: no second queue). The pipeline branches on this once.
public enum IngestSource: Sendable {
    /// A byte-backed item: hash / thumbnail / blob-first persistence.
    case bytes(ByteSource)
    /// A media-less item: skip all byte stages, straight to `ingestContent`.
    case content(AssetContentDraft)
    /// A media-less item that ALSO carries a card image (003 · C3, Option 3): a
    /// tweet whose picture is stored as a real blob. The pipeline runs the
    /// blob-first byte stages (hash / thumbnail / store) for the image AND passes
    /// the draft to `ingestContent(_:blob:)`, so the asset keeps its `tweet`
    /// content identity while rendering its picture. Because dedup is by tweet-id
    /// (not bytes), a card image discarded on dedup is reclaimed (never orphaned).
    case contentWithBytes(draft: AssetContentDraft, image: ByteSource)
}

/// One image to ingest: its bytes, its REQUIRED provenance, the target
/// collection, and an optional canvas placement.
///
/// The provenance (`SourceDraft`) is caller-supplied and non-optional, mirroring
/// AtelierCore's C6 "no asset with no origin" rule. Index-aligned with its
/// ``IngestOutcome`` in a batch.
public struct IngestInput: Sendable {
    /// What the item carries — bytes (byte-backed) or a content draft (media-less).
    public let source: IngestSource
    /// Where the item came from — carried straight through to `AppServices`.
    public let provenance: SourceDraft
    /// The collection the ingested asset is added to.
    public let collectionID: UUID
    /// An optional canvas placement supplied at ingest time.
    public let placement: CanvasPlacement?

    /// The general initializer — bytes or content.
    public init(
        source: IngestSource,
        provenance: SourceDraft,
        collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) {
        self.source = source
        self.provenance = provenance
        self.collectionID = collectionID
        self.placement = placement
    }

    /// A byte-backed item — the original shape, kept so every existing byte
    /// factory / call site (`.data` / `.fileURL`) stays source-compatible.
    public init(
        source: ByteSource,
        provenance: SourceDraft,
        collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) {
        self.init(
            source: .bytes(source), provenance: provenance,
            collectionID: collectionID, placement: placement)
    }

    /// A MEDIA-LESS item (003 · C3) — a `tweet` / `link` / `color` content draft
    /// routed through the same coordinator as bytes.
    public init(
        content: AssetContentDraft,
        provenance: SourceDraft,
        collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) {
        self.init(
            source: .content(content), provenance: provenance,
            collectionID: collectionID, placement: placement)
    }

    /// A MEDIA-LESS item WITH a card image (003 · C3, Option 3) — a `tweet`
    /// content draft plus the bytes of its picture, stored as a real blob.
    public init(
        content: AssetContentDraft,
        image: ByteSource,
        provenance: SourceDraft,
        collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) {
        self.init(
            source: .contentWithBytes(draft: content, image: image),
            provenance: provenance, collectionID: collectionID, placement: placement)
    }
}

/// The per-item result of an ingestion — exactly one per ``IngestInput``,
/// index-aligned in a batch (C8).
///
/// `.ingested` carries the resolved ``Asset`` and whether the 18A dedup rule
/// reused an existing one; `.failed` carries the typed ``IngestError`` naming
/// the pipeline stage that failed. `.cancelled` fills slots that never ran
/// because the surrounding batch task was cancelled — so
/// `zip(inputs, outcomes)` stays aligned. One bad item never aborts the batch.
public enum IngestOutcome: Sendable {
    /// The item was ingested (or deduped): its blob + thumbnails are on disk and
    /// the asset is persisted. `deduplicated` is `true` when an existing
    /// asset+source was reused (18A).
    case ingested(asset: Asset, deduplicated: Bool)
    /// The item failed at the named pipeline stage; nothing partial persists.
    case failed(IngestError)
    /// The item was never started because the batch was cancelled partway.
    case cancelled
}
