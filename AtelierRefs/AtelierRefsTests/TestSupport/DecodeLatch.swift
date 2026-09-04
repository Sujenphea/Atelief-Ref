//
//  DecodeLatch.swift
//  AtelierRefsTests
//
//  099 · P21 — the one-way gate a decode probe blocks on, and the only blocking
//  primitive these suites are allowed to use.
//
//  Both image suites need the same thing: hold a decode still, observe queueing
//  or promotion or cancellation while it is held, then let it go. The obvious
//  spelling is `DispatchSemaphore(value: 0)` / `signal()`, and it is wrong in two
//  ways that do not show up as a failing test. They show up as a GREEN suite that
//  poisons every suite after it, because both failure modes leak a thread rather
//  than raise an issue:
//
//   • **A counting semaphore is not a gate.** One `signal()` admits exactly one
//     waiter. Every test using one therefore hard-codes a decode COUNT — release
//     twice for two blocked hashes — and that count is a bet on loader internals,
//     not a property the test is asserting. The moment a regression causes one
//     extra decode (a preload re-run, a coalesce that stopped coalescing) the
//     surplus decode waits on a signal that will never come. The regression the
//     test exists to catch is the very thing that stops it reporting.
//
//   • **`DispatchSemaphore.wait()` ignores task cancellation.** It is not a
//     suspension point; it parks the OS thread. `Task.detached` bodies run on the
//     cooperative pool, which is `activeProcessorCount` threads wide — eight on
//     this machine — so each stuck waiter retires 1/8th of the runner's total
//     concurrency FOR THE LIFE OF THE PROCESS. A `.timeLimit` trait does not give
//     it back: the trait fails the test, the thread stays parked.
//
//  The consequence is the part worth remembering, because it cost a long
//  diagnosis twice. The suite that leaks the thread is usually NOT the suite that
//  fails. Once enough threads are gone, an unrelated test elsewhere in the target
//  cannot be scheduled and trips its own time limit — so the gate reports a
//  different, innocent, often entirely synchronous test each run
//  (`.change-log/330` for the thumbnail suites; a three-line
//  `Coalescer.cancelTrailingOnAnIdleKey` recorded at a flat 60.000 seconds for
//  the detail suite). A synchronous test cannot hang. If one times out, suspect
//  a starved pool, not the test named in the report.
//
//  So this type is both properties at once, and the probes get no other option:
//
//   • **It is a LATCH.** ``open()`` opens the gate for good and broadcasts, so a
//     decode arriving after it does not block and a surplus decode cannot strand.
//     Callers say "let everything through" once; there is no count to get wrong.
//   • **The wait is BOUNDED.** On timeout it sets ``timedOutWaiting`` and returns,
//     so the decode completes, the test reaches its assertions, and the suite
//     fails in seconds with a comprehensible message. Assert on it: a true here
//     means the test's premise did not hold, and it is the flag that would
//     otherwise have been a silent nineteen-minute stall.
//
//  `nonisolated` + `@unchecked Sendable`: probes hand their `decode` to the
//  pipeline as a `@Sendable` closure and it runs off the main actor, so the latch
//  it closes over must cross isolation too. `NSCondition` is the whole of the
//  synchronisation — and, unlike a lock held across a wait, it drops the lock
//  while waiting, so a blocked decode never keeps another from proceeding.
//
import Foundation

nonisolated final class DecodeLatch: @unchecked Sendable {
    /// How long a blocked caller waits for ``open()`` before giving up. Long
    /// enough that a merely slow machine never trips it, short enough that the
    /// suite still finishes well inside a one-minute `.timeLimit`.
    static let defaultTimeout: TimeInterval = 10

    private let condition = NSCondition()
    private var isOpen = false
    private var timedOut = false
    private let timeout: TimeInterval

    init(timeout: TimeInterval = DecodeLatch.defaultTimeout) {
        self.timeout = timeout
    }

    /// Block until ``open()``, or until the bound expires. Returns immediately —
    /// and forever after — once the latch is open.
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        // Deadline is computed once: a spurious wakeup must not extend the bound.
        let deadline = Date().addingTimeInterval(timeout)
        while !isOpen {
            if !condition.wait(until: deadline) {
                timedOut = true
                return
            }
        }
    }

    /// Open the gate: every waiter proceeds, now and in future.
    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    /// True if any waiter gave up. Assert on it — see the note above.
    var timedOutWaiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }
}
