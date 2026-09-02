//
//  EventSignal.swift
//  AtelierRefs
//
//  099 · 11A — a test-visible lifecycle signal, so a test can AWAIT the thing it
//  is waiting for instead of guessing how long it takes.
//
//  The tests this exists for were written as `try? await Task.sleep(...)`, and the
//  comments beside them said what they were really waiting for: "let the promotion
//  land", "let any stragglers land", "let the recording tasks drain". A sleep is
//  two bets at once — long enough that it always passes on the author's machine,
//  short enough that nobody notices the suite is slow — and both bets are lost
//  under load, which is exactly when CI runs. P0b's report already names
//  `ThumbnailPipelineTests` flaking that way on a loaded machine.
//
//  What is emitted is deliberately the LIFECYCLE, not the answer: `started`,
//  `joined`, `promoted`, `finished`. A test that awaits the answer proves nothing
//  about coalescing; a test that awaits "twenty-four requests have attached to one
//  task" proves precisely the thing it is named after, and it takes exactly as
//  long as that takes.
//
//  **The cost in production is a lock and an empty dictionary.** Nothing in the
//  app subscribes, so `emit` takes the lock, finds no continuations and returns.
//  It is not `#if DEBUG`: a signal that exists only in the configuration the tests
//  run in cannot be reasoned about from a release build, and the guard would be
//  more code than the thing it guards.
//

import Foundation

/// A many-listener broadcast of `Event`s. Each ``stream()`` gets its own
/// unbounded `AsyncStream`, so two tests (or a test and a diagnostic) can watch
/// the same object without stealing each other's events.
///
/// **Unbounded buffering is the point.** A test subscribes, then acts, then
/// awaits — and the acting usually finishes before the awaiting starts. A
/// buffering policy that dropped the oldest event would turn that ordinary shape
/// into a hang.
nonisolated final class EventSignal<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    init() {}

    /// A new stream of every event emitted from now on. Ends when the caller
    /// stops iterating (the continuation's termination handler unsubscribes), so
    /// a test that `break`s out of its `for await` leaves nothing behind.
    func stream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Publish `event` to every live stream.
    ///
    /// The continuations are copied out and the lock released BEFORE yielding:
    /// `yield` runs a consumer's buffering, and holding a lock across anything
    /// that is not ours is how a deadlock gets written by accident.
    func emit(_ event: Event) {
        lock.lock()
        let live = Array(continuations.values)
        lock.unlock()
        for continuation in live { continuation.yield(event) }
    }

    /// Whether anything is listening — the property that makes "this costs
    /// nothing in the app" checkable rather than asserted.
    var hasListeners: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !continuations.isEmpty
    }
}
