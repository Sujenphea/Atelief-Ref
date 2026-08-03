//
//  RestoreCopyTests.swift
//  AtelierRefsTests
//
//  008 · H5c — the words a restore says. Same standard `BackupStatusTests`
//  applies to backup prose, and it matters more here: restoring is the one
//  action in the app that replaces the library, so a sentence that under- or
//  over-states what is about to happen is a correctness bug, not a polish one.
//

import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Restore copy (008 H5c)")
struct RestoreCopyTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(
        _ outcome: BackupOutcome, ago seconds: TimeInterval = 3600, unresolved: Int = 0
    ) -> RestoreRunSummary {
        RestoreRunSummary(
            outcome: outcome, finishedAt: now.addingTimeInterval(-seconds),
            copiedFiles: 3, bytesCopied: 300, unresolvedFiles: unresolved)
    }

    private func source(
        blobCount: Int = 12, blobBytes: Int64 = 4_096, ago seconds: TimeInterval = 7200
    ) -> BackupSource {
        let id = "00aa11bb22cc33dd"
        return BackupSource(
            layout: BackupLayout(target: URL(fileURLWithPath: "/Volumes/Backup"), libraryID: id),
            manifest: BackupManifest(
                schemaVersion: "v18", appVersion: "1.0", libraryID: id,
                completedAt: now.addingTimeInterval(-seconds),
                blobCount: blobCount, blobBytes: blobBytes, databaseBytes: 1_024))
    }

    // MARK: - Status

    @Test("no attempt shows no line at all")
    func noAttemptIsSilent() {
        // Unlike a backup, silence here is honest: a library nobody has restored
        // is the normal state, and "never restored" would read as a warning.
        #expect(BackupTarget.restoreStatusLine(for: nil, now: now) == nil)
    }

    @Test("a prepared restore says the app must be reopened")
    func successNamesTheRelaunch() {
        let line = try! #require(BackupTarget.restoreStatusLine(
            for: summary(.succeeded), now: now))
        // The restore has NOT happened yet. A line implying otherwise would
        // leave someone believing their library was back when it wasn't.
        #expect(line.localizedCaseInsensitiveContains("quit and reopen"))
    }

    @Test("an incomplete restore says how many files didn't come back")
    func incompleteNamesTheCount() {
        let line = try! #require(BackupTarget.restoreStatusLine(
            for: summary(.incomplete, unresolved: 4), now: now))
        #expect(line.contains("4 files couldn't be copied back"))
        let one = try! #require(BackupTarget.restoreStatusLine(
            for: summary(.incomplete, unresolved: 1), now: now))
        #expect(one.contains("1 file couldn't be copied back"))
        #expect(!one.contains("1 files"))
    }

    @Test("a stopped or failed restore says the library is unchanged")
    func harmlessOutcomesSaySo() {
        // The user's first question after either is whether anything broke. Both
        // stage nothing, so both can answer it — and do.
        for outcome in [BackupOutcome.cancelled, .failed] {
            let line = try! #require(BackupTarget.restoreStatusLine(
                for: summary(outcome), now: now))
            #expect(line.localizedCaseInsensitiveContains("unchanged"))
        }
    }

    @Test("every outcome produces a distinct, non-empty line")
    func outcomesAreDistinguishable() {
        let lines = BackupOutcome.allCases.compactMap {
            BackupTarget.restoreStatusLine(for: summary($0, unresolved: 2), now: now)
        }
        #expect(lines.count == BackupOutcome.allCases.count)
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == BackupOutcome.allCases.count)
    }

    // MARK: - Confirmation

    @Test("the confirmation states the replacement, the relaunch, and what survives")
    func confirmationStatesTheThreeFacts() {
        let text = BackupTarget.restoreConfirmation(for: source(), now: now)
        // Destructive-adjacent: all three have to be said, in the dialog, before
        // the button — not in a status line afterwards.
        #expect(text.localizedCaseInsensitiveContains("replaces your current library"))
        #expect(text.localizedCaseInsensitiveContains("quit and reopened"))
        #expect(text.localizedCaseInsensitiveContains("set aside, not deleted"))
        // And it names the backup, so nobody restores the wrong one.
        #expect(text.contains("12 files"))
        #expect(text.localizedCaseInsensitiveContains("hours ago"))
    }

    @Test("a one-file backup reads in the singular")
    func confirmationSingular() {
        let text = BackupTarget.restoreConfirmation(for: source(blobCount: 1), now: now)
        #expect(text.contains("1 file "))
        #expect(!text.contains("1 files"))
    }

    @Test("a candidate's line names its size and age")
    func descriptionNamesSizeAndAge() {
        let text = BackupTarget.description(of: source(), now: now)
        #expect(text.contains("12 files"))
        #expect(text.localizedCaseInsensitiveContains("hours ago"))
        #expect(BackupTarget.description(of: source(blobCount: 1), now: now).contains("1 file "))
    }

    // MARK: - Failure words

    @Test("every restore failure names a different next action")
    func restoreErrorMessagesAreDistinct() {
        let all: [RestoreRunner.RestoreError] = [
            .databaseMissing, .manifestTooNew, .schemaTooNew("v99"),
            .snapshotsUnwritable, .databaseUnreadable, .databaseUnhealthy,
        ]
        let messages = all.map(BackupTarget.message(for:))
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == all.count)
    }

    @Test("a version refusal names the version and the remedy")
    func versionRefusalIsActionable() {
        // "Can't read this backup" with no version and no instruction is the
        // difference between updating the app and assuming the backup is dead.
        let schema = BackupTarget.message(for: .schemaTooNew("v99"))
        #expect(schema.contains("v99"))
        #expect(schema.localizedCaseInsensitiveContains("update the app"))
        #expect(BackupTarget.message(for: .manifestTooNew)
            .localizedCaseInsensitiveContains("update the app"))
    }

    @Test("no restore failure implies the live library was harmed")
    func failuresNeverImplyDamage() {
        // Every one of these refuses BEFORE anything is staged, so none of them
        // may leave the user wondering whether their library survived.
        for error in [RestoreRunner.RestoreError.databaseUnreadable, .databaseUnhealthy] {
            let message = BackupTarget.message(for: error)
            #expect(message.localizedCaseInsensitiveContains("nothing has changed")
                || message.localizedCaseInsensitiveContains("nothing was restored"))
        }
    }

    @Test("the restore words don't collide with the backup words")
    func restoreAndBackupMessagesAreDisjoint() {
        // Two different problems must never produce the same sentence — a user
        // reading "the drive is full" cannot be left guessing which half of the
        // feature said it.
        let restore: [RestoreRunner.RestoreError] = [
            .databaseMissing, .manifestTooNew, .schemaTooNew("v99"),
            .snapshotsUnwritable, .databaseUnreadable, .databaseUnhealthy,
        ]
        let backup: [BackupRunner.RunError] = [
            .destinationUnwritable, .databaseCopyFailed, .databaseCopyCorrupt,
            .databaseInstallFailed, .manifestWriteFailed,
        ]
        let restoreWords = Set(restore.map(BackupTarget.message(for:)))
            .union([BackupTarget.noBackupsFound, BackupTarget.unknownRestoreFailure,
                    BackupTarget.restoreStaged, BackupTarget.restoreExplainer])
        let backupWords = Set(backup.map(BackupTarget.message(for:)))
            .union([BackupTarget.unknownRunFailure, BackupTarget.explainer,
                    BackupTarget.unidentifiableLibrary, BackupTarget.couldNotRemember])
        #expect(restoreWords.intersection(backupWords).isEmpty)
    }

    @Test("the staged message tells the user the one thing left to do")
    func stagedMessageNamesTheRelaunch() {
        #expect(BackupTarget.restoreStaged.localizedCaseInsensitiveContains("quit and reopen"))
        #expect(BackupTarget.restoreStaged
            .localizedCaseInsensitiveContains("set aside, not deleted"))
    }

    @Test("the empty-folder message points at the mistake people actually make")
    func noBackupsFoundIsInstructive() {
        // Choosing the library folder instead of the backup folder is the
        // likeliest way to see this, so the message says which one to pick.
        #expect(BackupTarget.noBackupsFound.localizedCaseInsensitiveContains("backed up"))
    }
}
