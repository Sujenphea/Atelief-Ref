//
//  ArchiveImportController.swift
//  AtelierRefs
//
//  008 · H7 — the app-side orchestrator for reading a library archive back in:
//  hold the folder access, parse OFF the main actor, take the pre-destructive
//  snapshot, replay, and report honestly what came out.
//
//  The `ExportController` / `BackupController` / `RestoreController` /
//  `ArchiveExportController` shape for the sixth time — same `@Published`
//  progress, same `CancelFlag` (a detached task does NOT inherit cancellation),
//  same "work is detached, state is `@MainActor`" split.
//
//  Two orderings this file is responsible for, both of which cost somebody an
//  afternoon the first time:
//
//  • **Parse, THEN snapshot, THEN write.** A refused or unreadable archive must
//    cost nothing — no snapshot, no rows, no half-applied contract. Only once
//    the plans exist does the pre-destructive snapshot go in, and only then does
//    the first `createCollection` run.
//  • **Ask the cancel flag BEFORE classifying any error** (008 · H5b/H5c/H6).
//    Cancelling tears down in-flight work; telling the user their import failed
//    when they stopped it themselves is the bug this ordering prevents.
//

import AtelierArchive
import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

// MARK: - Outcome

nonisolated enum ImportOutcome: String, Equatable, Sendable {
    case succeeded
    /// Everything that could be imported was, but something the archive named
    /// wasn't usable — a missing file, a writer that refused a row. Saying
    /// "succeeded" would be a lie; "failed" would be a bigger one.
    case incomplete
    /// The archive's contract is newer than this build. NOTHING was applied.
    case refused
    case cancelled
    case failed
}

/// What one import run produced — the record the Settings row reads.
nonisolated struct ImportRunSummary: Equatable, Sendable {
    var outcome: ImportOutcome
    var finishedAt: Date
    /// The destination collection, as created.
    var destinationName: String = ""
    var collections: Int = 0
    var assets: Int = 0
    /// Assets newly created; `assets - newAssets` were matched by 18A dedup to
    /// media this library already held.
    var newAssets: Int = 0
    var memberships: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    /// Files in the archive folder no membership referred to.
    var unreferenced: Int = 0
    /// Why it refused or failed, in the user's words. `nil` when nothing did.
    var message: String?

    static func failure(_ message: String, at date: Date = Date()) -> ImportRunSummary {
        ImportRunSummary(outcome: .failed, finishedAt: date, message: message)
    }

    static func refusal(_ message: String, at date: Date = Date()) -> ImportRunSummary {
        ImportRunSummary(outcome: .refused, finishedAt: date, message: message)
    }
}

// MARK: - Words

/// The prose for the import row, AppKit- and SwiftUI-free so all of it is
/// directly unit-testable — the same split `ArchiveCopy` and `BackupTarget` use,
/// for the same reason: prose duplicated across surfaces drifts.
nonisolated enum ArchiveImportCopy {

    static let explainer =
        "Reads an archive folder back in as a new collection named after it. "
        + "Nothing already in your library is changed or replaced."

    static let panelMessage =
        "Choose an archive folder — the one holding manifest.json."

    static let panelPrompt = "Import"

    static let unknownFailure =
        "The archive couldn’t be imported. Check the folder is readable and "
        + "try again."

    /// The line under the button once a run has finished.
    static func statusLine(for summary: ImportRunSummary?) -> String? {
        guard let summary else { return nil }
        switch summary.outcome {
        case .cancelled:
            return "Import stopped — what had already been imported was kept."
        case .refused, .failed:
            return nil          // the message says it, in orange
        case .succeeded, .incomplete:
            var line = "Imported \(count(summary.assets, "item")) "
                + "in \(count(summary.collections, "collection")) "
                + "into “\(summary.destinationName)”."
            if summary.assets > summary.newAssets {
                line += " \(summary.assets - summary.newAssets) already in your library."
            }
            if summary.skipped > 0 {
                line += " \(count(summary.skipped, "item")) couldn’t be read."
            }
            if summary.failed > 0 {
                line += " \(count(summary.failed, "item")) couldn’t be added."
            }
            return line
        }
    }

    /// `1 item` / `3 items` — the importer never counts anything irregular.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// Why this build won't read the archive. Both cases say the same true
    /// thing — it came from a newer AtelierRefs — but name the axis, because
    /// "my library is older than the file" and "the file's format is newer" are
    /// different things to search for.
    static func message(for refusal: ArchiveRefusal) -> String {
        switch refusal {
        case let .manifestTooNew(version):
            "This archive was written by a newer version of AtelierRefs "
                + "(manifest version \(version)). Update AtelierRefs, then import it. "
                + "Nothing was changed."
        case let .schemaTooNew(version):
            "This archive came from a newer library (schema \(version)). "
                + "Update AtelierRefs, then import it. Nothing was changed."
        }
    }

    static func message(for error: ArchiveReadError) -> String {
        switch error {
        case .missingManifest:
            "That folder has no manifest.json, so it isn’t a finished archive — "
                + "an export that was stopped part-way leaves it out."
        case .unreadableManifest:
            "That archive’s manifest.json couldn’t be read. Nothing was imported."
        case let .refused(refusal):
            message(for: refusal)
        }
    }

    static func message(for error: FolderAccessError) -> String {
        switch error {
        case .noFolderChosen: "No archive folder was chosen."
        case .bookmarkUnresolvable: "That folder can’t be reached any more."
        case .accessDenied: "AtelierRefs isn’t allowed to read there."
        }
    }
}

