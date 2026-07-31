//
//  BackupRunSummary.swift
//  AtelierRefs
//
//  008 · H5 — what the last backup run did, in a form that survives quitting the
//  app. The Settings window is where a user checks whether their backup is
//  current, and the honest answer to "when did this last run?" has to outlive
//  the process that ran it — otherwise every launch reports "never", which reads
//  as "your backup is not working".
//
//  A value type with its words in ``BackupTarget``, following the split H4
//  established: rules and prose in testable, AppKit-free code; layout in the
//  view.
//

import Foundation

/// The outcome of one backup run, as the user needs to understand it.
///
/// Note what is NOT here: a distinction between "failed to copy the database"
/// and "failed to write the manifest". The *message* carries that; the outcome
/// only has to answer "can I rely on this backup?", and the answer has three
/// shapes, not eight.
nonisolated enum BackupOutcome: String, Codable, Sendable, CaseIterable {
    /// Everything the library references is at the destination.
    case succeeded
    /// The run finished and the backup is usable, but something is missing —
    /// blobs whose files were gone, or files that wouldn't copy.
    case incomplete
    /// The user stopped it. What copied is kept; the next run resumes.
    case cancelled
    /// The run couldn't produce a complete backup. The previous one is intact.
    case failed
}

/// A record of the last run, persisted so Settings can answer "is my backup
/// current?" after a relaunch.
nonisolated struct BackupRunSummary: Codable, Equatable, Sendable {
    var outcome: BackupOutcome
    /// When the run ended.
    var finishedAt: Date
    /// Files this run copied.
    var copiedFiles: Int
    /// Bytes this run copied.
    var bytesCopied: Int64
    /// Files the run could not copy (missing at source, or a write failure) —
    /// the reason an `incomplete` run is incomplete.
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
}

/// Reads and writes the last-run summary in `UserDefaults`.
///
/// Its own type rather than two lines inline, so the decode failure has one
/// home: a summary written by a FUTURE build (a new `BackupOutcome` case) must
/// read back as "no record", not crash and not resurrect a stale one. A missing
/// status line is a small lie; a wrong one is a big one.
/// `@unchecked Sendable` for the same reason ``StoredFolderAccess`` is: the
/// defaults object is thread-safe, and the stored property is immutable.
nonisolated struct BackupSummaryStore: @unchecked Sendable {
    /// Alongside `AtelierBackupFolderBookmark` (F2) — same ad-hoc `Atelier…`
    /// convention.
    static let key = "AtelierBackupLastRun"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BackupRunSummary? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(BackupRunSummary.self, from: data)
    }

    func save(_ summary: BackupRunSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Forget the record — used when the target is cleared, because a status
    /// line about a folder the app no longer has is worse than none.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
