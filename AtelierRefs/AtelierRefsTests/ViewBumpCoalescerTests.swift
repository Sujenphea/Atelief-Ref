//
//  ViewBumpCoalescerTests.swift
//  AtelierRefsTests
//
//  007 G4 / 036 §3 B4 — the pure view-bump coalescer. `drain()` returns PER-ID
//  counts (`[UUID: Int]`) as of B4: repeated opens of one asset now accumulate a
//  count (were collapsed to a set), distinct assets each get their own count, and
//  drain empties the buffer.
//
//  099 · 13A generalised it into `Coalescer<Key>` and gave it a second face — the
//  per-key throttle behind `refreshAfterIngest`. Both suites live here because
//  they are one type. The throttle's decision is PURE and takes its instant as a
//  parameter, so the suite below drives a burst across a window boundary without
//  sleeping through one — the end-to-end assertion is
//  `CollectionReadModelTests.ingestBurstCollapses`.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@Suite("ViewBumpCoalescer (007 G4 / 036 B4)")
struct ViewBumpCoalescerTests {

    @Test("recording the same asset N times drains to that count")
    func countsRepeats() {
        var c = ViewBumpCoalescer()
        let a = UUID()
        c.record(a); c.record(a); c.record(a)
        #expect(c.drain() == [a: 3])
    }

    @Test("distinct assets each drain with their own count")
    func distinctAssets() {
        var c = ViewBumpCoalescer()
        let a = UUID(), b = UUID()
        c.record(a); c.record(b); c.record(a)
        #expect(c.drain() == [a: 2, b: 1])
    }

    @Test("drain empties the buffer; a fresh window starts clean")
    func drainEmpties() {
        var c = ViewBumpCoalescer()
        let a = UUID()
        c.record(a)
        #expect(!c.isEmpty)
        _ = c.drain()
        #expect(c.isEmpty)
        #expect(c.drain().isEmpty)         // second drain yields nothing

        // A new open after a drain is a new, countable view.
        c.record(a)
        #expect(c.drain() == [a: 1])
    }

    @Test("an untouched coalescer is empty and drains to nothing")
    func emptyByDefault() {
        var c = ViewBumpCoalescer()
        #expect(c.isEmpty)
        #expect(c.drain().isEmpty)
    }
}

@Suite("Coalescer throttle (099 · 13A)")
struct CoalescerThrottleTests {

    private let interval: Duration = .milliseconds(500)

    @Test("the first signal for a key runs immediately")
    func leadingEdgeRuns() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        #expect(c.admit(a, interval: interval, at: .now) == .run)
    }

    @Test("a burst inside one window yields ONE hold and then only holds")
    func burstCollapsesToOneTrailingRun() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)

        // The second signal is the one that OWES the trailing run, and the delay it
        // is handed is what remains of the window rather than a fresh one.
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(100))
                == .hold(after: .milliseconds(400)))
        // Everything behind it is covered by that scheduled run: eight more signals,
        // no more work.
        for offset in 150...157 {
            #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(offset)) == .held)
        }
        #expect(c.isHolding(a))
    }

    @Test("the window is per key — a second collection is not throttled by the first")
    func windowsAreIndependent() {
        var c = Coalescer<UUID?>()
        let a = UUID(), b = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)
        #expect(c.admit(b, interval: interval, at: t0) == .run)
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(10))
                == .hold(after: .milliseconds(490)))
        // `b`'s first hold is still available: `a`'s window said nothing about it.
        #expect(c.admit(b, interval: interval, at: t0 + .milliseconds(10))
                == .hold(after: .milliseconds(490)))
    }

    @Test("`nil` — the producer that cannot say — is a key like any other")
    func nilKeyThrottles() {
        var c = Coalescer<UUID?>()
        let t0 = ContinuousClock.now
        #expect(c.admit(nil, interval: interval, at: t0) == .run)
        #expect(c.admit(nil, interval: interval, at: t0 + .milliseconds(1)) != .run)
        // …and it does not throttle a real collection, which is a different key.
        #expect(c.admit(UUID(), interval: interval, at: t0 + .milliseconds(1)) == .run)
    }

    @Test("a signal past the window runs, and clears the owed trailing run")
    func windowExpiryRuns() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(1)) != .run)
        #expect(c.isHolding(a))
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(500)) == .run)
        #expect(!c.isHolding(a))
    }

    @Test("release restarts the window from when the deferred work actually ran")
    func releaseRestartsTheWindow() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(100))
                == .hold(after: .milliseconds(400)))

        // The caller's deferred task fires at the end of the window and says so.
        c.release(a, at: t0 + .milliseconds(500))
        #expect(!c.isHolding(a))
        // A signal arriving straight after is inside the NEW window, not the old one.
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(510))
                == .hold(after: .milliseconds(490)))
    }
}

