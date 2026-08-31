// AtelierBrowse — WHEN the phone drains its inbox, and who is allowed to touch it
// while it does (096 · 4, phase 4).
//
// This type was written in phase 3 as `AtelierRefsMobile/InboxDrainScheduler.swift`,
// and phase 3's own changelog closed by admitting what that cost:
//
//   > `InboxDrainScheduler` has no unit test, and `AtelierRefsMobile` has no test
//   > target. The three properties the design turns on — an activation dropped while
//   > a pass runs, an export waiting out a running pass, and a deferred activation
//   > running after an export — are asserted by construction and by the build, and by
//   > nothing else.
//
// It also rejected moving the gate into a package, on the grounds that AtelierIngestion
// is deliberately free of UI-shaped cadence and AtelierBrowse is the read seam. The
// first half of that still holds and is why this is not in AtelierIngestion. The second
// half was reading this package's NAME rather than its charter. Its manifest states the
// charter in one sentence — *"Logic that lives in `AtelierRefsMobile` is logic nothing
// runs but a person with a phone"* — and this file is the most load-bearing example of
// that sentence in the program: a coalescing rule and a mutual-exclusion rule over a
// directory two processes write, whose failure modes are a lost capture and a corrupt
// archive, and whose entire proof was "read the code and agree".
//
// "Browse" was an accurate name for the package while the phone only read. Phase 3 gave
// the phone a writer; what is here is still the same kind of thing — a companion-app
// decision that is not a view, put where `swift test` can reach it.
//
// **What stays in the app, and why it genuinely has to.** SwiftUI's `ScenePhase`, and
// nothing else. ``ScenePhaseKind`` below is its three cases without the import;
// `AtelierRefsMobile/InboxDrainScheduler.swift` is now a one-line map from one to the
// other plus the log lines. Importing SwiftUI here to spell one enum would have put a UI
// framework inside the package whose whole argument is that it needs no device.
//
// **Why it is generic over what a pass returns.** The policy decides WHETHER and WHEN a
// pass runs; it has no opinion whatsoever about what a pass found. Typing `Outcome` as
// `DrainSummary` would mean this package importing AtelierIngestion — the entire ingest
// pipeline — to name the return type of one closure it only ever hands straight back to
// its caller. The generic costs nothing at the call site (`InboxDrainPolicy<DrainSummary>`,
// spelled once, behind a typealias) and it keeps the boundary in the manifest true.
//
// ---
//
// The policy itself, restated. `InboxDrain.drainOnce()` starts nothing, schedules nothing
// and holds no state between calls, precisely so the decision of WHEN belongs to the app —
// and the Mac and the phone are asked that question by two different systems. The Mac
// subscribes to `NSApplication.didBecomeActiveNotification`; the phone is told through
// SwiftUI's `ScenePhase`, which is not a notification, is delivered to a View rather than
// to an object, and does not fire for the value a scene launches in. The two share this
// policy and no code.
//
// **Launch, and every return to the foreground. No timer, no watcher, no background
// task.** A pass runs once when the library opens and again whenever the scene becomes
// active. A capture reaches `inbox/` from the share extension — another process, while
// this app is backgrounded or not running at all — so foregrounding is both the cheap
// approximation of "something may have arrived" and the moment the user is looking for
// it. An empty inbox costs one `contentsOfDirectory`, so the pass is free in the case it
// is in nearly always.
//
// `BGTaskScheduler` was considered and refused: it would drain while nobody is looking, at
// the cost of a background-modes entitlement, a second lifetime to own, and a code path
// that only ever runs where it cannot be observed. Nothing here needs to have happened
// before the user opens the app, because the only surface that reads the result is the
// grid they are opening.
//
// **The grid is not gated on the pass.** The library opens, the feed renders what is
// already in it, and the drain runs behind it; a pass that ingests something reports it
// and the feed re-reads. So launch latency is a database read and never a backlog of
// image decodes — which matters most on exactly the phone that has the biggest backlog.
//
// **One thing at a time, and the export is the other thing.** Two concurrent passes over
// one directory would race each other's moves — both enumerate the same record, both
// decode it, both hand it to the coordinator — so an activation that finds a pass running
// is DROPPED rather than queued: the drain re-enumerates from scratch every time, so the
// running pass will see anything the dropped one would have. That is the Mac's rule
// verbatim.
//
// What the Mac does not have is a second writer of the same directory. The phone's export
// (`CaptureExport`) reads the inbox and moves records into `inbox/sent/`, while a pass
// moves them into `inbox/ingested/`; `InboxArchive.pendingRecords(in:)` reads BOTH sets,
// so a record that moves between the two while an archive is being written is a record
// whose payload the archive may resolve from a site it has just left. Id-dedup in the
// export does not absorb that — it de-duplicates a record seen twice, not a file that
// moved mid-copy. So an export takes the inbox exclusively (``exclusively(_:)``): it waits
// out a pass that is already running, and no pass may start until it is done.
//
// The one place this policy differs from "drop it, the running pass will see it": an
// activation dropped while an EXPORT holds the inbox is remembered and run afterwards. The
// Mac's argument for dropping rests on there being a pass in flight that re-enumerates;
// during an export there is no such pass, so dropping would simply lose the activation
// until the next one.
//
// Both guards work because this type is `@MainActor`: the read that decides and the write
// that claims are one synchronous step with no suspension between them.
//
// The seam is a closure rather than an `InboxDrain`, for the reason the drain's own header
// gives — AtelierIngestion is kept free of a UI-shaped callback, so the coupling lives on
// the app's side of the line.

