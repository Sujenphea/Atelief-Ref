//
//  BackupController.swift
//  AtelierRefs
//
//  008 · H5 — the app-side orchestrator for an off-device backup run: hold the
//  security scope, run the copy OFF the main actor, publish progress for the
//  Settings section, and record what happened so the next launch can say when
//  the backup last ran.
//
//  Shaped after `ExportController` (052 · B3), deliberately: same `@Published`
//  progress, same `CancelFlag`, same "the work is a detached task and the state
//  is `@MainActor`" split. Two long-running user-facing jobs behaving the same
//  way is worth more than either one being individually clever.
//
//  Lives here rather than as `@State` on `SettingsView` because that window can
//  be closed and reopened mid-run, and view state would go with it — showing a
//  fresh "Back Up Now" over a copy that is still running (see 068 H4's state
//  placement note).
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

@MainActor
final class BackupController: ObservableObject {

    /// Whether a run is in flight — gates the button and shows the progress row.
    @Published private(set) var isRunning = false

    /// 0…1 across the files THIS run has to copy. An incremental run's progress
    /// covers the diff, not the library, so it reflects the work left.
    @Published private(set) var progress: Double = 0

    /// The last run, loaded from disk at init so it survives a relaunch.
    @Published private(set) var lastRun: BackupRunSummary?

    /// How often a backup runs by itself (008 · H5d). Reads as the default until
    /// ``activate(libraryID:)`` binds it to the open library, since the
    /// preference is per-library and there is no library yet at init.
    @Published private(set) var cadence: BackupCadence = .default

    /// The library the cadence preference belongs to; `nil` until the library
    /// opens. Also the gate on persisting a change — a cadence saved under no
    /// library id would be a preference nothing ever reads back.
    @Published private(set) var libraryID: String?

    private let summaries: BackupSummaryStore
    private let cadences: BackupCadenceStore
    /// The clock — injected the way ``SnapshotManager``'s is, so the staleness
    /// boundary is a decision about a `Date` rather than about wall-clock time.
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    init(
        summaries: BackupSummaryStore = BackupSummaryStore(),
        cadences: BackupCadenceStore = BackupCadenceStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.summaries = summaries
        self.cadences = cadences
        self.now = now
        self.lastRun = summaries.load()
    }

    // MARK: - Cadence (008 H5d)

    /// Bind to the open library and resume its stored cadence.
    ///
    /// Called once from `IngestionModel.bootstrap()`, the same way
    /// `ClipboardWatcher.activate(libraryID:)` is. Until it runs the automatic
    /// path is inert — not because the cadence is unknown (it has a default) but
    /// because there is no library to back up.
    func activate(libraryID: String) {
        guard self.libraryID == nil else { return }
        self.libraryID = libraryID
        cadence = cadences.load(libraryID: libraryID)
    }

    /// Change the cadence, persisting it for this library.
    func setCadence(_ cadence: BackupCadence) {
        self.cadence = cadence
        guard let libraryID else { return }
        cadences.save(cadence, libraryID: libraryID)
    }

    // MARK: - Running

    /// Start a backup of `services` / `source` into `folder`.
    ///
    /// No-op while one is already running: the destination's atomic installs
    /// would survive two concurrent runs, but the progress bar wouldn't mean
    /// anything, and a second run does no useful work the first isn't doing.
    ///
    /// - Parameter libraryRoot: needed for ``LibraryIdentity``, which names the
    ///   subdirectory inside the chosen folder.
    func start(
        services: AppServices,
        source: MediaStore,
        libraryRoot: URL,
        folder: any FolderAccess,
        appVersion: String
    ) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0

        let flag = CancelFlag()
        cancelFlag = flag