// MARK: - The trailing run, cancelled (099 · P4 — P3's third handoff)

@MainActor
@Suite("Coalescer: the trailing run can be called off (099 · P4)", .timeLimit(.minutes(1)))
struct CoalescerCancellationTests {

    private let interval: Duration = .milliseconds(500)

    /// The pure half. [472](../../.change-log/472-the-feed-gets-a-model-of-its-own.md)
    /// closed by naming this: *"there is no token to cancel it with and nothing
    /// asserts there is not one."* `cancelTrailing` is the token's other half —
    /// without it a cancelled task leaves the key marked as owing a run, and every
    /// signal for the rest of that window answers `.held`, waiting on a task that no
    /// longer exists.
    @Test("cancelling the owed run frees the key without moving its window")
    func cancelTrailingFreesTheKey() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(100))
                == .hold(after: .milliseconds(400)))
        #expect(c.isHolding(a))

        c.cancelTrailing(a)
        #expect(!c.isHolding(a))
        // The window itself did NOT move — nothing ran — so the next signal inside
        // it owes a fresh trailing run measured from the ORIGINAL leading edge.
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(200))
                == .hold(after: .milliseconds(300)))
    }

    @Test("cancelling a key that owes nothing is a no-op, not a reset")
    func cancelTrailingOnAnIdleKey() {
        var c = Coalescer<UUID?>()
        let a = UUID()
        let t0 = ContinuousClock.now
        #expect(c.admit(a, interval: interval, at: t0) == .run)
        c.cancelTrailing(a)
        #expect(!c.isHolding(a))
        // Still inside the window the leading edge opened.
        #expect(c.admit(a, interval: interval, at: t0 + .milliseconds(10)) != .run)
    }

    /// The model half: the deferred reload is now a task the model HOLDS, so it can
    /// be called off — and, because it captures `[weak self]`, a model that goes
    /// away mid-window is not kept alive by its own debounce. That is what P3 meant
    /// by "a real cost the moment a second window's model is short-lived".
    @Test("a held ingest reload is owed, and can be called off")
    func pendingIngestReloadIsCancellable() async throws {
        let dbPath = NSTemporaryDirectory() + "coalescer-cancel-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        let unsorted = model.unsortedFolderID

        #expect(!model.hasPendingIngestReload(touching: unsorted))
        model.refreshAfterIngest(touching: unsorted)            // leading edge — runs
        #expect(!model.hasPendingIngestReload(touching: unsorted))
        model.refreshAfterIngest(touching: unsorted)            // inside the window
        #expect(model.hasPendingIngestReload(touching: unsorted))

        model.cancelPendingIngestReloads()
        #expect(!model.hasPendingIngestReload(touching: unsorted))
        // …and the coalescer agrees, so the rest of the window is not spent waiting
        // on a task that was cancelled.
        model.refreshAfterIngest(touching: unsorted)
        #expect(model.hasPendingIngestReload(touching: unsorted))
    }
}
