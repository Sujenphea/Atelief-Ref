//
//  BackupVerifyController.swift
//  AtelierRefs
//
//  008 · H5d — the app-side orchestrator for re-hashing what actually landed at
//  the backup destination: hold the security scope, run the check OFF the main
//  actor, publish progress, and report what it found.
//
//  The `BackupController` shape for the fifth time (`ExportController` → backup →
//  restore → this): `@Published progress`, a `CancelFlag`, the work in a task
//  and the state on `@MainActor`, and the cancel flag read BEFORE any error is
//  classified. Cancelling tears down in-flight reads, which throw; calling that
//  "verification failed" would tell a user their backup is suspect when all they
//  did was press Stop — and for a verifier specifically, a false alarm is the
//  worst possible output.
//
//  Its own controller rather than a mode of `BackupController`, for the reason
//  restore got one: the two jobs are mutually exclusive (the model's
//  `canVerifyBackup` / `canRunBackup` enforce that) but they answer different
//  questions, and a single `isRunning` covering both would leave the Settings
//  section unable to say which one is running.
//
//  The last result is NOT persisted, unlike a backup run's. A backup's status
//  answers "is my off-device copy current?", which is a fact about a past event
//  and has to outlive the process. A verification answers "are those bytes still
//  intact?", which is a claim about the destination RIGHT NOW — and the
//  destination is a folder on someone else's drive or in someone else's cloud,
//  changing while this app isn't looking. A week-old "it was fine" is a weaker
//  statement than no claim at all, and it would be read as a stronger one.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

/// A record of the last verification, for the Settings row.
nonisolated struct BackupVerifySummary: Equatable, Sendable {
    /// Reuses ``BackupOutcome``, as restore does: `succeeded` is a clean check,
    /// `incomplete` is a check that ran and found something, `cancelled` is a
    /// stop, `failed` is a check that couldn't run at all. The distinction
    /// between the middle two matters more here than anywhere else — "we found
    /// damage" and "we couldn't look" are opposite messages.
    var outcome: BackupOutcome
    var finishedAt: Date
    /// What the pass measured. `nil` when it never got to measure anything.
    var result: BackupVerifyResult?
    /// The specific thing to do about a failure, from ``BackupTarget``.
    var message: String?

    init(
        outcome: BackupOutcome,
        finishedAt: Date,
        result: BackupVerifyResult? = nil,
        message: String? = nil
    ) {
        self.outcome = outcome
        self.finishedAt = finishedAt
        self.result = result
        self.message = message
    }

    /// A check that never got far enough to look at anything.
    static func failure(_ message: String, at date: Date = Date()) -> BackupVerifySummary {
        BackupVerifySummary(outcome: .failed, finishedAt: date, message: message)
    }
}

@MainActor
final class BackupVerifyController: ObservableObject {

    /// Whether a check is in flight — gates the buttons and shows progress.
    @Published private(set) var isRunning = false

    /// 0…1 across the files THIS check re-hashes — the sample, not the library.
    @Published private(set) var progress: Double = 0

    /// Whether the check in flight is the exhaustive one, so the progress row
    /// can say which cost is being paid.
    @Published private(set) var isExhaustive = false

    /// The last attempt, in memory only (see the file header).
    @Published private(set) var lastRun: BackupVerifySummary?

