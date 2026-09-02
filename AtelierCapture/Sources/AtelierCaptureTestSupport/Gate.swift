// AtelierCaptureTestSupport — a latch a task parks on until a test opens it (457).
//
// Three suites had one of these in three shapes: an `actor` in `InboxDrainTests`, a
// `@MainActor` class in `InboxDrainPolicyTests`, and a third in the Mac's scheduler
// tests. They agreed on the contract and not on the spelling, and the contract is the
// part worth having once: `wait()` ignores cancellation on purpose — it is what holds a
// task at the starting line WHILE it is being cancelled — and `open()` is idempotent and
// may run before the first `wait()`, so a test never has to sequence the two.
//
// A lock rather than an actor, so `open()` is synchronous. The policy suite's ordering
// claims are read off a trace after a synchronous `open()`, with no suspension point
// between opening the gate and the next assertion; an actor would have put an `await`
// there and moved every such assertion to after whatever the runtime chose to schedule
// first. The drain suite is indifferent, and the Mac suite (098 · P4) will be.

import Synchronization

/// A gate any number of tasks can park on, opened once.
public final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether ``open()`` has been called.
    public var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    /// Park until the gate opens; return at once if it already has. Cancellation of the
    /// waiting task does not release it.
    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The check and the enqueue are one critical section, so an `open()` that
            // lands between them cannot strand this waiter.
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Release every waiter, now and later. Idempotent.
    public func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        // Resumed outside the lock: a resumed task may run synchronously on some
        // executors, and it must not find the gate held.
        for continuation in waiting { continuation.resume() }
    }
}
