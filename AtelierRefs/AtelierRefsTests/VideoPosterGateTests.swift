//
//  VideoPosterGateTests.swift
//  AtelierRefsTests
//
//  489 — the detail page's video poster came down on ONE of the three ways its wait
//  could end, and the other two left an opaque still over a video that was playing
//  underneath it. This suite is the statement that every exit lifts.
//
//  Driven through ``VideoPosterGate/firstFrame(statuses:lift:)`` rather than the
//  view, which is the standing strategy for this area (`DetailPostTests`: the logic
//  lives beside the view and "should not be tested through the view"). The point of
//  the seam is right here — a real `AVPlayerItem` cannot be asked to end its status
//  sequence without ever leaving `.unknown`, and that is the case that shipped
//  broken. An `AsyncStream` can be asked, so the regression is a test rather than a
//  bug report.
//
//  **Every test counts the LIFT, not just the returned reason.** The reason is
//  diagnostic; the lift is the behaviour, and it is the thing that was missing. A
//  suite that only checked the returned `VideoPosterLift` would pass against a gate
//  that reported `.sequenceEnded` accurately and still left the poster up.
//
//  `.timeLimit` is load-bearing, not decoration: the failure mode of a gate that
//  does not return is a hung test, and a hung test is the same silence as the bug.
//

import AVFoundation
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("VideoPosterGate", .timeLimit(.minutes(1)))
struct VideoPosterGateTests {

    /// Counts the lifts. The gate must call it exactly once per wait — never zero
    /// (the poster strands) and never twice (the lift is not idempotent in spirit,
    /// even though setting a Bool twice is harmless: two calls would mean two exits).
    private final class LiftCounter {
        private(set) var count = 0
        func lift() { count += 1 }
    }

    /// A finite stream of statuses — the sequence the view's KVO publisher stands in
    /// for, with an end the test controls.
    private func stream(_ values: [AVPlayerItem.Status]) -> AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }

    // MARK: - The three exits

    @Test("no player item lifts the poster rather than waiting on nothing")
    func noItemLifts() async {
        let counter = LiftCounter()
        let lift = await VideoPosterGate.firstFrame(
            statuses: Optional<AsyncStream<AVPlayerItem.Status>>.none,
            lift: counter.lift)
        #expect(lift == .noItem)
        #expect(counter.count == 1)
    }

    @Test("a real status lifts, and `.unknown` before it is skipped, not counted")
    func readyToPlayLifts() async {
        let counter = LiftCounter()
        let lift = await VideoPosterGate.firstFrame(
            statuses: stream([.unknown, .unknown, .readyToPlay]),
            lift: counter.lift)
        #expect(lift == .status(.readyToPlay))
        #expect(counter.count == 1)
    }

    /// `.failed` lifting is a DECISION, not an oversight — a poster held over a player
    /// that will never draw looks exactly like a working video that refuses to play,
    /// and it hides the error state, which is the one signal a person could report.
    @Test("`.failed` lifts the poster too, deliberately")
    func failedLifts() async {
        let counter = LiftCounter()
        let lift = await VideoPosterGate.firstFrame(
            statuses: stream([.unknown, .failed]), lift: counter.lift)
        #expect(lift == .status(.failed))
        #expect(counter.count == 1)
    }

    // MARK: - The regression (489)

    /// The shipped bug, in one line: the sequence ends without ever leaving
    /// `.unknown`. Before the fix the wait returned having set nothing, the view's
    /// `videoReady` stayed false with `player` already assigned, and
    /// `.task(id: asset.id)` never re-ran for an id that had not changed.
    @Test("a sequence that ends without a status still lifts")
    func sequenceEndingWithoutAStatusLifts() async {
        let counter = LiftCounter()
        let lift = await VideoPosterGate.firstFrame(
            statuses: stream([.unknown]), lift: counter.lift)
        #expect(lift == .sequenceEnded)
        #expect(counter.count == 1)
    }

    /// And the way it actually happened in the running app: `.task(id:)` cancelled the
    /// wait mid-flight. `for await` does NOT throw on cancellation — it ends — so the
    /// only thing that makes this safe is the `defer` inside the gate.
    ///
    /// The stream here never finishes on its own and never leaves `.unknown`, so the
    /// ONLY way this test completes is cancellation ending the iteration. If the gate
    /// ever goes back to waiting for a status it cannot get, this hangs and the time
    /// limit fails it.
    @Test("a cancelled wait lifts instead of stranding the poster")
    func cancelledWaitLifts() async {
        let counter = LiftCounter()
        let held = AsyncStream<AVPlayerItem.Status>.makeStream()
        held.continuation.yield(.unknown)

        let task = Task { @MainActor in
            await VideoPosterGate.firstFrame(statuses: held.stream, lift: counter.lift)
        }
        task.cancel()

        #expect(await task.value == .sequenceEnded)
        #expect(counter.count == 1)
        // Keep the continuation alive to the end: a finished-by-deallocation stream
        // would end the iteration for a reason that is not the one under test.
        held.continuation.finish()
    }
}