        // Progress arrives from the copy's concurrent tasks; hop each one back
        // to the main actor for the published value.
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            guard let self, total > 0 else { return }
            let fraction = Double(completed) / Double(total)
            Task { @MainActor in self.progress = fraction }
        }

        let clock = now
        task = Task { [weak self] in
            let summary = await Self.perform(
                services: services, source: source, libraryRoot: libraryRoot,
                folder: folder, appVersion: appVersion,
                flag: flag, now: clock, onProgress: onProgress)
            await MainActor.run { self?.finish(summary) }
        }
    }

    // MARK: - The on-launch cadence (008 H5d)

    /// Run a backup if the cadence says one is overdue, and wait for it.
    ///
    /// The H3 daily-snapshot shape (`SnapshotManager.snapshotIfStale`), with the
    /// same two rules: it is called from a background task AFTER the library has
    /// loaded, never on the bootstrap critical path, and it is best-effort — a
    /// backup must never be the reason a launch is slow or a window is late.
    ///
    /// Four separate refusals, each for its own reason:
    ///
    /// - **Manual cadence.** The user said "when I say so".
    /// - **A pending restore.** The same guard "Back Up Now" already carries
    ///   (H5c): the library is one relaunch away from being replaced by the
    ///   backup, and copying the current library over that backup now would
    ///   destroy the recovery point on the way to using it. Automatic is the
    ///   *more* dangerous path here, because nobody pressed anything.
    /// - **A bookmark that doesn't resolve.** An unplugged drive is the normal
    ///   state of an external backup disk, not a fault, so this returns silently
    ///   rather than recording a failed run. A "Last backup failed" line every
    ///   launch would train the user to ignore the one time it means something.
    /// - **A recent good run.** The staleness test itself.
    ///
    /// - Returns: whether a run was actually started (and awaited).
    @discardableResult
    func backUpIfStale(
        services: AppServices,
        source: MediaStore,
        libraryRoot: URL,
        folder: any FolderAccess,
        appVersion: String,
        restorePending: Bool
    ) async -> Bool {
        guard let maxAge = cadence.maxAge, !restorePending, !isRunning else { return false }
        guard Self.isStale(lastRun: lastRun, maxAge: maxAge, now: now()) else { return false }
        // Resolving is cheap and grants nothing; it is only asked so an absent
        // volume can be skipped instead of reported.
        guard (try? folder.resolve()) != nil else { return false }

        start(
            services: services, source: source, libraryRoot: libraryRoot,
            folder: folder, appVersion: appVersion)
        // Awaiting keeps the caller's `Task` alive for the run's duration, so a
        // launch-time backup is one traceable unit of work rather than a
        // fire-and-forget the app can't reason about. `start` has already hopped
        // the work off the main actor.
        if let task { await task.value }
        return true
    }

    /// Whether a backup is overdue, judged only against a run that LANDED.
    ///
    /// A failed or cancelled run leaves the destination exactly as stale as it
    /// was, so treating either as a fresh backup would mean one unplugged drive
    /// (or one press of Stop) buying a whole cadence period of silence — the
    /// backup would go a week out of date and the status line would say so in
    /// small grey text nobody reads. Both therefore read as "never", and the
    /// next launch tries again.
    ///
    /// An **incomplete** run does reset the clock. It finished, it installed a
    /// verified database, and the destination is usable; what it could not copy
    /// was a blob whose file is missing at the *source*, which no amount of
    /// re-running will conjure back. Counting it as stale would pin the library
    /// into a full backup attempt on every single launch, forever, over a fault
    /// the status line is already reporting in its own words.
    static func isStale(lastRun: BackupRunSummary?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let lastRun,
              lastRun.outcome == .succeeded || lastRun.outcome == .incomplete
        else { return true }
        return now.timeIntervalSince(lastRun.finishedAt) >= maxAge
    }

    /// Stop the run. What has already copied is kept and the next run resumes
    /// from it — every copied file is complete by construction (A2).
    ///
    /// Both signals are sent on purpose. The flag is what the copy loop reads
    /// per file; cancelling the task additionally stops `runBounded` from
    /// launching the remaining thousands of no-op items, so a stop during a
    /// large run is immediate rather than merely eventual. ``perform`` knows to
    /// read the flag before classifying anything the teardown throws.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    /// Forget the recorded last run — called when the target is cleared, since a
    /// status line about a folder the app no longer has is worse than none.
    func forgetLastRun() {
        summaries.clear()
        lastRun = nil
    }

    // MARK: - The run itself

    /// The whole job, off the main actor. `static` so it captures only
    /// `Sendable` values rather than the controller.
    ///
    /// The security scope is held across the entire run by the ASYNC
    /// `withAccess` — the synchronous one would drop it at the first `await`,
    /// and every copy after that would fail on permissions.
    private static func perform(
        services: AppServices,
        source: MediaStore,
        libraryRoot: URL,
        folder: any FolderAccess,
        appVersion: String,
        flag: CancelFlag,
        now: @escaping @Sendable () -> Date,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> BackupRunSummary {
        do {
            let result = try await folder.withAccess { target -> BackupRunResult in
                let libraryID = try LibraryIdentity.resolve(root: libraryRoot)
                let layout = BackupLayout(target: target, libraryID: libraryID)
                let runner = BackupRunner(
                    services: services, source: source,
                    layout: layout, appVersion: appVersion)
                return try await runner.run(
                    isCancelled: { flag.isCancelled }, onProgress: onProgress, now: now())
            }
            return summarize(result, at: now())
        } catch {
            // The flag is checked FIRST, before the error is classified. ``cancel``
            // tears down the surrounding task as well as setting the flag, so
            // whatever was in flight — a database read, the copy loop — can throw
            // on the way out. Those throws are a CONSEQUENCE of the user pressing
            // Stop, and reporting them as "backup failed" would tell the user
            // something went wrong when nothing did.
            if flag.isCancelled {
                return BackupRunSummary(outcome: .cancelled, finishedAt: now())
            }
            switch error {
            case let error as FolderAccessError:
                return .failure(BackupTarget.message(for: error), at: now())
            case let error as BackupRunner.RunError:
                return .failure(BackupTarget.message(for: error), at: now())
            case is LibraryIdentity.IdentityError:
                return .failure(BackupTarget.unidentifiableLibrary, at: now())
            default:
                AppLog.model.error("backup run failed: \(error, privacy: .public)")
                return .failure(BackupTarget.unknownRunFailure, at: now())
            }
        }
    }

    /// Turn a finished run into the record the user sees.
    private static func summarize(_ result: BackupRunResult, at date: Date) -> BackupRunSummary {
        let unresolved = result.copy.missingAtSource.count + result.copy.failed.count
        let outcome: BackupOutcome
        if result.cancelled {
            outcome = .cancelled
        } else if unresolved > 0 {
            // The run finished and the destination is usable — it just isn't
            // whole. That is NOT a failure (the previous state was worse) and
            // not a success (saying so would be a lie).
            outcome = .incomplete
        } else {
            outcome = .succeeded
        }
        return BackupRunSummary(
            outcome: outcome, finishedAt: date,
            copiedFiles: result.copy.copied, bytesCopied: result.copy.bytesCopied,
            unresolvedFiles: unresolved)
    }

    private func finish(_ summary: BackupRunSummary) {
        isRunning = false
        cancelFlag = nil
        task = nil
        if summary.outcome == .succeeded { progress = 1 }
        lastRun = summary
        summaries.save(summary)
    }
}

extension BackupRunSummary {
    /// A run that never got far enough to copy anything.
    static func failure(_ message: String, at date: Date = Date()) -> BackupRunSummary {
        BackupRunSummary(outcome: .failed, finishedAt: date, message: message)
    }
}
