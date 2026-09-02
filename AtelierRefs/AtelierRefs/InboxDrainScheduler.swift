//
//  InboxDrainScheduler.swift
//  AtelierRefs
//
//  092 · S3 — the CADENCE half of the iOS handoff, and since 098 · finding 5 the
//  AppKit adapter over a policy this app no longer owns.
//
//  `InboxDrain.drainOnce()` runs the inbox as it stands and returns what happened;
//  it starts nothing, schedules nothing, and holds no state between calls,
//  precisely so that the decision of WHEN to run belongs to the app. Until this
//  file existed, nobody made it: the writer, the layout, the drain and their tests
//  were all built and proven, and `drainOnce()` had no caller anywhere in the app.
//  A share sent from the phone landed in `inbox/` and stayed there.
//
//  **What this file used to be, and why it is not that any more.** It held the
//  guard-and-claim — read `currentPass`, claim it, run, release — spelled out here
//  in ten lines. 454 gave the phone the same rule, restated; 455 named the
//  duplication and left it; 096 · 4 phase 4 then moved the phone's copy into
//  `AtelierBrowse/InboxDrainPolicy.swift`, where `swift test` could reach it — and
//  the 39 tests written against it found TWO live bugs in a rule both platforms had
//  been reading and agreeing with for months (a guard order that lost every
//  activation during an export body, and a live-lock between two overlapping
//  exports). This app kept the untested copy of half of that rule until now.
//
//  So the guard, the claim, the release-from-inside and the idempotent launch pass
//  are `InboxDrainPolicy`'s, and this file is the two things that genuinely are the
//  Mac's:
//
//  1. **`NSApplication.didBecomeActiveNotification`.** The Mac is asked "are you
//     active?" by AppKit, through a notification, delivered to an observer object.
//     The phone is told by SwiftUI's `ScenePhase`, which is not a notification, is
//     delivered to a View, and does not fire for the value a scene launches in.
//     That is the whole reason two adapters exist over one policy, and it is why
//     this type is a class holding a policy rather than the phone's typealias: the
//     subscription is state, and the policy has nowhere to put it.
//  2. **`AppLog`.** Which `Logger` a report line goes to. The lines themselves are
//     `DrainSummary.reportLines`' since 098 · finding 5.
//
//  **Launch, and every activation. No timer, no watcher.** A pass runs once at
//  launch, and again whenever the app becomes active. Activation is the cheap
//  approximation of "something may have arrived": records reach the inbox by
//  AirDrop or iCloud Drive while the Mac app is already running, and the moment
//  the user comes back to the window is both the moment they might look for the
//  capture and a moment the app is already doing work. An empty inbox costs one
//  `contentsOfDirectory`, so the pass is free in the case it is in nearly always.
//  A timer would spend that call forever for the same result; an `FSEvents`
//  watcher would be a second lifetime to own, a second failure mode, and would
//  still need the launch pass for everything that arrived while the app was shut.
//
//  **One pass at a time**, which is now the policy's guard rather than this file's.
//  Activation can fire while a pass is still running — ⌘-Tab away and back, a
//  second window raised, a Finder drop that activates the app — and two concurrent
//  passes over one directory would race each other's deletes. An activation that
//  finds a pass running is DROPPED, not queued: the drain re-enumerates the
//  directory from scratch every time, so a pass already running will see anything
//  the dropped one would have.
//
//  **The Mac has no second writer of the inbox, and that is why nothing here calls
//  `exclusively(_:)`.** The policy's other half — an export taking the inbox to
//  itself, and an activation arriving during one being remembered rather than
//  dropped — exists for the phone, whose `CaptureExportController` reads every
//  record and moves the ones it sent into `inbox/sent/` while a pass is moving
//  records into `inbox/ingested/`. On this host the inbox has exactly one reader,
//  the drain, so `exportsHolding` is 0 for the life of the process and the export
//  guard is a branch that is never taken. That is a no-op by construction and not
//  by an argument passed in: the policy's counter starts at zero and only
//  ``InboxDrainPolicy/exclusively(_:)`` raises it, and this app never calls it.
//  ``InboxDrainEvent/activationDeferredDuringExport`` is handled below all the same,
//  because a `switch` that assumed otherwise would be the kind of assumption that
//  is wrong the day the Mac grows an archive writer.
//
//  The seam is a closure rather than an `InboxDrain`, for the reason the drain's
//  own header gives: `AtelierIngestion` is kept free of a UI-shaped callback, so
//  the coupling lives here, on the app's side of the line — the same shape as
//  ``ClipboardWatcher``'s injected `board`, and testable for the same reason.
//

import AppKit
import AtelierBrowse
import AtelierIngestion
import Combine
import Foundation
import os

/// Decides when the inbox is drained, and what the app does with the result.
///
/// A thin adapter: the cadence is ``InboxDrainPolicy``'s, the activation and the log
/// are this app's. Every property below forwards, so the names `IngestionModel` and
/// `InboxDrainSchedulerTests` were written against are unchanged.
@MainActor
final class InboxDrainScheduler {

    /// The activation the second pass hangs off. Named here so the observer and
    /// the tests that drive it cannot drift onto two different notifications.
    static let activationNotification = NSApplication.didBecomeActiveNotification

