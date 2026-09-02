//
//  Coalescer.swift
//  AtelierRefs
//
//  099 · 13A — one answer to "a burst of signals should become one action",
//  generalised from `ViewBumpCoalescer` (007 G4 / 036 B4).
//
//  The original coalesced "this asset was viewed" into one `recordViews` write
//  per asset. `refreshAfterIngest` wanted the same idea with a different unit —
//  a burst of capture batches into one reload per collection — and was written
//  without it, so it reloaded the visible folder on EVERY batch. A sweep landing
//  forty images fired forty full `collectionItems` reads of the same collection,
//  and each of those is the 071 number (the scale harness: 65 ms at 2,000 rows,
//  640 ms at 20,000). One type, two faces:
//
//    • the TALLY — `record` / `drain`, unchanged, for "how many times did each
//      key fire in this window"; and
//    • the THROTTLE — `admit` / `release`, for "at most one run per key per
//      interval, and never lose the last one".
//
//  Both are PURE (no timers, no I/O, no clock reads of their own): the caller
//  owns the debounce task and passes the instant in. That is what makes the
//  throttle testable without a sleep — a test advances the instant by hand.
//

import Foundation

/// Folds a burst of per-key signals into one action per key.
///
/// Generic over the key because its two callers key by different things: view
/// bumps by `UUID` (an asset), reloads by `UUID?` (a collection, or `nil` for
/// "the producer cannot say which"). `Optional` is `Hashable`, so `nil` is a
/// perfectly good key and the unknown-target case throttles alongside the rest
/// rather than escaping the limit.
struct Coalescer<Key: Hashable> {

    // MARK: - The tally (007 G4)

    /// Per-key signal counts within the current window.
    private var pending: [Key: Int] = [:]

    /// Whether there is anything to flush.
    var isEmpty: Bool { pending.isEmpty }

    /// Note that `key` fired. Recording the same key twice before a drain
    /// increments its count (was a set-collapse before 036 B4).
    mutating func record(_ key: Key) {
        pending[key, default: 0] += 1
    }

    /// Take the accumulated per-key counts and clear the buffer. Returns `[:]`
    /// when empty.
    mutating func drain() -> [Key: Int] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    // MARK: - The throttle (099 · 13A)

    /// What the caller should do with a signal that has just arrived.
    enum Admission: Equatable {
        /// Run it now. The key's window restarts from the instant passed in.
        case run
        /// Suppressed, and THIS signal is the one that owes a trailing run: the
        /// caller schedules the work after `after` and calls ``release(_:at:)``
        /// when it fires. Exactly one signal per window gets this.
        case hold(after: Duration)
        /// Suppressed, and a trailing run is already owed — do nothing. The work
        /// an earlier `.hold` scheduled will cover this signal too, which is
        /// precisely the coalescing.
        case held
    }

    /// Per-key window state: when the key last ran, and whether a trailing run
    /// has already been scheduled for the current window.
    private struct Window {
        var lastRun: ContinuousClock.Instant
        var trailingScheduled = false
    }

    private var windows: [Key: Window] = [:]

    /// Decide what to do with a signal for `key` arriving at `now`, given a
    /// minimum spacing of `interval` between runs of that key.
    ///
    /// **Leading edge, plus a trailing run.** The first signal of a window runs
    /// immediately — a capture the user just watched arrive must not wait half a
    /// second to appear — and everything inside the window collapses into ONE
    /// deferred run at its end, so the last item of a burst is never the one that
    /// goes missing. That is the difference between throttling and dropping, and
    /// it is the whole reason `.hold` is distinct from `.held`.
    ///
    /// The instant is a parameter rather than `ContinuousClock.now` so this stays
    /// pure and a test can drive a burst across a window boundary without sleeping
    /// through one (099 · 11A).
    mutating func admit(
        _ key: Key, interval: Duration, at now: ContinuousClock.Instant
    ) -> Admission {
        guard let window = windows[key] else {
            windows[key] = Window(lastRun: now)
            return .run
        }
        let elapsed = now - window.lastRun
        if elapsed >= interval {
            windows[key] = Window(lastRun: now)
            return .run
        }
        if window.trailingScheduled { return .held }
        windows[key]?.trailingScheduled = true
        return .hold(after: interval - elapsed)
    }

    /// Record that `key`'s owed trailing run has just happened at `now`: its
    /// window restarts and nothing is owed any more.
    ///
    /// Called by the caller's deferred task, not by ``admit(_:interval:at:)`` —
    /// the coalescer has no clock and no scheduler, so it cannot know when the
    /// work it deferred actually ran.
    mutating func release(_ key: Key, at now: ContinuousClock.Instant) {
        windows[key] = Window(lastRun: now)
    }

    /// Whether `key` currently owes a trailing run — the property a test asserts
    /// to show a burst collapsed rather than each signal running.
    func isHolding(_ key: Key) -> Bool {
        windows[key]?.trailingScheduled ?? false
    }
}

/// The 007 G4 view-bump coalescer: ``Coalescer`` keyed by asset id.
///
/// Core's `recordViews` coalesces a batch to ONE `view_count` increment per
/// DISTINCT asset (`AppServices.swift`), so the model folds each drain to +1 per
/// key when reproducing that delta locally — the raw per-open count is exposed
/// but the persisted unit remains one bump per asset.
typealias ViewBumpCoalescer = Coalescer<UUID>
