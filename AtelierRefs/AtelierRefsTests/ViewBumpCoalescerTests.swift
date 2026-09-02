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
