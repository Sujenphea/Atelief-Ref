//
//  ArchiveExportController.swift
//  AtelierRefs
//
//  008 · H6 — the app-side orchestrator for a library archive: hold the folder
//  access, run the write OFF the main actor, publish progress for the Settings
//  row, and report honestly what came out.
//
//  The `ExportController` / `BackupController` / `RestoreController` shape for
//  the fifth time — same `@Published` progress, same `CancelFlag` (a detached
//  task does NOT inherit cancellation), same "work is detached, state is
//  `@MainActor`" split. Five long-running jobs behaving identically is worth
//  more than any one of them being individually clever.
//
//  Unlike `BackupController`, the outcome is NOT persisted across launches. A
//  backup's last-run date answers "am I protected right now?"; an archive is a
//  one-shot the user just watched finish, and a status line about a folder they
//  may since have moved, renamed or mailed would be worse than none.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

// MARK: - Outcome

nonisolated enum ArchiveOutcome: String, Equatable, Sendable {
    case succeeded
    /// The archive was written, but something it was meant to carry wasn't
    /// there — a blob already gone from disk. Usable, just not whole; saying
    /// "succeeded" would be a lie and "failed" would be worse.
    case incomplete
    case cancelled
    case failed
}

/// What one archive run produced — the record the Settings row reads.
nonisolated struct ArchiveRunSummary: Equatable, Sendable {
    var outcome: ArchiveOutcome
    var finishedAt: Date
    var collections: Int = 0
    var assets: Int = 0
    var files: Int = 0
    var skipped: Int = 0
    /// The archive folder, on any outcome that produced one.
    var url: URL?
    /// Why it failed, in the user's words. `nil` unless something went wrong.
    var message: String?

    static func failure(_ message: String, at date: Date = Date()) -> ArchiveRunSummary {
        ArchiveRunSummary(outcome: .failed, finishedAt: date, message: message)
    }
}

// MARK: - Words

/// The prose for the archive rows, kept free of AppKit and SwiftUI so all of it
/// is directly unit-testable — the `BackupTarget` / `CaptureCopy` split, for the
/// same reason: prose duplicated across surfaces drifts.
nonisolated enum ArchiveCopy {

    /// What the archive actually carries — and what it doesn't.
    ///
    /// The exclusions are named on purpose. Spaces and saved searches are out of
    /// the archive's graph by decision (008 · H6), and Space TEXT elements exist
    /// nowhere but `space_item` — nothing can recompute them. A user who archives,
    /// wipes and re-imports would lose every board with no warning, so the one
    /// place they decide to trust this feature is the place that has to say so.
    /// (Backup and restore are unaffected: they copy the whole database.)
    static let explainer =
        "Writes every collection as a folder of images you can open in Finder, "
        + "beside a manifest.json describing your collections, tags and "
        + "provenance. Spaces and saved searches aren't included — use Backup "
        + "for a complete copy. Nothing is removed from AtelierRefs."

    /// Shown when the chosen destination sits inside the library itself.
    static let insideLibrary =
        "That folder is inside your library, so the archive can't be written "
        + "there. Choose a folder somewhere else."

    /// Shown when every copy failed and no manifest was written.
    static let nothingCopied =
        "None of the images could be copied, so no archive was written. Check "
        + "there's room on the destination and try again."

    static let panelMessage =
        "Choose where to write the archive — a folder of collections plus a "
        + "manifest.json."

    static let noLibrary = "The library isn't open yet."

    static let unknownFailure =
        "The archive couldn't be written. Check there is room on the destination "
        + "and try again."

    /// The folder name the save panel suggests: `Atelier Archive 2026-08-03`.
    /// Dated because an archive is a point-in-time copy, and two of them in one
    /// folder should be tellable apart without opening either.
    static func suggestedName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Atelier Archive \(formatter.string(from: date))"
    }

    /// The line under the button once a run has finished.
    static func statusLine(for summary: ArchiveRunSummary?) -> String? {
        guard let summary else { return nil }
        switch summary.outcome {
        case .cancelled:
            return "Archive stopped — the folder it was writing is incomplete."
        case .failed:
            return nil          // the failure message says it, in orange
        case .succeeded, .incomplete:
            let counted = "Archived \(count(summary.assets, "item")) "
                + "in \(count(summary.collections, "collection"))."
            guard summary.skipped > 0 else { return counted }
            return counted + " \(count(summary.skipped, "file")) couldn't be copied."
        }
    }

    /// `1 item` / `3 items` — the archive never counts anything irregular.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func message(for error: FolderAccessError) -> String {
        switch error {
        case .noFolderChosen: "No archive folder was chosen."
        case .bookmarkUnresolvable: "That folder can't be reached any more."
        case .accessDenied: "AtelierRefs isn't allowed to write there."
        }
    }
}

