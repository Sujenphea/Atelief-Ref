//
//  InboxDrainScheduler.swift
//  AtelierRefs
//
//  092 · S3 — the CADENCE half of the iOS handoff. `InboxDrain.drainOnce()` runs
//  the inbox as it stands and returns what happened; it starts nothing, schedules
//  nothing, and holds no state between calls, precisely so that the decision of
//  WHEN to run belongs to the app. Until this file existed, nobody made it: the
//  writer, the layout, the drain and their tests were all built and proven, and
//  `drainOnce()` had no caller anywhere in the app. A share sent from the phone
//  landed in `inbox/` and stayed there.
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
//  **One pass at a time.** Activation can fire while a pass is still running —
//  ⌘-Tab away and back, a second window raised, a Finder drop that activates the
//  app — and two concurrent passes over one directory would race each other's
//  deletes: both enumerate the same record, both decode it, both hand it to the
//  coordinator, and the second `removeItem` fails on a file the first already
//  unlinked. 18A dedup means the outcome is not a duplicate ASSET, but it is
//  duplicated decode work and a summary that double-counts. So a pass is held in
//  ``currentPass`` and an activation that finds one there is dropped, not queued:
//  the drain re-enumerates the directory from scratch every time, so a pass that
//  is already running will see anything the dropped one would have. The guard
//  works because this type is `@MainActor` — the read of `currentPass` and the
//  write that claims it are one synchronous step with no suspension between them,
//  so there is no window for a second activation to slip through.
//
//  The seam is a closure rather than an `InboxDrain`, for the reason the drain's
//  own header gives: `AtelierIngestion` is kept free of a UI-shaped callback, so
//  the coupling lives here, on the app's side of the line — the same shape as
//  ``ClipboardWatcher``'s injected `board`, and testable for the same reason.
//

import AppKit
import AtelierIngestion
import Combine
import Foundation
import os

/// Decides when the inbox is drained, and what the app does with the result.
@MainActor
final class InboxDrainScheduler {

    /// The activation the second pass hangs off. Named here so the observer and
    /// the tests that drive it cannot drift onto two different notifications.
    static let activationNotification = NSApplication.didBecomeActiveNotification

    /// One pass over the inbox. Injected so the schedule is testable without a
    /// library on disk, and so this file never has to know what a record is.
    private let pass: @MainActor () async -> DrainSummary

    /// Called after a pass that ingested at least one capture — nothing else is
    /// worth a redraw. Records that were skipped as incomplete, quarantined, or
    /// left for a retry changed nothing the grid shows.
    private let onIngest: @MainActor () -> Void

    /// The centre the activation is observed on. Injectable so a test drives its
    /// own and cannot be woken by the real app becoming active around it.
    private let center: NotificationCenter

    /// The activation subscription; also the "already started" flag.
    private var activation: AnyCancellable?

    /// The pass in flight, or `nil` when idle. This IS the overlap guard (see the
    /// file header); `private(set)` so a test can await the pass it started
    /// rather than sleeping for it.
    private(set) var currentPass: Task<Void, Never>?

    /// Whether a pass is running right now.
    var isDraining: Bool { currentPass != nil }

    init(
        center: NotificationCenter = .default,
        pass: @escaping @MainActor () async -> DrainSummary,
        onIngest: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.pass = pass
        self.onIngest = onIngest
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
        drain()
    }

    /// Run a pass unless one is already running.
    ///
    /// Internal rather than private so a test can drive a pass without posting a
    /// notification — the notification path is itself under test, and a test that
    /// needed it for every case could not tell "the observer is wired" apart from
    /// "draining works".
    func drain() {
        guard currentPass == nil else {
            AppLog.capture.debug("inbox drain already running; activation pass skipped")
            return
        }
        currentPass = Task { [weak self] in
            guard let self else { return }
            let summary = await pass()
            currentPass = nil
            report(summary)
        }
    }

    // MARK: - The result

    /// Log what the pass found, and refresh the library if it changed.
    ///
    /// Nothing here reaches the user directly. An unreadable inbox is a condition
    /// they have no lever for — the container is gone, or unreadable — so it goes
    /// to the log the rest of the capture path already writes to (093 argues
    /// against error UI for exactly this), and the captures are still on disk for
    /// the next pass. A quarantine is louder in consequence and just as
    /// unactionable in the moment, so it is logged too, at the level that says
    /// "someone will want to have seen this".
    private func report(_ summary: DrainSummary) {
        if summary.inboxUnreadable {
            AppLog.capture.error("inbox could not be enumerated; captures left in place")
        }
        if summary.quarantined > 0 {
            AppLog.capture.error(
                "\(summary.quarantined) capture(s) moved to inbox/failed/")
        }
        if summary.ingested > 0 || summary.retrying > 0 || summary.skippedIncomplete > 0 {
            AppLog.capture.notice(
                """
                inbox drain: \(summary.ingested) ingested, \
                \(summary.retrying) retrying, \
                \(summary.skippedIncomplete) incomplete
                """)
        }
        if summary.ingested > 0 { onIngest() }
    }
}