    private let now: @Sendable () -> Date
    /// Rotates the sampled selection between runs. Injected so a test can pin
    /// exactly which files a check looks at — the sample is deterministic given
    /// a seed, and a seed taken from the wall clock would throw that away at the
    /// last moment.
    private let seed: @Sendable () -> UInt64
    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        seed: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) {
        self.now = now
        self.seed = seed
    }

    // MARK: - Running

    /// Re-hash the backup of the library at `libraryRoot` inside `folder`.
    ///
    /// - Parameter exhaustive: `false` re-hashes a capped sample — the routine
    ///   check. `true` re-hashes every blob, which on a synced destination
    ///   downloads the entire backup, and is therefore only ever reached from
    ///   its own button. It is never folded into a backup run.
    func start(
        libraryRoot: URL,
        folder: any FolderAccess,
        exhaustive: Bool = false
    ) {
        guard !isRunning else { return }
        isRunning = true
        isExhaustive = exhaustive
        progress = 0

        let flag = CancelFlag()
        cancelFlag = flag

        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            guard let self, total > 0 else { return }
            let fraction = Double(completed) / Double(total)
            Task { @MainActor in self.progress = fraction }
        }

        let scope: BackupVerifier.Scope = exhaustive ? .full : .sample(seed: seed())
        let clock = now
        task = Task { [weak self] in
            let summary = await Self.perform(
                libraryRoot: libraryRoot, folder: folder, scope: scope,
                flag: flag, now: clock, onProgress: onProgress)
            await MainActor.run { self?.finish(summary) }
        }
    }

    /// Stop the check. Nothing is left behind: verification writes nothing,
    /// moves nothing, and deletes nothing, so a stop costs only the answer.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    /// Forget the last result — called when the target is cleared, since a
    /// verdict about a folder the app no longer has is worse than none.
    func forgetLastRun() {
        lastRun = nil
    }

    // MARK: - The check itself

    /// The whole job, off the main actor. `static` so it captures only
    /// `Sendable` values rather than the controller.
    ///
    /// The security scope is held across the entire check by the ASYNC
    /// `withAccess`: re-hashing thousands of files suspends constantly, and the
    /// synchronous bracket would drop the scope at the first `await` — after
    /// which every read fails and the verifier reports the user's intact backup
    /// as unreadable.
    private static func perform(
        libraryRoot: URL,
        folder: any FolderAccess,
        scope: BackupVerifier.Scope,
        flag: CancelFlag,
        now: @escaping @Sendable () -> Date,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> BackupVerifySummary {
        do {
            let result = try await folder.withAccess { target -> BackupVerifyResult in
                let libraryID = try LibraryIdentity.resolve(root: libraryRoot)
                let layout = BackupLayout(target: target, libraryID: libraryID)
                return try await BackupVerifier(layout: layout).verify(
                    scope: scope, isCancelled: { flag.isCancelled }, onProgress: onProgress)
            }
            return summarize(result, at: now())
        } catch {
            // The flag FIRST, before the error is classified — the lesson H5b
            // and H5c both paid for, and the one it matters most in: a teardown
            // exception reported as a verification failure reads as "your backup
            // is damaged", which is a lie that costs the user a whole re-copy.
            if flag.isCancelled {
                return BackupVerifySummary(outcome: .cancelled, finishedAt: now())
            }
            switch error {
            case let error as FolderAccessError:
                return .failure(BackupTarget.message(for: error), at: now())
            case let error as BackupVerifier.VerifyError:
                return .failure(BackupTarget.message(for: error), at: now())
            case is LibraryIdentity.IdentityError:
                return .failure(BackupTarget.unidentifiableLibrary, at: now())
            default:
                AppLog.model.error("backup verify failed: \(error, privacy: .public)")
                return .failure(BackupTarget.unknownVerifyFailure, at: now())
            }
        }
    }

    /// Turn a finished check into the verdict the user sees.
    private static func summarize(
        _ result: BackupVerifyResult, at date: Date
    ) -> BackupVerifySummary {
        let outcome: BackupOutcome
        if result.cancelled {
            outcome = .cancelled
        } else if result.isClean {
            outcome = .succeeded
        } else {
            // The check RAN — it just didn't like what it saw. That is not a
            // failure of the check, and calling it one would point the user at
            // the app instead of at their backup.
            outcome = .incomplete
        }
        return BackupVerifySummary(outcome: outcome, finishedAt: date, result: result)
    }

    private func finish(_ summary: BackupVerifySummary) {
        isRunning = false
        cancelFlag = nil
        task = nil
        if summary.outcome == .succeeded { progress = 1 }
        lastRun = summary
    }
}
