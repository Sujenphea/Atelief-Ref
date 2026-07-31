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

    private let summaries: BackupSummaryStore
    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    init(summaries: BackupSummaryStore = BackupSummaryStore()) {
        self.summaries = summaries
        self.lastRun = summaries.load()
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

        task = Task { [weak self] in
            let summary = await Self.perform(
                services: services, source: source, libraryRoot: libraryRoot,
                folder: folder, appVersion: appVersion,
                flag: flag, onProgress: onProgress)
            await MainActor.run { self?.finish(summary) }
        }
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
                    isCancelled: { flag.isCancelled }, onProgress: onProgress)
            }
            return summarize(result)
        } catch {
            // The flag is checked FIRST, before the error is classified. ``cancel``
            // tears down the surrounding task as well as setting the flag, so
            // whatever was in flight — a database read, the copy loop — can throw
            // on the way out. Those throws are a CONSEQUENCE of the user pressing
            // Stop, and reporting them as "backup failed" would tell the user
            // something went wrong when nothing did.
            if flag.isCancelled {
                return BackupRunSummary(outcome: .cancelled, finishedAt: Date())
            }
            switch error {
            case let error as FolderAccessError:
                return .failure(BackupTarget.message(for: error))
            case let error as BackupRunner.RunError:
                return .failure(BackupTarget.message(for: error))
            case is LibraryIdentity.IdentityError:
                return .failure(BackupTarget.unidentifiableLibrary)
            default:
                AppLog.model.error("backup run failed: \(error, privacy: .public)")
                return .failure(BackupTarget.unknownRunFailure)
            }
        }
    }

    /// Turn a finished run into the record the user sees.
    private static func summarize(_ result: BackupRunResult) -> BackupRunSummary {
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
            outcome: outcome, finishedAt: Date(),
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
