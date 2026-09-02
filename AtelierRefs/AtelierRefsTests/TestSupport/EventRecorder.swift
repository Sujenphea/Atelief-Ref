//
//  EventRecorder.swift
//  AtelierRefsTests
//
//  099 · 11A — reading an ``EventSignal`` from a test.
//
//  A test wants two things a bare `AsyncStream` makes awkward together: to wait
//  for an event, and to wait for one that may ALREADY have arrived while it was
//  asserting something else. Iterating the stream directly gives the first and
//  loses the second — take a fresh stream for the second wait and whatever
//  happened in between is not in it.
//
//  So: subscribe ONCE, record everything from that moment, and phrase every wait
//  as a predicate over the record. "The promotion has happened" is then true
//  whether it happened a microsecond ago or is about to, and a test that waits for
//  it cannot lose a race it was written to win.
//
//  (An iterator-holding struct was the first shape and does not survive Swift 6:
//  a `mutating func` cannot call `AsyncStream.AsyncIterator.next()` across a
//  suspension without sending a non-`Sendable` iterator. One task owns the
//  iteration here, which is the shape the language is asking for anyway.)
//
//  Every wait is unbounded, on purpose, and the bound lives one level up in the
//  suite's `.timeLimit` — the same division `ThumbnailPipelineTests` already makes
//  between its probe's own bounded wait and the trait that catches everything
//  else. A per-call timeout would report "the event never came" with no stack;
//  the suite bound reports the test that is stuck.
//

import Foundation

/// Records every event from one ``EventSignal`` subscription and lets a test
/// await conditions over the record.
///
/// Construct it BEFORE the work starts — the subscription begins here, and an
/// event emitted earlier is genuinely not in it.
nonisolated final class EventRecorder<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Event] = []
    private var waiters: [(id: UUID, isSatisfied: @Sendable ([Event]) -> Bool,
                           continuation: CheckedContinuation<Void, Never>)] = []
    private var consumer: Task<Void, Never>?

    init(_ stream: AsyncStream<Event>) {
        consumer = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    deinit { consumer?.cancel() }

    /// Everything recorded so far.
    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// How many recorded events satisfy `predicate` — the counting half, for the
    /// coalescing tests ("N requests attached to one task").
    func count(where predicate: (Event) -> Bool) -> Int {
        events.filter(predicate).count
    }

    /// Suspend until the recorded events satisfy `condition`. Returns immediately
    /// if they already do, which is the whole reason this records rather than
    /// iterates.
    func wait(until condition: @escaping @Sendable ([Event]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if condition(seen) {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((id: UUID(), isSatisfied: condition, continuation: continuation))
            lock.unlock()
        }
    }

    /// Suspend until at least `count` recorded events satisfy `predicate`.
    func wait(forAtLeast count: Int, where predicate: @escaping @Sendable (Event) -> Bool) async {
        await wait { events in events.filter(predicate).count >= count }
    }

    private func append(_ event: Event) {
        lock.lock()
        seen.append(event)
        // Resolve waiters OUTSIDE the lock: `resume` runs the woken task's
        // continuation machinery, and holding a lock across code that is not ours
        // is how a test helper acquires a deadlock nobody can reproduce.
        let ready = waiters.filter { $0.isSatisfied(seen) }
        let readyIDs = Set(ready.map(\.id))
        waiters.removeAll { readyIDs.contains($0.id) }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }
}