// MARK: - Controller

@MainActor
final class ArchiveExportController: ObservableObject {

    /// Whether a run is in flight — gates the button and shows the progress row.
    @Published private(set) var isExporting = false

    /// 0…1 across the library's collections (see `LibraryArchiveWriter.fraction`).
    @Published private(set) var progress: Double = 0

    /// The last run this launch. Deliberately not persisted (see the file note).
    @Published private(set) var lastRun: ArchiveRunSummary?

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    // MARK: Running

    /// Archive `services` / `store` into `folder`.
    ///
    /// No-op while one is already running: two writers in the same folder would
    /// race on the name allocators and produce a manifest that disagreed with
    /// the tree.
    func start(
        services: AppServices,
        store: MediaStore,
        folder: any FolderAccess,
        appVersion: String
    ) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0

        let flag = CancelFlag()
        cancelFlag = flag

        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.progress = fraction }
        }

        task = Task { [weak self] in
            let summary = await Self.perform(
                services: services, store: store, folder: folder,
                appVersion: appVersion, flag: flag, onProgress: onProgress)
            await MainActor.run { self?.finish(summary) }
        }
    }

    /// Publish a refusal the caller reached before any work started — a
    /// destination the archive must not be written to.
    ///
    /// Surfaced as a failed run because from the user's side it is one: they
    /// asked for an archive and there isn't one. Ignored mid-run, so a stray
    /// call can't overwrite the outcome of work actually in flight.
    func reject(_ message: String) {
        guard !isExporting else { return }
        progress = 0
        lastRun = .failure(message)
    }

    /// Stop the run. The manifest is written last, so a stopped archive is a
    /// folder with no manifest — visibly incomplete rather than plausibly whole.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    // MARK: The run itself

    /// The whole job, off the main actor. `static` so it captures only
    /// `Sendable` values rather than the controller.
    ///
    /// The folder access is held across the entire run by the ASYNC
    /// `withAccess` — the synchronous one drops the scope at the first `await`,
    /// and every copy after that would fail on a permission the user could do
    /// nothing about (008 · H5b).
    private static func perform(
        services: AppServices,
        store: MediaStore,
        folder: any FolderAccess,
        appVersion: String,
        flag: CancelFlag,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> ArchiveRunSummary {
        do {
            let (root, result) = try await folder.withAccess {
                root -> (URL, LibraryArchiveWriter.Result) in
                let writer = LibraryArchiveWriter(
                    services: services, store: store, appVersion: appVersion)
                let result = try await writer.write(
                    to: root, isCancelled: { flag.isCancelled }, onProgress: onProgress)
                return (root, result)
            }
            return ArchiveRunSummary(
                outcome: result.skipped > 0 ? .incomplete : .succeeded,
                finishedAt: Date(),
                collections: result.collections, assets: result.assets,
                files: result.files, skipped: result.skipped,
                url: root)
        } catch {
            // The FLAG is asked first, never the error (008 · H5b/H5c). Cancelling
            // tears down whatever is in flight — a database read, a copy — and
            // those throws are a CONSEQUENCE of the user pressing Stop. Telling
            // them their archive failed when nothing went wrong is the bug this
            // ordering exists to prevent.
            if flag.isCancelled || error is CancellationError {
                return ArchiveRunSummary(
                    outcome: .cancelled, finishedAt: Date(), url: try? folder.resolve())
            }
            if let error = error as? FolderAccessError {
                return .failure(ArchiveCopy.message(for: error))
            }
            // Nothing landed and nothing was committed — the writer refused to
            // leave a manifest over an empty tree. Named rather than folded into
            // the catch-all, because it has a remedy: free some space.
            if error is ArchiveWriteError {
                return .failure(ArchiveCopy.nothingCopied)
            }
            AppLog.model.error("archive export failed: \(error, privacy: .public)")
            return .failure(ArchiveCopy.unknownFailure)
        }
    }

    private func finish(_ summary: ArchiveRunSummary) {
        isExporting = false
        cancelFlag = nil
        task = nil
        if summary.outcome == .succeeded { progress = 1 }
        lastRun = summary
    }
}
