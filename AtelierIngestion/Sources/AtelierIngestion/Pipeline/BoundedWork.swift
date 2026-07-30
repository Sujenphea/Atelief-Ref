// AtelierIngestion — bounded-concurrency batch work + serialized progress.
//
// Extracted from `IngestCoordinator` (008 · F3) once a second consumer appeared:
// off-device backup copies N blob files with the same shape ingest uses — at
// most K in flight, monotonic progress, cancellable, results index-aligned with
// inputs. The logic never depended on WHAT was being processed (it only indexes
// the array), so the element type is now generic and both callers share one
// implementation rather than keeping two concurrency loops correct in parallel.
//
// Deliberately NOT an actor or a manager type: this is a function plus a small
// reporter. Anything that needs a lifecycle (pausing, resuming, a persistent
// queue) belongs to its own coordinator — see `IngestCoordinator` for the
// batch-ingest one.

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
/// completion. Indices that never started are `nil` so callers can fill a typed
/// placeholder (e.g. ``IngestOutcome.cancelled``) and keep `zip(inputs, results)`
/// aligned. For ingest, MediaStore atomicity (A2) means those finished items are
/// complete blobs and nothing partial is left behind; a backup copier gets the
/// same property by staging + renaming each file.
///
/// Generic over a `Sendable` element AND result, so a test can pass a probe
/// operation that records the max concurrency it observes.
///
/// - Note: `Task.isCancelled` here reads the *surrounding* task's state. Work
///   started from `Task.detached` does not inherit cancellation — such callers
///   must thread their own flag through `operation`.
public func runBounded<Element: Sendable, T: Sendable>(
    _ items: [Element],
    maxConcurrent: Int,
    _ operation: @Sendable @escaping (Int, Element) async -> T
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

/// A serialized progress reporter so batch progress is delivered monotonically
/// even as concurrent tasks finish in arbitrary order. Each `report()` bumps the
/// completed count and — under the actor's isolation — invokes the callback, so
/// callers observe `completed` as a strictly increasing 1…total sequence.
///
/// Shared by batch ingest and off-device backup: "N of M done, in order" is the
/// same problem in both, and getting monotonicity right once is the point.
public actor ProgressReporter {
    private var count = 0
    private let total: Int
    private let onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?

    public init(
        total: Int,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) {
        self.total = total
        self.onProgress = onProgress
    }

    /// Record one completed unit and deliver the new count.
    public func report() {
        count += 1
        onProgress?(count, total)
    }
}
