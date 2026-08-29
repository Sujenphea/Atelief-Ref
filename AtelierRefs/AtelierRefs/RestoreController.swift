//
//  RestoreController.swift
//  AtelierRefs
//
//  008 · H5c — the app-side orchestrator for restoring a library from its backup
//  folder: hold the security scope, run the copy OFF the main actor, publish
//  progress for the Settings section, and hand the result to the ONE shipped
//  restore seam.
//
//  Shaped after `BackupController` (which is itself shaped after
//  `ExportController`) on purpose: same `@Published` progress, same `CancelFlag`,
//  same "the work is a detached task and the state is `@MainActor`" split. Three
//  long-running user-facing jobs behaving identically is worth more than any of
//  them being individually clever.
//
//  What this deliberately does NOT do is install anything. `RestoreRunner` turns
//  the backup's database into an ordinary snapshot; from there it goes through
//  `SnapshotManager.stageRestore` → `.pending-restore` → relaunch →
//  `applyPendingRestore`, the same atomic, rollback-safe path a snapshot restore
//  has used since H3. The controller's last act is to call the caller's
//  `onStaged` with that snapshot.
//
//  The last run is NOT persisted, unlike a backup's. A backup's status answers
//  "is my off-device copy current?", which has to outlive the process. A
//  restore's ends in a relaunch, after which the honest status is the library
//  itself.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

/// A record of the last restore attempt, for the Settings row.
nonisolated struct RestoreRunSummary: Equatable, Sendable {
    /// Reuses ``BackupOutcome``: the question ("can I rely on what just
    /// happened?") and its four honest answers are the same in both directions.
    var outcome: BackupOutcome
    var finishedAt: Date
    /// Blob files this run copied back into the live library.
    var copiedFiles: Int
    var bytesCopied: Int64
    /// Files that couldn't be copied — missing at the backup, or unwritable
    /// locally. The reason an `incomplete` restore is incomplete.
    var unresolvedFiles: Int
    /// The specific thing to do about a failure, from ``BackupTarget``.
    var message: String?

    init(
        outcome: BackupOutcome,
        finishedAt: Date,
        copiedFiles: Int = 0,
        bytesCopied: Int64 = 0,
        unresolvedFiles: Int = 0,
        message: String? = nil
    ) {
        self.outcome = outcome
        self.finishedAt = finishedAt
        self.copiedFiles = copiedFiles
        self.bytesCopied = bytesCopied
        self.unresolvedFiles = unresolvedFiles
        self.message = message
    }

    /// A restore that never got far enough to copy anything.
    static func failure(_ message: String, at date: Date = Date()) -> RestoreRunSummary {
        RestoreRunSummary(outcome: .failed, finishedAt: date, message: message)
    }
}

@MainActor
final class RestoreController: ObservableObject {

    /// Whether a restore is in flight — gates the buttons and shows progress.
    @Published private(set) var isRunning = false

    /// 0…1 across the blob files THIS restore has to copy.
    @Published private(set) var progress: Double = 0

    /// The last attempt, in memory only (see the file header).
    @Published private(set) var lastRun: RestoreRunSummary?

    /// Whether the backup folder is currently being read.
    @Published private(set) var isScanning = false

    /// What the backup folder holds, newest first — empty until ``scan`` runs.
    @Published private(set) var candidates: [BackupSource] = []

    /// Why the folder couldn't be read, in words. `nil` when all is well.
    @Published private(set) var scanMessage: String?

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    // MARK: - Scanning

