//
//  EventSignalTests.swift
//  AtelierRefsTests
//
//  099 · 11A — the machinery the timing tests now stand on.
//
//  `EventSignal` is production code (`DetailImageLoader`, `ThumbnailPipeline` and
//  `LibrarySearchModel` each hold one), so it gets its own tests rather than being
//  proven only by the suites that use it. Two properties matter and both are the
//  kind that fail silently: an event emitted while nobody is looking must not
//  block or leak, and an event emitted between a test's subscribe and its await
//  must not be lost — that second one is the whole reason `EventRecorder` records
//  instead of iterating.
//

import Foundation
import Testing

@testable import AtelierRefs

@Suite("EventSignal / EventRecorder (099 · 11A)", .timeLimit(.minutes(1)))
struct EventSignalTests {

    private typealias Signal = EventSignal<Int>

    @Test("with nobody listening, emitting is a no-op that costs a lock")
    func emitWithNoListeners() {
        // The production case: nothing in the app subscribes, so this path runs on
        // every decode and every query and must never block or accumulate.
        let signal = Signal()
        #expect(!signal.hasListeners)
        for value in 0..<1_000 { signal.emit(value) }
        #expect(!signal.hasListeners)
    }

    @Test("a stream receives what is emitted after it was made")
    func streamReceives() async {
        let signal = Signal()
        let recorder = EventRecorder(signal.stream())
        signal.emit(1)
        signal.emit(2)
        await recorder.wait(forAtLeast: 2) { _ in true }
        #expect(recorder.events == [1, 2])
    }

    @Test("two listeners each get every event — one does not consume the other's")
    func fanOut() async {
        // The property that lets a diagnostic watch an object a test is already
        // watching, and the reason this is a broadcast rather than a queue.
        let signal = Signal()
        let a = EventRecorder(signal.stream())
        let b = EventRecorder(signal.stream())
        signal.emit(7)
        await a.wait(forAtLeast: 1) { _ in true }
        await b.wait(forAtLeast: 1) { _ in true }
        #expect(a.events == [7])
        #expect(b.events == [7])
    }

    @Test("a wait whose condition is ALREADY true returns immediately")
    func waitIsNotOnlyForwardLooking() async {
        // This is the bug the first design had. An iterator only ever looks
        // forward, so "wait for the promotion" after the promotion had already
        // happened waited forever — precisely the race the sleeps were papering
        // over, reintroduced by the thing meant to remove them.
        let signal = Signal()
        let recorder = EventRecorder(signal.stream())
        signal.emit(42)
        await recorder.wait(forAtLeast: 1) { $0 == 42 }   // settles the arrival
        await recorder.wait { events in events.contains(42) }   // already true
        #expect(recorder.events == [42])
    }

    @Test("a wait for a count resumes exactly when the count is reached")
    func countedWait() async {
        let signal = Signal()
        let recorder = EventRecorder(signal.stream())
        let waiter = Task { await recorder.wait(forAtLeast: 3) { $0 % 2 == 0 } }
        for value in [1, 2, 3, 4, 5, 6] { signal.emit(value) }
        await waiter.value
        #expect(recorder.count { $0 % 2 == 0 } >= 3)
    }

    @Test("a recorder that goes away unsubscribes, and emitting afterwards is safe")
    func unsubscribeOnDrop() async {
        let signal = Signal()
        do {
            let recorder = EventRecorder(signal.stream())
            signal.emit(1)
            await recorder.wait(forAtLeast: 1) { _ in true }
        }
        // The consuming task is cancelled on deinit and the continuation's
        // termination handler drops the subscription. The emit below must not
        // trap, and must not grow anything.
        signal.emit(2)
        signal.emit(3)
    }

    @Test("events arrive in the order they were emitted")
    func ordering() async {
        let signal = Signal()
        let recorder = EventRecorder(signal.stream())
        for value in 0..<50 { signal.emit(value) }
        await recorder.wait(forAtLeast: 50) { _ in true }
        #expect(recorder.events == Array(0..<50))
    }
}

@MainActor
@Suite("poll — the one bounded wait (099 · 11A)", .timeLimit(.minutes(1)))
struct PollTests {

    @Test("returns true immediately when the condition already holds")
    func immediate() async {
        #expect(await poll { true })
    }

    @Test("returns false after the timeout when it never holds")
    func timesOut() async {
        // Bounded, always — an unbounded wait in a test body stalls the runner
        // with no output, which is the failure 330 records costing 19 minutes.
        #expect(await poll(timeout: .milliseconds(50)) { false } == false)
    }

    // `flips` is the assertion here, not the clock. The condition goes true on the
    // fourth evaluation, so a correct `poll` leaves `flips` in single figures
    // whatever the timeout is — that is what "settles early" MEANS, and it is
    // scale-free. The timeout is only the outer bound, and it was `.seconds(2)`
    // until 099 · P21, which made this a wall-clock test by accident: three 1 ms
    // sleeps have to resume inside two seconds, so ONE stalled `Task.sleep` fails
    // it. That is not hypothetical — it is the most-named flake in this target
    // (470, 471, 473, 475, 476, 478), and 478's run 5 caught the machine behind it
    // with 798 MB of disk left. A bound generous enough that only a genuinely
    // wedged machine trips it costs nothing: the test still returns in ~3 ms, and
    // `flips <= 10` still fails loudly the day `poll` starts running the timeout
    // out instead of settling.
    @Test("settles as soon as the condition becomes true")
    func settlesEarly() async {
        var flips = 0
        let met = await poll(timeout: .seconds(20), interval: .milliseconds(1)) {
            flips += 1
            return flips > 3
        }
        #expect(met)
        #expect(flips <= 10, "polled far past the point the condition was met")
    }
}
