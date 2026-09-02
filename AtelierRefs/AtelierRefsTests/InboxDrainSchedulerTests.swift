//
//  InboxDrainSchedulerTests.swift
//  AtelierRefsTests
//
//  092 · S3 — the cadence the drain deliberately does not own: a pass at launch,
//  a pass on every activation, never two at once.
//
//  The pass itself is injected, which is what makes the SCHEDULE testable at all:
//  a real `InboxDrain` over a real directory finishes in microseconds, so "two
//  activations did not overlap" could only ever be asserted by luck. Here the pass
//  is held open on a gate, so the overlapping case is the deterministic one rather
//  than the rare one. The drain's own behaviour — what a pass does to records — is
//  covered in `AtelierIngestionTests` against real files; nothing here re-tests it.
//
//  Each case runs on its OWN `NotificationCenter`, so a test cannot be woken by
//  the test runner's app becoming active around it, and two cases running back to
//  back cannot post into each other.
//
//  **What the cases assert did not change when the scheduler did** (098 · finding 5).
//  The guard-and-claim they drive is `InboxDrainPolicy`'s now and the scheduler is an
//  adapter over it; every assertion below is the assertion it was, against the same
//  `start()` / `drain()` / `currentPass` / `isDraining` surface. That is the point of
//  running them unchanged: the policy's own 39 tests prove the rule, and these prove the
//  Mac still gets THAT rule, through its own notification, with its own idempotence.
//
//  The gate is ``AtelierCaptureTestSupport``'s (098 · finding 12). This file held the
//  third of three, in the third shape; 457 replaced the two in the packages and could
//  not reach this one, because the Mac's bundle did not link the fixtures. It is a
//  `Mutex`-guarded class whose `open()` is SYNCHRONOUS by design — an actor would insert
//  a suspension point between opening the gate and the next assertion, and reorder every
//  claim a test makes about what happened next.
//

import AppKit
import AtelierCaptureTestSupport
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

/// A scheduler over a counting pass, plus the knobs a test drives it with.
@MainActor
private final class Rig {
    let center = NotificationCenter()
    let gate = Gate()
    /// How many passes have STARTED. Incremented before the gate, so it counts
    /// entries rather than completions.
    private(set) var passes = 0
    /// How many times the refresh callback fired.
    private(set) var refreshes = 0
    /// What each successive pass returns; the last value repeats once exhausted.
    var summaries: [DrainSummary] = [DrainSummary()]
    /// Whether the pass parks on the gate. Off by default so most cases run to
    /// completion without any sequencing.
    var holdsOpen = false

    private(set) var scheduler: InboxDrainScheduler!

    init() {
        scheduler = InboxDrainScheduler(
            center: center,
            pass: { [weak self] in
                guard let self else { return DrainSummary() }
                let index = passes
                passes += 1
                if holdsOpen { await gate.wait() }
                return summaries[min(index, summaries.count - 1)]
            },
            onIngest: { [weak self] in self?.refreshes += 1 })
    }

    /// Post the activation the scheduler subscribes to.
    func activate() {
        center.post(name: InboxDrainScheduler.activationNotification, object: nil)
    }

    /// Let the in-flight pass finish and settle everything it kicked off.
    func settle() async {
        let pass = scheduler.currentPass
        gate.open()
        await pass?.value
    }

    /// Poll until `condition` holds — the scheduler's pass is an unstructured
    /// `Task`, so there is no chain to await before it has been claimed.
    func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

@MainActor
@Suite("InboxDrainScheduler: launch, activation, no overlap (092 · S3)")
struct InboxDrainSchedulerTests {

    // MARK: - Launch

    @Test("start() runs a pass at launch")
    func launchDrains() async throws {
        let rig = Rig()
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
    }

    @Test("a second start() neither drains again nor double-subscribes")
    func startIsIdempotent() async throws {
        let rig = Rig()
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        rig.scheduler.start()
        // One activation, one pass — not two, which is what a second subscription
        // on the same notification would produce for the rest of the app's life.
        rig.activate()
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
        #expect(rig.passes == 2)
    }

    // MARK: - Activation

    @Test("becoming active runs another pass")
    func activationDrains() async throws {
        let rig = Rig()
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        rig.activate()
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()

        rig.activate()
        #expect(await rig.waitUntil { rig.passes == 3 })
        await rig.settle()
    }

    @Test("no activation is observed before start()")
    func dormantUntilStarted() async throws {
        let rig = Rig()
        rig.activate()
        // Nothing is subscribed yet, so this must reach nothing at all — a
        // scheduler that drained here would be draining before the library opened.
        #expect(await rig.waitUntil(timeout: 0.2) { rig.passes > 0 } == false)
        #expect(rig.scheduler.isDraining == false)
    }

    // MARK: - Overlap

    @Test("an activation during a running pass does NOT start a second one")
    func activationDuringPassIsDropped() async throws {
        let rig = Rig()
        rig.holdsOpen = true
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        #expect(rig.scheduler.isDraining)

        // Three activations while the first pass is parked mid-flight: ⌘-Tab back,
        // a window raised, a Finder drop. All three must be dropped, not queued —
        // the next pass re-enumerates the directory anyway.
        rig.activate()
        rig.activate()
        rig.activate()
        #expect(await rig.waitUntil(timeout: 0.2) { rig.passes > 1 } == false)
        #expect(rig.passes == 1)

        await rig.settle()
        #expect(rig.scheduler.isDraining == false)
        #expect(rig.passes == 1)
    }

    @Test("the guard is not a latch: activating after a pass finishes drains again")
    func guardReleasesAfterPass() async throws {
        let rig = Rig()
        rig.holdsOpen = true
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        rig.activate()
        #expect(rig.passes == 1)

        await rig.settle()
        #expect(rig.scheduler.isDraining == false)

        // The gate is open now, so this one runs straight through.
        rig.activate()
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
    }

    // MARK: - The result

    @Test("the refresh fires only when a pass ingested something")
    func refreshFollowsIngestedCount() async throws {
        let rig = Rig()
        // Pass 1 does nothing; pass 2 ingests; pass 3 only quarantines and retries.
        rig.summaries = [
            DrainSummary(),
            DrainSummary(ingested: 2),
            DrainSummary(quarantined: 1, retrying: 1),
        ]

        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.refreshes == 0)

        rig.activate()
        #expect(await rig.waitUntil { rig.refreshes == 1 })
        await rig.settle()

        rig.activate()
        #expect(await rig.waitUntil { rig.passes == 3 })
        await rig.settle()
        // A quarantine and a retry changed nothing the grid shows.
        #expect(rig.refreshes == 1)
    }

    @Test("an unreadable inbox is reported but never refreshes")
    func unreadableInboxDoesNotRefresh() async throws {
        let rig = Rig()
        rig.summaries = [DrainSummary(inboxUnreadable: true)]
        rig.scheduler.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        // It goes to the log (20A) and nowhere else — there is no state on the
        // scheduler for a surface to read, which is the assertion: an unreadable
        // inbox must not become UI for a condition the user cannot act on.
        #expect(rig.refreshes == 0)
        #expect(rig.scheduler.isDraining == false)
    }
}