import Foundation

/// A body that holds the inbox to itself for as long as it runs.
public typealias InboxWork = @MainActor () async -> Void

/// Runs an ``InboxWork`` once nothing else is touching the inbox, and keeps a drain pass
/// from starting while it does. What ``InboxDrainPolicy/exclusively(_:)`` provides and
/// what the companion's `CaptureExport` is built with.
public typealias InboxExclusion = @MainActor (@escaping InboxWork) async -> Void

/// SwiftUI's `ScenePhase`, minus SwiftUI.
///
/// Three cases with the same names and the same meanings, declared here so that the rule
/// this policy is built on — *active, and only active* — is stated in the package a test
/// can reach rather than in the app target it cannot. The app maps one to the other in a
/// single `switch`; see `AtelierRefsMobile/InboxDrainScheduler.swift`.
///
/// It is a mirror rather than a subset because a future `.background` or `.inactive`
/// response needs somewhere to go, and because a two-case enum would make the mapping
/// lossy in a way the next reader would have to reconstruct from the call site.
public enum ScenePhaseKind: Sendable, Equatable, CaseIterable {
    case active
    case inactive
    case background
}

/// Something the cadence did with an activation that was not "ran a pass".
///
/// Both cases are the interesting half of this type's design and neither leaves a trace in
/// the outcome of any pass — the dropped one is absorbed by a pass that was already
/// running, the deferred one turns into an ordinary pass some time later. Phase 3 logged
/// them at `.debug` from inside the scheduler; reporting them instead keeps that log line
/// in the app, where the `Logger` is, and lets a test tell the two paths apart directly
/// rather than by their consequences.
public enum InboxDrainEvent: Sendable, Equatable {
    /// An activation arrived while a pass was running. Dropped: the running pass
    /// re-enumerates from scratch and will see whatever this one would have.
    case activationDroppedDuringPass
    /// An activation arrived while an export held the inbox. Remembered, and run when the
    /// last export lets go — there was no pass in flight to inherit it.
    case activationDeferredDuringExport
}

/// Decides when the phone drains its inbox, and hands the result back to whoever cares.
///
/// `Outcome` is whatever one pass returns — `DrainSummary` in the app. This type never
/// looks inside it; see the file header for why it is a type parameter and not an import.
@MainActor
public final class InboxDrainPolicy<Outcome> {

    /// One pass over the inbox. Injected so the schedule is separable from the drain, and
    /// so this file never has to know what a record is.
    private let pass: @MainActor () async -> Outcome