    /// The shared cadence. Generic over what a pass returns so `AtelierBrowse` never
    /// has to name `DrainSummary` — see that package's manifest.
    private let policy: InboxDrainPolicy<DrainSummary>

    /// The centre the activation is observed on. Injectable so a test drives its
    /// own and cannot be woken by the real app becoming active around it.
    private let center: NotificationCenter

    /// The activation subscription; also the "already started" flag.
    ///
    /// This — not a `Bool` — is what makes ``start()`` idempotent here, because the
    /// thing that must happen exactly once on this host is the SUBSCRIPTION. A second
    /// one would drain twice per activation for the rest of the app's life, and the
    /// policy's own `hasStarted` guard cannot see it. The two guards are independent
    /// and both are wanted: this one protects the observer, the policy's protects the
    /// launch pass.
    private var activation: AnyCancellable?

    /// The pass in flight, or `nil` when idle. Forwarded from the policy, where it IS
    /// the overlap guard; readable so a test can await the pass it started rather
    /// than sleeping for it.
    var currentPass: Task<Void, Never>? { policy.inFlight }

    /// Whether a pass is running right now.
    var isDraining: Bool { policy.isDraining }

    init(
        center: NotificationCenter = .default,
        pass: @escaping @MainActor () async -> DrainSummary,
        onIngest: @escaping @MainActor () -> Void
    ) {
        self.center = center
        policy = InboxDrainPolicy(
            pass: pass,
            report: { summary in Self.report(summary, onIngest: onIngest) },
            observe: { event in Self.log(event) })
    }

    // MARK: - Cadence

    /// Subscribe to activation and run the launch pass.
    ///
    /// Idempotent: a second call after the first is a no-op rather than a second
    /// subscription, so a re-bootstrap cannot end up draining twice per
    /// activation forever. The subscription is taken BEFORE the launch pass, so a
    /// user who activates the app while that first pass is still running is
    /// covered by the guard rather than by nothing.
    func start() {
        guard activation == nil else { return }
        activation = center.publisher(for: Self.activationNotification)
            .sink { [weak self] _ in
                // `didBecomeActive` is posted on the main thread, which is this
                // class's isolation; a Combine sink is simply not typed that way.
                // Same treatment as `ClipboardWatcher`'s timer block.
                MainActor.assumeIsolated { self?.drain() }
            }
        policy.start()
    }

    /// Run a pass unless one is already running.
    ///
    /// Internal rather than private so a test can drive a pass without posting a
    /// notification — the notification path is itself under test, and a test that
    /// needed it for every case could not tell "the observer is wired" apart from
    /// "draining works".
    func drain() {
        policy.drain()
    }

    // MARK: - The result

    /// The activations that did not become passes.
    ///
    /// Written from outside the cadence since 098 · finding 5, at the same level and
    /// in the same words this file used when it owned the guard: an activation that
    /// did not become a pass is invisible in every other record of what the app did,
    /// and the first question asked of a Mac that "did not import my share" is which
    /// of these two happened. On this host only the first can happen — see the file
    /// header — and the second is spelled anyway rather than defaulted away.
    private static func log(_ event: InboxDrainEvent) {
        switch event {
        case .activationDroppedDuringPass:
            AppLog.capture.debug("inbox drain already running; activation pass skipped")
        case .activationDeferredDuringExport:
            AppLog.capture.debug("inbox held by an export; activation pass deferred")
        }
    }

    /// Log what the pass found, and refresh the library if it changed.
    ///
    /// Nothing here reaches the user directly. An unreadable inbox is a condition
    /// they have no lever for — the container is gone, or unreadable — so it goes
    /// to the log the rest of the capture path already writes to (093 argues
    /// against error UI for exactly this), and the captures are still on disk for
    /// the next pass. A quarantine is louder in consequence and just as
    /// unactionable in the moment, so it is logged too, at the level that says
    /// "someone will want to have seen this".
    ///
    /// **The wording is not decided here any more** (098 · finding 5).
    /// ``DrainSummary/reportLines`` says what a pass is worth saying, in what order
    /// and at which of two levels; this method routes those lines to the Mac's
    /// `Logger` and does the one thing that genuinely is the app's — the refresh.
    /// The phone's scheduler is the same four lines against `MobileLog`. What is
    /// left duplicated is the level mapping, deliberately: `os` is a system
    /// framework no package here imports, and a pre-built `String` handed to
    /// `Logger` also gives up the `privacy:` control every other call site keeps.
    ///
    /// Called once per completed pass, AFTER the policy has released the inbox —
    /// which matters because `onIngest` reloads the visible folder, and holding the
    /// inbox while the UI re-reads would make every grid's query part of the window
    /// in which no other pass may start.
    private static func report(_ summary: DrainSummary, onIngest: @MainActor () -> Void) {
        for line in summary.reportLines {
            switch line.level {
            case .notice: AppLog.capture.notice("\(line.text, privacy: .public)")
            case .error: AppLog.capture.error("\(line.text, privacy: .public)")
            }
        }
        if summary.ingested > 0 { onIngest() }
    }
}
