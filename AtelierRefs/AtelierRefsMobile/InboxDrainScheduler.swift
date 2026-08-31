// AtelierRefsMobile — when the phone drains its own inbox (096 · 4, phase 3).
//
// The Mac has a file of this name and this is deliberately NOT it. `InboxDrain.drainOnce()`
// starts nothing, schedules nothing and holds no state between calls, precisely so the
// decision of WHEN belongs to the app — and the two apps are asked that question by two
// different systems. The Mac's answer is an `NSApplication.didBecomeActiveNotification`
// subscription; this one is driven by SwiftUI's `ScenePhase`, which is not a notification,
// is delivered to a View rather than to an object, and does not fire for the value a scene
// launches in. Sharing the Mac's implementation would have meant an `#if os(macOS)` around
// most of its body and an AppKit import in an iOS target. **They share the policy, and the
// policy is what is restated below — not the code.**
//
// **Launch, and every return to the foreground. No timer, no watcher, no background task.**
// A pass runs once when the library opens and again whenever the scene becomes active. A
// capture reaches `inbox/` from the share extension — another process, while this app is
// backgrounded or not running at all — so foregrounding is both the cheap approximation of
// "something may have arrived" and the moment the user is looking for it. An empty inbox
// costs one `contentsOfDirectory`, so the pass is free in the case it is in nearly always.
//
// `BGTaskScheduler` was considered and refused: it would drain while nobody is looking, at
// the cost of a background-modes entitlement, a second lifetime to own, and a code path
// that only ever runs where it cannot be observed. Nothing here needs to have happened
// before the user opens the app, because the only surface that reads the result is the
// grid they are opening.
//
// **The grid is not gated on the pass.** ``LibraryStore/bootstrap()`` finishes, the feed
// renders what the library already holds, and the drain runs behind it; a pass that ingests
// something calls `onIngest` and the feed re-reads. So launch latency is a database read
// and never a backlog of image decodes — which matters most on exactly the phone that has
// the biggest backlog.
//
// **One thing at a time, and the export is the other thing.** Two concurrent passes over one
// directory would race each other's moves — both enumerate the same record, both decode it,
// both hand it to the coordinator — so an activation that finds a pass running is DROPPED
// rather than queued: the drain re-enumerates from scratch every time, so the running pass
// will see anything the dropped one would have. That is the Mac's rule verbatim.
//
// What the Mac does not have is a second writer of the same directory. The phone's export
// (`CaptureExport`) reads the inbox and moves records into `inbox/sent/`, while a pass moves
// them into `inbox/ingested/`; `InboxArchive.pendingRecords(in:)` reads BOTH sets, so a
// record that moves between the two while an archive is being written is a record whose
// payload the archive may resolve from a site it has just left. Id-dedup in the export does
// not absorb that — it de-duplicates a record seen twice, not a file that moved mid-copy.
// So an export takes the inbox exclusively (``exclusively(_:)``): it waits out a pass that
// is already running, and no pass may start until it is done.
//
// The one place this scheduler's policy differs from "drop it, the running pass will see
// it": an activation dropped while an EXPORT holds the inbox is remembered and run
// afterwards. The Mac's argument for dropping rests on there being a pass in flight that
// re-enumerates; during an export there is no such pass, so dropping would simply lose the
// activation until the next one.
//
// Both guards work because this type is `@MainActor`: the read that decides and the write
// that claims are one synchronous step with no suspension between them.
//
// The seam is a closure rather than an `InboxDrain`, for the reason the drain's own header
// gives — AtelierIngestion is kept free of a UI-shaped callback, so the coupling lives here,
// on the app's side of the line.

import AtelierIngestion
import Foundation
import os
import SwiftUI

/// A body that holds the inbox to itself for as long as it runs.
typealias InboxWork = @MainActor () async -> Void

/// Runs an ``InboxWork`` once nothing else is touching the inbox, and keeps a drain pass
/// from starting while it does. What ``InboxDrainScheduler/exclusively(_:)`` provides and
/// what ``CaptureExport`` is built with.
typealias InboxExclusion = @MainActor (@escaping InboxWork) async -> Void

/// Decides when the phone drains its inbox, and what the app does with the result.
@MainActor
final class InboxDrainScheduler {

    /// One pass over the inbox. Injected so the schedule is separable from the drain, and
    /// so this file never has to know what a record is.
    private let pass: @MainActor () async -> DrainSummary

    /// Called after a pass that ingested at least one capture — nothing else is worth a
    /// re-read. Records skipped as incomplete, quarantined, or left for a retry changed
    /// nothing the grid shows.
    private let onIngest: @MainActor () -> Void