// MARK: - Controller

@MainActor
final class ArchiveImportController: ObservableObject {

    /// Whether a run is in flight — gates the button and shows the progress row.
    @Published private(set) var isImporting = false

    /// 0…1 across the archive's collections.
    @Published private(set) var progress: Double = 0

    /// The last run this launch. Deliberately not persisted, matching
    /// ``ArchiveExportController``: an import is a one-shot the user just
    /// watched finish.
    @Published private(set) var lastRun: ImportRunSummary?

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    // MARK: Running

    /// Import the archive in `folder` into `services` / `store`.
    ///
    /// `snapshot` is the pre-destructive net, run AFTER the archive parses and
    /// BEFORE the first row is written. It is injected rather than reached for
    /// so that ordering is a testable fact rather than a comment, and so a
    /// refused archive demonstrably costs nothing.
    ///
    /// `onFinished` fires on the main actor once the run is over, whatever the
    /// outcome — the sidebar has to reload even after a cancel, because a
    /// cancelled import keeps what it already wrote.
    func start(
        services: AppServices,
        store: MediaStore,
        folder: any FolderAccess,
        snapshot: @escaping @Sendable () async -> Void = {},
        onFinished: (() -> Void)? = nil
    ) {
        guard !isImporting else { return }
        isImporting = true
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
                snapshot: snapshot, flag: flag, onProgress: onProgress)
            await MainActor.run {
                self?.finish(summary)
                onFinished?()
            }
        }
    }

    /// Stop the run. What has already been written stays: every row went in
    /// through the funnel, so a stopped import leaves a smaller — not a
    /// broken — collection.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    // MARK: The run itself

    /// The whole job, off the main actor. `static` so it captures only
    /// `Sendable` values rather than the controller.
    ///
    /// The folder access is held across the entire run by the ASYNC `withAccess`
    /// — the synchronous one drops the scope at the first `await`, and every
    /// read after that would fail on a permission the user could do nothing
    /// about (008 · H5b).
    static func perform(
        services: AppServices,
        store: MediaStore,
        folder: any FolderAccess,
        snapshot: @escaping @Sendable () async -> Void,
        flag: CancelFlag,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> ImportRunSummary {
        do {
            return try await folder.withAccess { root -> ImportRunSummary in
                let parse = try LibraryArchiveReader.parse(root)
                if flag.isCancelled { throw CancellationError() }

                // The net goes in HERE: after the archive proved readable, before
                // the first write. `snapshotBeforeDestruction` is freshness-gated,
                // so this is cheap and usually a no-op.
                await snapshot()

                let importer = LibraryImporter(services: services, store: store)
                let report = try await importer.replay(
                    parse.plans, into: parse.name,
                    isCancelled: { flag.isCancelled }, onProgress: onProgress)

                return summary(for: report, parse: parse)
            }
        } catch {
            // The FLAG first, never the error (008 · H5b/H5c/H6).
            if flag.isCancelled || error is CancellationError {
                return ImportRunSummary(outcome: .cancelled, finishedAt: Date())
            }
            if let error = error as? ArchiveReadError {
                let message = ArchiveImportCopy.message(for: error)
                // A version refusal is not a failure: nothing broke, this build
                // simply declined to guess at a contract it doesn't know.
                if case .refused = error { return .refusal(message) }
                return .failure(message)
            }
            if let error = error as? FolderAccessError {
                return .failure(ArchiveImportCopy.message(for: error))
            }
            AppLog.model.error("archive import failed: \(error, privacy: .public)")
            return .failure(ArchiveImportCopy.unknownFailure)
        }
    }

    /// Fold a replay's report and its parse into the one record the UI reads.
    /// `incomplete` whenever anything the archive named didn't make it —
    /// a bare "succeeded" over a partial import is the outcome 004 taught this
    /// codebase not to report.
    /// `nonisolated` because the run that calls it is: `withAccess`'s body is a
    /// `@Sendable` closure, which does not inherit the controller's actor.
    nonisolated static func summary(
        for report: ImportReport, parse: ArchiveParse
    ) -> ImportRunSummary {
        let skipped = parse.skipped.count
        let failed = report.failed.count
        return ImportRunSummary(
            outcome: skipped + failed > 0 ? .incomplete : .succeeded,
            finishedAt: Date(),
            destinationName: report.destinationName,
            collections: report.collections,
            assets: report.assets,
            newAssets: report.newAssets,
            memberships: report.memberships,
            skipped: skipped,
            failed: failed,
            unreferenced: parse.unreferenced.count)
    }

    private func finish(_ summary: ImportRunSummary) {
        isImporting = false
        cancelFlag = nil
        task = nil
        if summary.outcome == .succeeded { progress = 1 }
        lastRun = summary
    }
}
