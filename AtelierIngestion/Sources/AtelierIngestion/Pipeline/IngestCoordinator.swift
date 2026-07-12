// AtelierIngestion — the batch ingestion coordinator (chunk 4, decision A3)
//
// The lightweight, in-memory, bounded-concurrency runner for a BATCH of images:
// it drives `IngestPipeline.ingest` over many items off-main, with AT MOST N in
// flight, reporting progress and honoring cancellation. There is NO persistent /
// resumable queue (A3) — that is reserved for the deferred bulk-network path.
//
// Partial-failure tolerance (C8) and cancellation safety (A2) fall out of the
// pieces below: each item's outcome is independent (`pipeline.ingest` never
// throws), and because every MediaStore write is atomic (chunk 2), cancelling
// mid-batch leaves COMPLETE blobs for the finished items and NOTHING partial for
// the rest.

import Foundation

/// Run `operation` over `items` with AT MOST `maxConcurrent` tasks in flight,
/// returning one optional result per input IN INPUT ORDER (decision A3).
///
/// The concurrency cap is structural, not advisory: the task group is PRIMED
/// with exactly `maxConcurrent` child tasks, then runs strictly one-in-one-out —
/// each time a task finishes (`group.next()`), at most one replacement is
/// launched. So the group never holds more than `maxConcurrent` unfinished
/// children, which is what a concurrency probe observes as the ceiling.
///
/// Cancellation-aware: when the surrounding task is cancelled, no NEW work is
/// launched (the `Task.isCancelled` guard), while already-launched items run to
/// completion — MediaStore atomicity means those finish as complete blobs.
/// Indices that never started are `nil` so callers can fill a typed placeholder
/// (e.g. ``IngestOutcome.cancelled``) and keep `zip(inputs, outcomes)` aligned.
///
/// Generic over a `Sendable` result `T` so a test can pass a probe operation
/// that records the max concurrency it observes.
func runBounded<T: Sendable>(
    _ items: [IngestInput],
    maxConcurrent: Int,
    _ operation: @Sendable @escaping (Int, IngestInput) async -> T
) async -> [T?] {
    let total = items.count
    guard total > 0 else { return [] }
    // At least one in flight, regardless of a bogus limit.
    let limit = max(1, maxConcurrent)

    // Keyed by input index so results survive out-of-order completion; mapped
    // back into a full-length, input-ordered array at the end.
    var results = [Int: T]()
    results.reserveCapacity(total)

    await withTaskGroup(of: (Int, T).self) { group in
        var nextIndex = 0

        // Prime the group with up to `limit` tasks — the ceiling on in-flight
        // work. (Nothing is primed if the batch starts already cancelled.)
        while nextIndex < total, nextIndex < limit, !Task.isCancelled {
            let index = nextIndex
            let item = items[index]
            group.addTask { (index, await operation(index, item)) }
            nextIndex += 1
        }

        // One-in-one-out: for each completion, record it and launch at most one
        // replacement — so the in-flight count never exceeds `limit`. Stop
        // launching (but keep draining) once cancelled.
        while let (index, value) = await group.next() {
            results[index] = value
            if nextIndex < total, !Task.isCancelled {
                let i = nextIndex
                let item = items[i]
                group.addTask { (i, await operation(i, item)) }
                nextIndex += 1
            }
        }
    }

    // Full length, input order — nil slots are indices that never ran.
    return (0 ..< total).map { results[$0] }
}

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
    private let maxConcurrent: Int

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

/// A serialized progress reporter so batch progress is delivered monotonically
/// even as concurrent tasks finish in arbitrary order. Each `report()` bumps the
/// completed count and — under the actor's isolation — invokes the callback, so
/// callers observe `completed` as a strictly increasing 1…total sequence.
private actor ProgressReporter {
    private var count = 0
    private let total: Int
    private let onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?

    init(total: Int, onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) {
        self.total = total
        self.onProgress = onProgress
    }

    func report() {
        count += 1
        onProgress?(count, total)
    }
}