    /// Whatever currently holds the inbox — a drain pass, or an export — or `nil` when
    /// nobody does.
    ///
    /// This IS the overlap guard (see the file header). One property for both kinds of
    /// holder rather than two, because "may I touch the inbox" is one question, and a
    /// second flag saying which KIND of holder it is would be a second thing to keep true
    /// for the benefit of nobody who asks. `private(set)` so a caller can await the work it
    /// started rather than sleeping for it.
    private(set) var inFlight: Task<Void, Never>?

    /// How many exports are waiting for the inbox or holding it.
    ///
    /// Not a `Bool`, and not folded into ``inFlight``. An export that is WAITING has not
    /// claimed `inFlight` yet — the pass it is waiting for still holds it — and without
    /// this count a drain kicked off by an activation in that window would claim the inbox
    /// the instant the pass released it, ahead of an export that had been waiting longer.
    /// A count rather than a flag so two exports overlapping cannot have the first one to
    /// finish clear the gate out from under the second.
    private var exportsHolding = 0

    /// An activation that arrived while an export held the inbox, and therefore still owes
    /// a pass. See the file header for why this one is remembered when a dropped
    /// activation normally is not.
    private var missedActivation = false

    /// Whether ``start()`` has already run. The launch pass must happen exactly once even
    /// though the view that calls it may have its `task` re-run.
    private var hasStarted = false

    init(
        pass: @escaping @MainActor () async -> DrainSummary,
        onIngest: @escaping @MainActor () -> Void
    ) {
        self.pass = pass
        self.onIngest = onIngest
    }

    // MARK: - Cadence

    /// Run the launch pass. Idempotent — a second call is a no-op rather than a second
    /// pass, so a view whose `task` re-runs cannot end up draining twice per launch.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        drain()
    }

    /// The scene changed phase; drain if it just became active.
    ///
    /// Every phase is passed in rather than the view deciding, so the rule ("active, and
    /// only active") is stated in one place and a future `.inactive` or `.background`
    /// response has somewhere to go.
    ///
    /// A launch usually delivers `.inactive` → `.active`, which means this normally fires
    /// once immediately after ``start()``. That is harmless and is the same overlap the Mac
    /// has: if the launch pass is still running the activation is dropped, and if it has
    /// already finished the second pass is one `contentsOfDirectory` over an inbox the
    /// first one just emptied.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard phase == .active else { return }
        drain()
    }

    /// Run a pass unless something is already holding the inbox.
    ///
    /// Internal rather than private so a caller can force a pass without faking a scene
    /// phase — the scene-phase path is a one-line adapter and a test that needed it for
    /// every case could not tell "the phase is wired" apart from "draining works".
    func drain() {
        guard inFlight == nil else {
            // A pass is running and re-enumerates from scratch, so it will see whatever
            // this activation would have. Dropped, not queued.
            MobileLog.capture.debug("inbox drain already running; activation pass skipped")
            return
        }
        guard exportsHolding == 0 else {
            // An export holds the inbox and there is no pass in flight to inherit this
            // activation, so it is remembered rather than dropped.
            missedActivation = true
            MobileLog.capture.debug("inbox held by an export; activation pass deferred")
            return
        }
        inFlight = Task { [weak self] in
            guard let self else { return }
            let summary = await pass()
            inFlight = nil
            report(summary)
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
    func exclusively(_ body: @escaping InboxWork) async {
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

        let work = Task { @MainActor in await body() }
        inFlight = work
        await work.value
        // Safe to clear unconditionally: nothing else can have claimed `inFlight` while we
        // held it — a drain is blocked by `exportsHolding` and another export is still in
        // the loop above.
        inFlight = nil
    }

    // MARK: - The result

    /// Log what the pass found, and tell the app if the library changed.
    ///
    /// Nothing here reaches the user directly, which is the Mac's conclusion and 093 § 7's:
    /// an unreadable inbox and a quarantined capture are both conditions a person holding a
    /// phone has no lever for, and the captures are still on disk either way. A quarantine
    /// is louder in consequence and just as unactionable in the moment, so it is logged at
    /// the level that says "someone will want to have seen this".
    private func report(_ summary: DrainSummary) {
        if summary.inboxUnreadable {
            MobileLog.capture.error("inbox could not be enumerated; captures left in place")
        }
        if summary.quarantined > 0 {
            MobileLog.capture.error(
                "\(summary.quarantined) capture(s) moved to inbox/failed/")
        }
        if summary.ingested > 0 || summary.retrying > 0 || summary.skippedIncomplete > 0 {
            MobileLog.capture.notice(
                """
                inbox drain: \(summary.ingested) ingested, \
                \(summary.retrying) retrying, \
                \(summary.skippedIncomplete) incomplete
                """)
        }
        if summary.ingested > 0 { onIngest() }
    }
}