    /// Called once per completed pass, with what that pass returned.
    ///
    /// Deliberately after ``inFlight`` is cleared: the report is the app's business — a
    /// log line and, when something was ingested, a counter the grids are keyed on — and
    /// holding the inbox while the UI reacts to it would make every screen's re-read part
    /// of the window in which no other pass may start.
    private let report: @MainActor (Outcome) -> Void

    /// Told about the activations that did NOT become passes. Optional, and `nil` by
    /// default, because it is an observation hook and not a policy: a caller that does not
    /// pass one gets the same cadence, not a different one.
    private let observe: (@MainActor (InboxDrainEvent) -> Void)?

    /// Whatever currently holds the inbox — a drain pass, or an export — or `nil` when
    /// nobody does.
    ///
    /// This IS the overlap guard (see the file header). One property for both kinds of
    /// holder rather than two, because "may I touch the inbox" is one question, and a
    /// second flag saying which KIND of holder it is would be a second thing to keep true
    /// for the benefit of nobody who asks. `private(set)` so a caller can await the work it
    /// started rather than sleeping for it.
    public private(set) var inFlight: Task<Void, Never>?

    /// Whether anything holds the inbox right now. The Mac's scheduler exposes the same
    /// property under the same name; it is what a caller asks when it wants the fact
    /// rather than the task.
    public var isDraining: Bool { inFlight != nil }

    /// How many exports are waiting for the inbox or holding it.
    ///
    /// Not a `Bool`, and not folded into ``inFlight``. An export that is WAITING has not
    /// claimed `inFlight` yet — the pass it is waiting for still holds it — and without
    /// this count a drain kicked off by an activation in that window would claim the inbox
    /// the instant the pass released it, ahead of an export that had been waiting longer.
    /// A count rather than a flag so two exports overlapping cannot have the first one to
    /// finish clear the gate out from under the second.
    ///
    /// Readable because it is the one piece of this type's state whose going wrong is
    /// silent: a count left above zero stops the phone draining for the rest of the
    /// launch and nothing anywhere reports it. `InboxDrainPolicyTests` asserts it returns
    /// to zero after every shape of export the design allows.
    public private(set) var exportsHolding = 0

    /// An activation that arrived while an export held the inbox, and therefore still owes
    /// a pass. See the file header for why this one is remembered when a dropped
    /// activation normally is not.
    private var missedActivation = false

    /// Whether ``start()`` has already run. The launch pass must happen exactly once even
    /// though the view that calls it may have its `task` re-run.
    private var hasStarted = false

    public init(
        pass: @escaping @MainActor () async -> Outcome,
        report: @escaping @MainActor (Outcome) -> Void,
        observe: (@MainActor (InboxDrainEvent) -> Void)? = nil
    ) {
        self.pass = pass
        self.report = report
        self.observe = observe
    }

    // MARK: - Cadence

