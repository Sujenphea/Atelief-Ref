// AtelierIngestion — the batch ingestion coordinator (chunk 4, decision A3)
//
// The lightweight, in-memory, bounded-concurrency runner for a BATCH of images:
// it drives `IngestPipeline.ingest` over many items off-main, with AT MOST N in
// flight, reporting progress and honoring cancellation. There is NO persistent /
// resumable queue (A3) — that is reserved for the deferred bulk-network path.
//
// The concurrency + progress machinery itself lives in `BoundedWork.swift`
// (`runBounded` / `ProgressReporter`), shared with off-device backup (008 · F3);
// what remains here is the ingest-specific wiring: pipeline, outcomes, and the
// cancelled-slot fill.
//
// Partial-failure tolerance (C8) and cancellation safety (A2) fall out of the
// pieces below: each item's outcome is independent (`pipeline.ingest` never
// throws), and because every MediaStore write is atomic (chunk 2), cancelling
// mid-batch leaves COMPLETE blobs for the finished items and NOTHING partial for
// the rest.

import Foundation

/// The bounded-concurrency batch coordinator (decision A3).
///
/// An `actor` so its `IngestPipeline` and concurrency limit are isolated state;
/// it drives the pipeline over a batch off-main via ``runBounded(_:maxConcurrent:_:)``,
/// reporting monotonic progress and honoring cancellation. Holds no persistent
/// queue — a batch is a single in-memory call.
public actor IngestCoordinator {
    /// The single-image pipeline each item is run through.
    private let pipeline: IngestPipeline

    /// The maximum number of items ingested concurrently (default 4).
    ///
    /// Readable, because a producer that has more work than one batch needs to know
    /// how wide to make its batches — `InboxDrain` chunks the inbox at exactly this
    /// number. A `let` of a `Sendable` type, so reading it across the actor boundary
    /// is synchronous and free; it is state a caller may size a batch by, never state
    /// a caller may set.
    ///
    /// Exposed rather than duplicated: a second constant meaning "how much of the
    /// machine we spend on decoding" is two numbers that must agree, and they will
    /// not the first time one of them is tuned.
    ///
    /// `nonisolated` and not merely `public`: reading a batch width should not cost
    /// an `await` on the actor that is busy running the previous batch.
    public nonisolated let maxConcurrent: Int

    public init(pipeline: IngestPipeline, maxConcurrent: Int = 4) {
        self.pipeline = pipeline
        // A non-positive limit is meaningless; clamp to serial.
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Ingest a batch, returning one ``IngestOutcome`` per input IN INPUT ORDER.
    ///
    /// Runs `pipeline.ingest` over the inputs with at most ``maxConcurrent`` in
    /// flight (via ``runBounded(_:maxConcurrent:_:)``). `onProgress` is invoked
    /// as each item finishes with a MONOTONICALLY increasing `completed` count of
    /// `total`, ending at `total` for a batch that runs to completion.
    ///
    /// Never throws and never aborts the batch on a single failure (C8): a bad
    /// item is its own `.failed` outcome. Cancelling the surrounding task partway
    /// stops launching new items; unstarted slots are ``IngestOutcome.cancelled``
    /// so the returned array stays index-aligned with `inputs`. MediaStore
    /// atomicity (A2) guarantees no partial blobs are left behind.
    public func ingest(
        _ inputs: [IngestInput],
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [IngestOutcome] {
        let total = inputs.count
        // A serialized reporter shared across the concurrent tasks: it both
        // increments the completed count AND invokes `onProgress` under its own
        // isolation, so deliveries are strictly ordered (1, 2, …, total) — never
        // reordered by out-of-order task completion.
        let reporter = ProgressReporter(total: total, onProgress: onProgress)
        let pipeline = self.pipeline

        let slots = await runBounded(inputs, maxConcurrent: maxConcurrent) { _, input in
            let outcome = await pipeline.ingest(input)
            await reporter.report()
            return outcome
        }
        return slots.map { $0 ?? .cancelled }
    }
}

