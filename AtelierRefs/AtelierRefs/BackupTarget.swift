//
//  BackupTarget.swift
//  AtelierRefs
//
//  008 · H4 — the rules and words for the off-device backup destination, kept
//  free of AppKit and SwiftUI so all of it is directly unit-testable. The view
//  supplies layout; this supplies the facts. (Same split as `CaptureCopy`, for
//  the same reason: prose and rules duplicated across surfaces drift.)
//

import AtelierIngestion
import Foundation

/// Why a folder the user picked can't serve as the backup target.
nonisolated enum BackupTargetRejection: Error, Equatable {
    /// The chosen folder IS the library, or sits inside it. Backing the library
    /// up into itself would copy blobs into the tree being enumerated and grow
    /// without bound — and it defeats the point, since the whole reason for an
    /// off-device copy is surviving the loss of this one.
    case insideLibrary
}

nonisolated enum BackupTarget {

    // MARK: - Choosing

    /// Vet a freshly picked folder. `nil` means it is usable.
    ///
    /// `libraryRoot` is optional because the Library may not be open yet; with
    /// nothing to compare against we cannot claim a conflict, so the choice
    /// stands. (Not a real path in practice — Settings is unreachable before
    /// bootstrap — but returning "rejected" on unknown would be a lie.)
    static func rejection(choosing target: URL, libraryRoot: URL?) -> BackupTargetRejection? {
        guard let libraryRoot else { return nil }
        return isSelfOrDescendant(target, of: libraryRoot) ? .insideLibrary : nil
    }

    /// Whether `url` is `ancestor` itself or lives underneath it.
    ///
    /// Compared by path COMPONENT, never by string prefix: `/Vol/Library2` has
    /// `/Vol/Library` as a string prefix but is a sibling, and rejecting it would
    /// block a perfectly good target. Symlinks are resolved and the path
    /// standardized first so `~/Backups/../Backups` and a symlinked volume path
    /// can't slip past.
    ///
    /// Comparison is case-INSENSITIVE, matching APFS's default. On a
    /// case-sensitive volume this is stricter than the filesystem — it can reject
    /// a folder that is technically distinct. That is the safe direction to err:
    /// the cost is re-picking a folder, versus a backup that eats itself.
    static func isSelfOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let target = normalizedComponents(url)
        let root = normalizedComponents(ancestor)
        guard root.count <= target.count else { return false }
        return zip(target, root).allSatisfy {
            $0.compare($1, options: .caseInsensitive) == .orderedSame
        }
    }

    private static func normalizedComponents(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    // MARK: - Words

    /// What to tell the user about a rejected choice.
    static func message(for rejection: BackupTargetRejection) -> String {
        switch rejection {
        case .insideLibrary:
            return "That folder is inside your library, so it can't hold the "
                + "backup. Choose a folder on another drive."
        }
    }

    /// What to tell the user about a target that can't be reached right now.
    /// Each case names a DIFFERENT next action — which is the whole reason
    /// ``FolderAccessError`` has three cases instead of being one opaque error.
    static func message(for error: FolderAccessError) -> String {
        switch error {
        case .noFolderChosen:
            return "No backup folder chosen yet."
        case .bookmarkUnresolvable:
            return "Can't find the backup folder. If it's on an external drive, "
                + "reconnect it — otherwise choose it again."
        case .accessDenied:
            return "macOS denied access to the backup folder. Choose it again to "
                + "restore permission."
        }
    }

    /// Shown when remembering a folder fails outright — a bookmark that can't be
    /// made at all, which leaves NO target behind (`StoredFolderAccess.setFolder`
    /// persists nothing on failure), so the honest instruction is to retry.
    static let couldNotRemember =
        "Couldn't remember that folder. Try choosing it again."

    /// What to tell the user about a run that couldn't finish (008 · H5).
    /// Each case names the thing to DO about it — a run failing is only useful
    /// information if it says whether to free space, reconnect a drive, or
    /// report a bug.
    static func message(for error: BackupRunner.RunError) -> String {
        switch error {
        case .destinationUnwritable:
            return "Couldn't write to the backup folder. Check the drive is "
                + "connected and not read-only."
        case .databaseCopyFailed:
            return "Couldn't copy the library database — the backup drive is "
                + "most likely full. Your previous backup is untouched."
        case .databaseCopyCorrupt:
            return "The copied database didn't pass its integrity check, so it "
                + "wasn't installed. Your previous backup is untouched."
        case .databaseInstallFailed:
            return "Couldn't replace the previous database copy. Your previous "
                + "backup is untouched."
        case .manifestWriteFailed:
            return "The backup copied, but couldn't be marked complete. Run it "
                + "again."
        }
    }

    /// What to tell the user when the library's own identity file is unusable.
    /// Rare, and deliberately not self-healing — see ``LibraryIdentity``.
    static let unidentifiableLibrary =
        "Couldn't identify this library, so there's nowhere safe to put the "
        + "backup. The `library-id` file in your library folder is damaged."

    /// The catch-all, for an error with no specific remedy to offer.
    static let unknownRunFailure =
        "The backup didn't finish. Try again — if it keeps failing, export "
        + "diagnostics from Settings."

    // MARK: - Last run

    /// The one-line status under the Backup section: when the last run was, and
    /// whether it can be relied on.
    ///
    /// `nil` summary means no run has ever been recorded, which is a real state
    /// worth naming — a target chosen but never used is the most likely reason
    /// someone's backup isn't where they expect it.
    static func statusLine(for summary: BackupRunSummary?, now: Date = Date()) -> String {
        guard let summary else { return "Never backed up." }
        let when = relativeTime(from: summary.finishedAt, to: now)
        switch summary.outcome {
        case .succeeded:
            return "Last backed up \(when)."
        case .incomplete:
            // Say the number. "Some files" leaves the user unable to judge
            // whether this is a rounding error or half their library.
            let count = summary.unresolvedFiles
            return "Last backed up \(when) — \(count) "
                + (count == 1 ? "file" : "files") + " couldn't be copied."
        case .cancelled:
            return "Last backup stopped \(when). What copied was kept."
        case .failed:
            return "Last backup failed \(when)."
        }
    }

    /// A coarse, human "when" — the precision a backup status actually wants.
    /// Nobody needs seconds; they need to know whether it was today.
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        // A clock adjustment (or a file copied from another Mac) can put the
        // stamp in the future. "in 3 hours" would read as a bug, so clamp.
        guard seconds > 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Restore (008 · H5c)

    /// What to tell the user about a restore that couldn't run. Same standard as
    /// the backup messages: name the thing to DO, and never imply the live
    /// library was harmed — none of these touch it.
    static func message(for error: RestoreRunner.RestoreError) -> String {
        switch error {
        case .databaseMissing:
            return "That backup has no library database, so there's nothing to "
                + "restore from. Back up again from the Mac that made it."
        case .manifestTooNew:
            return "That backup was made by a newer version of AtelierRefs. "
                + "Update the app, then try again."
        case .schemaTooNew(let version):
            return "That backup uses a newer library format (\(version)) than "
                + "this version of AtelierRefs understands. Update the app, then "
                + "try again."
        case .snapshotsUnwritable:
            return "Couldn't write to this library's snapshots folder, so the "
                + "restore can't be prepared. Check the disk isn't full."
        case .databaseUnreadable:
            return "Couldn't copy the library database out of the backup. Check "
                + "the drive is connected and this Mac has space. Nothing has "
                + "changed."
        case .databaseUnhealthy:
            return "That backup's database didn't pass its integrity check, so "
                + "nothing was restored. Try an earlier backup."
        }
    }

    /// Shown when the chosen folder holds no restorable backup.
    static let noBackupsFound =
        "No complete backups in that folder. Choose the folder you backed up "
        + "INTO — backups live in a folder named after the library."

    /// The catch-all, for a restore error with no specific remedy to offer.
    static let unknownRestoreFailure =
        "The restore didn't finish. Your library hasn't changed — try again, and "
        + "if it keeps failing, export diagnostics from Settings."

    /// The one-line status under the restore row.
    static func restoreStatusLine(
        for summary: RestoreRunSummary?, now: Date = Date()
    ) -> String? {
        guard let summary else { return nil }
        let when = relativeTime(from: summary.finishedAt, to: now)
        switch summary.outcome {
        case .succeeded:
            return "Restore prepared \(when) — quit and reopen to apply it."
        case .incomplete:
            // Say the number. A restore that silently dropped media is the
            // worst possible thing to round off to "done".
            let count = summary.unresolvedFiles
            return "Restore prepared \(when), but \(count) "
                + (count == 1 ? "file" : "files")
                + " couldn't be copied back. Quit and reopen to apply it."
        case .cancelled:
            return "Restore stopped \(when). Your library is unchanged."
        case .failed:
            return "Restore failed \(when). Your library is unchanged."
        }
    }

    /// The confirmation before a restore — destructive-adjacent, so it states
    /// plainly what is replaced, what is kept, and that the app must relaunch.
    static func restoreConfirmation(for source: BackupSource, now: Date = Date()) -> String {
        let when = relativeTime(from: source.completedAt, to: now)
        let size = ByteCountFormatter.string(
            fromByteCount: source.manifest.blobBytes, countStyle: .file)
        return "This copies \(source.manifest.blobCount) "
            + (source.manifest.blobCount == 1 ? "file" : "files")
            + " (\(size)) back into your library, then replaces your current "
            + "library with the backup taken \(when). AtelierRefs must be quit "
            + "and reopened to finish. Your current library is set aside, not "
            + "deleted."
    }

    /// Shown once the restore is prepared and only a relaunch is left.
    static let restoreStaged =
        "The backup will be restored the next time you open AtelierRefs. Quit "
        + "and reopen to complete the restore — your current library is set "
        + "aside, not deleted."

    /// One line describing a candidate backup in the restore list.
    static func description(of source: BackupSource, now: Date = Date()) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: source.manifest.blobBytes, countStyle: .file)
        return "\(source.manifest.blobCount) "
            + (source.manifest.blobCount == 1 ? "file" : "files")
            + " · \(size) · backed up \(relativeTime(from: source.completedAt, to: now))"
    }

    /// The standing explanation under the restore row.
    static let restoreExplainer =
        "Restoring copies the backup's images back into this library and replaces "
        + "its database. Use it on a new Mac, or after losing data. It never "
        + "deletes anything you've added since."

    // MARK: - Cadence (008 · H5d)

    /// The standing explanation under the "Automatically" picker.
    ///
    /// It names the three things a user would otherwise have to discover by
    /// waiting: that automatic means *at launch*, that it is checked rather than
    /// scheduled, and that a disconnected drive is a skip rather than a failure.
    static let automaticExplainer =
        "Automatic backups run in the background shortly after AtelierRefs opens, "
        + "and only when the last one is older than this. They're skipped while "
        + "the backup folder isn't reachable, and while a restore is waiting."

    // MARK: - Verification (008 · H5d)

    /// What to tell the user about a check that couldn't run.
    static func message(for error: BackupVerifier.VerifyError) -> String {
        switch error {
        case .noBackupFound:
            return "There's no backup of this library in that folder yet, so "
                + "there's nothing to check. Back up first."
        }
    }

    /// The catch-all, for a check error with no specific remedy to offer.
    static let unknownVerifyFailure =
        "The check didn't finish. Your backup hasn't been changed — try again, "
        + "and if it keeps failing, export diagnostics from Settings."

    /// The one-line result under the check row.
    ///
    /// A clean result always says how much was looked at. "Everything matched"
    /// on its own would read as a statement about the whole backup when it is a
    /// statement about thirty-two files, and a verifier that overstates its own
    /// reach is worse than one nobody runs.
    static func verifyStatusLine(
        for summary: BackupVerifySummary?, now: Date = Date()
    ) -> String? {
        guard let summary else { return nil }
        let when = relativeTime(from: summary.finishedAt, to: now)
        switch summary.outcome {
        case .succeeded:
            guard let result = summary.result else { return "Checked \(when)." }
            if result.wasExhaustive {
                return "Checked all \(fileCount(result.totalFiles)) \(when) — "
                    + "everything matched."
            }
            return "Checked \(result.checked) of \(fileCount(result.totalFiles)) "
                + "\(when) — everything matched."
        case .incomplete:
            return "Checked \(when) — problems found."
        case .cancelled:
            return "Check stopped \(when). Nothing was changed."
        case .failed:
            return "Check failed \(when)."
        }
    }

    /// The loud part: what a check FOUND, and what to do about it.
    ///
    /// Every branch says explicitly that nothing was deleted. A verifier's
    /// finding arrives as bad news about the copy someone would restore from,
    /// and the first question that follows is "did it just throw my backup
    /// away?" — answering it before it is asked is the difference between a
    /// warning that is acted on and one that is panicked about.
    ///
    /// `nil` when there is nothing to report.
    static func verifyProblem(for result: BackupVerifyResult) -> String? {
        var parts: [String] = []
        if !result.databaseHealthy {
            parts.append(
                "The backup's database didn't pass its integrity check. Back up "
                + "again — the next run installs a fresh copy over it.")
        }
        if !result.mismatched.isEmpty {
            let count = result.mismatched.count
            parts.append(
                "\(count) backed-up \(count == 1 ? "file no" : "files no longer") "
                + "\(count == 1 ? "longer matches" : "match") its own checksum, so "
                + "that backup can't be fully trusted. Nothing was deleted — back "
                + "up to a fresh folder to make a clean copy.")
        }
        if !result.unreadable.isEmpty {
            let count = result.unreadable.count
            parts.append(
                "\(count) \(count == 1 ? "file" : "files") couldn't be read. If the "
                + "backup is in iCloud Drive or on a network drive, check it's "
                + "online and try again. Nothing was deleted.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The standing explanation under the check row — the cost, stated up front.
    static let verifyExplainer =
        "Checking re-reads some of the backup's files and confirms each one still "
        + "matches its checksum. It has to download what it reads, so on iCloud "
        + "Drive or a network drive it costs time and bandwidth. It never deletes "
        + "anything."

    /// `n files` / `1 file`.
    private static func fileCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files")"
    }

    /// The standing explanation under the folder row.
    static let explainer =
        "Backups copy your images and database here. Snapshots (File ▸ Snapshot "
        + "Now) live inside the library and won't survive losing this Mac — an "
        + "off-device folder will."
}