    /// Read `folder` and publish the backups in it.
    ///
    /// Discovery, not lookup: the library being restored INTO may never have
    /// backed up here (a replacement Mac's library is brand new), so the local
    /// library id says nothing about what is in this folder.
    func scan(folder: any FolderAccess) {
        guard !isScanning, !isRunning else { return }
        isScanning = true
        scanMessage = nil
        Task { [weak self] in
            let outcome = await Self.performScan(folder: folder)
            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                self.candidates = outcome.sources
                self.scanMessage = outcome.message
            }
        }
    }

    private static func performScan(
        folder: any FolderAccess
    ) async -> (sources: [BackupSource], message: String?) {
        do {
            // The SYNC bracket, which is what this has always called: the body is
            // `BackupCatalog.sources(in:)`, which cannot suspend, so overload
            // resolution picks the synchronous `withAccess` and the `await` this
            // line used to carry awaited nothing. The scope-drop hazard the async
            // overload exists for (`FolderAccess.swift:70`) needs a body that
            // actually suspends — the copy loop has one; a directory listing does
            // not. `performScan` stays `async` because its CALLER is, and running
            // it off the main actor is the point.
            let sources = try folder.withAccess { target -> [BackupSource] in
                BackupCatalog.sources(in: target)
            }
            return (sources, sources.isEmpty ? BackupTarget.noBackupsFound : nil)
        } catch let error as FolderAccessError {
            return ([], BackupTarget.message(for: error))
        } catch {
            AppLog.model.error("backup scan failed: \(error, privacy: .public)")
            return ([], BackupTarget.message(for: .bookmarkUnresolvable))
        }
    }

    // MARK: - Running

    /// Copy `source` back into the live library, then hand the snapshot it
    /// produced to `onStaged`.
    ///
    /// No-op while one is already running.
    ///
    /// - Parameter onStaged: called on the main actor with the snapshot the
    ///   backup's database became. The caller stages it through
    ///   `SnapshotManager` — this type never installs anything itself.
    func start(
        source: BackupSource,
        live: MediaStore,
        snapshotsDirectory: URL,
        folder: any FolderAccess,
        onStaged: @escaping @MainActor (URL, BackupSource) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0

        let flag = CancelFlag()
        cancelFlag = flag

        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            guard let self, total > 0 else { return }
            let fraction = Double(completed) / Double(total)
            Task { @MainActor in self.progress = fraction }
        }

        task = Task { [weak self] in
            let outcome = await Self.perform(
                source: source, live: live, snapshotsDirectory: snapshotsDirectory,
                folder: folder, flag: flag, onProgress: onProgress)
            await MainActor.run {
                self?.finish(outcome.summary)
                if let snapshot = outcome.snapshot { onStaged(snapshot, source) }
            }
        }
    }

    /// Stop the restore. Every blob already copied is kept — content-addressed
    /// and complete by construction (A2) — and nothing is staged, so the live
    /// library is untouched and a later attempt resumes.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    // MARK: - The run itself

    /// The whole job, off the main actor. `static` so it captures only
    /// `Sendable` values rather than the controller.
    ///
    /// The security scope is held across the entire run by the ASYNC
    /// `withAccess` — the synchronous one would drop it at the first `await`,
    /// and every copy after that would fail on permissions.
    private static func perform(
        source: BackupSource,
        live: MediaStore,
        snapshotsDirectory: URL,
        folder: any FolderAccess,
        flag: CancelFlag,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> (summary: RestoreRunSummary, snapshot: URL?) {
        do {
            let result = try await folder.withAccess { _ -> RestoreRunResult in
                let runner = RestoreRunner(
                    source: source, live: live, snapshotsDirectory: snapshotsDirectory)
                return try await runner.run(
                    isCancelled: { flag.isCancelled }, onProgress: onProgress)
            }
            return (summarize(result), result.snapshot)
        } catch {
            // The flag is checked FIRST, before the error is classified.
            // ``cancel`` tears down the surrounding task as well as setting the
            // flag, so whatever was in flight can throw on the way out. Those
            // throws are a CONSEQUENCE of the user pressing Stop; reporting them
            // as "restore failed" would say something went wrong when nothing
            // did. (The H5b lesson, and it applies to every long job.)
            if flag.isCancelled {
                return (RestoreRunSummary(outcome: .cancelled, finishedAt: Date()), nil)
            }
            switch error {
            case let error as FolderAccessError:
                return (.failure(BackupTarget.message(for: error)), nil)
            case let error as RestoreRunner.RestoreError:
                return (.failure(BackupTarget.message(for: error)), nil)
            default:
                AppLog.model.error("restore failed: \(error, privacy: .public)")
                return (.failure(BackupTarget.unknownRestoreFailure), nil)
            }
        }
    }

    /// Turn a finished restore into the record the user sees.
    private static func summarize(_ result: RestoreRunResult) -> RestoreRunSummary {
        let unresolved = result.copy.missingAtSource.count + result.copy.failed.count
        let outcome: BackupOutcome
        if result.cancelled {
            outcome = .cancelled
        } else if unresolved > 0 {
            // The database IS staged — the restore will happen — but some media
            // didn't come back. Neither a failure nor a clean success, and
            // saying either would be a lie.
            outcome = .incomplete
        } else {
            outcome = .succeeded
        }
        return RestoreRunSummary(
            outcome: outcome, finishedAt: Date(),
            copiedFiles: result.copy.copied, bytesCopied: result.copy.bytesCopied,
            unresolvedFiles: unresolved)
    }

    private func finish(_ summary: RestoreRunSummary) {
        isRunning = false
        cancelFlag = nil
        task = nil
        if summary.outcome == .succeeded { progress = 1 }
        lastRun = summary
    }
}