    /// Run the launch pass. Idempotent — a second call is a no-op rather than a second
    /// pass, so a view whose `task` re-runs cannot end up draining twice per launch.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        drain()
    }

    /// The scene changed phase; drain if it just became active.
    ///
    /// Every phase is passed in rather than the caller deciding, so the rule ("active, and
    /// only active") is stated in one place and a future `.inactive` or `.background`
    /// response has somewhere to go.
    ///
    /// A launch usually delivers `.inactive` → `.active`, which means this normally fires
    /// once immediately after ``start()``. That is harmless and is the same overlap the Mac
    /// has: if the launch pass is still running the activation is dropped, and if it has
    /// already finished the second pass is one `contentsOfDirectory` over an inbox the
    /// first one just emptied.
    public func scenePhaseChanged(to phase: ScenePhaseKind) {
        guard phase == .active else { return }
        drain()
    }

    /// Run a pass unless something is already holding the inbox.
    ///
    /// Public rather than internal so a caller can force a pass without faking a scene
    /// phase — the scene-phase path is a one-line adapter and a test that needed it for
    /// every case could not tell "the phase is wired" apart from "draining works".
    public func drain() {
        // **The export check comes FIRST, and phase 3 had these two the other way round.**
        // `inFlight` deliberately does not say WHICH kind of holder it is, which is right
        // for "may I touch the inbox" and wrong for "will anybody serve this activation".
        // Asking `inFlight` first meant that for the whole duration of an export BODY —
        // the archive copy, the retirement, the case this deferral was written for — an
        // activation took the dropped branch and was lost, because the export had claimed
        // `inFlight` and so the first guard answered before the second was ever reached.
        // Only the sliver where an export sat waiting with the inbox momentarily free
        // reached the branch below, which is not a state the app can produce with one
        // export at a time. The behaviour phase 3's header describes is the behaviour
        // below; this order is what makes it true.
        guard exportsHolding == 0 else {
            // An export holds the inbox, or is queued for it. Either way this activation
            // is remembered rather than dropped. Where a drain pass in flight will
            // re-enumerate and pick up whatever arrived, an export will not: it copies
            // records out and moves them, and it hands the inbox back to nobody. The
            // deferral costs at most one extra `contentsOfDirectory` over an inbox a pass
            // has just emptied, against losing a capture until the next foreground.
            missedActivation = true
            observe?(.activationDeferredDuringExport)
            return
        }
        guard inFlight == nil else {
            // A pass is running and re-enumerates from scratch, so it will see whatever
            // this activation would have. Dropped, not queued.
            observe?(.activationDroppedDuringPass)
            return
        }
        inFlight = Task { [weak self] in
            guard let self else { return }
            let outcome = await pass()
            inFlight = nil
            report(outcome)
        }
    }

    // MARK: - The inbox, exclusively

    /// Run `body` with the inbox to itself: wait out whatever holds it, hold it for the
    /// duration, and let a deferred activation through afterwards.
    ///
    /// Used by the export, which reads every record in the inbox and moves the ones it sent
    /// — both of which a drain pass moving records underneath would corrupt. See the file
    /// header for why the export's own id-dedup is not an answer to that.
    ///
    /// The wait is a loop rather than a single `await` because the thing being waited for
    /// can change while waiting: a second export that arrived first will have claimed
    /// ``inFlight`` by the time a drain pass releases it. Re-reading after each await is
    /// what makes two exports serialize instead of both proceeding.
    public func exclusively(_ body: @escaping InboxWork) async {
        // Claimed BEFORE the wait, so no activation can start a pass in the window between
        // the current holder finishing and this body claiming `inFlight`.
        exportsHolding += 1
        // In a `defer` because this counter going out of balance does not fail anything
        // loudly — it silently stops the phone draining for the rest of the launch. There
        // is no early exit on this path today; the point is that adding one cannot break it.
        defer {
            exportsHolding -= 1
            if exportsHolding == 0, missedActivation {
                missedActivation = false
                drain()
            }
        }

        while let holder = inFlight { await holder.value }

        // **The task releases the inbox from INSIDE, before it completes**, which is what
        // a drain pass already does and what phase 3's export did not: it awaited the task
        // and cleared `inFlight` afterwards.
        //
        // That afterwards is a real gap. Everything waiting on this task resumes the moment
        // it completes, and the loop above re-reads `inFlight` on each resumption. A second
        // export woken before the first's own continuation gets a turn would read the
        // finished task, `await` a value that is already there — which does not suspend —
        // re-read the same finished task, and go round again, on the main actor, forever.
        // The first export never gets scheduled to clear the flag, so the loop never ends:
        // a live-lock at 100% of one core, in exactly the two-overlapping-exports case the
        // ``exportsHolding`` comment above says the count exists to handle.
        //
        // Clearing inside the body closes it: a waiter that resumes on completion always
        // observes a released inbox, and there is no window in which a finished task is
        // still the holder. It is also the reason there is no `inFlight = nil` after the
        // await — by then another export may legitimately hold it.
        let work = Task { @MainActor [weak self] in
            await body()
            self?.inFlight = nil
        }
        inFlight = work
        await work.value
    }
}
