//
//  BackupStatusTests.swift
//  AtelierRefsTests
//
//  008 · H5 — the last-run record and the sentence it turns into. This is the
//  only thing in the app that answers "is my backup current?", so the ways it
//  can lie are what get tested: a run that half-worked reported as a success, a
//  stale record surviving a change of target, a future build's record decoded
//  into something wrong.
//

import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Backup status (008 H5)")
struct BackupStatusTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(
        _ outcome: BackupOutcome, ago seconds: TimeInterval = 0, unresolved: Int = 0
    ) -> BackupRunSummary {
        BackupRunSummary(
            outcome: outcome, finishedAt: now.addingTimeInterval(-seconds),
            copiedFiles: 3, bytesCopied: 300, unresolvedFiles: unresolved)
    }

    // MARK: - The status line

    @Test("no record reads as never, not as up to date")
    func neverBackedUp() {
        // The likeliest reason someone's backup isn't where they expect is that
        // they chose a folder and never ran it. Silence would hide exactly that.
        #expect(BackupTarget.statusLine(for: nil, now: now) == "Never backed up.")
    }

    @Test("a success says when")
    func successNamesTheTime() {
        let line = BackupTarget.statusLine(for: summary(.succeeded, ago: 7200), now: now)
        #expect(line.hasPrefix("Last backed up "))
        #expect(line.localizedCaseInsensitiveContains("hour"))
    }

    @Test("an incomplete run is NOT reported as a success, and says how many")
    func incompleteIsDistinct() {
        let line = BackupTarget.statusLine(
            for: summary(.incomplete, ago: 3600, unresolved: 4), now: now)
        // "Some files" would leave the user unable to tell a rounding error from
        // half their library.
        #expect(line.contains("4 files couldn't be copied"))
        #expect(line != BackupTarget.statusLine(for: summary(.succeeded, ago: 3600), now: now))
    }

    @Test("one unresolved file is singular")
    func incompleteSingular() {
        let line = BackupTarget.statusLine(
            for: summary(.incomplete, ago: 3600, unresolved: 1), now: now)
        #expect(line.contains("1 file couldn't be copied"))
        #expect(!line.contains("1 files"))
    }

    @Test("a cancelled run says what was kept")
    func cancelledSaysWhatSurvived() {
        let line = BackupTarget.statusLine(for: summary(.cancelled, ago: 60), now: now)
        // Stopping keeps every copied file — saying so is what makes cancelling
        // feel safe enough to use.
        #expect(line.localizedCaseInsensitiveContains("kept"))
    }

    @Test("a failure is not dressed up as anything else")
    func failureIsPlain() {
        let line = BackupTarget.statusLine(for: summary(.failed, ago: 60), now: now)
        #expect(line.localizedCaseInsensitiveContains("failed"))
    }

    @Test("every outcome produces a distinct, non-empty line")
    func outcomesAreDistinguishable() {
        let lines = BackupOutcome.allCases.map {
            BackupTarget.statusLine(for: summary($0, ago: 3600, unresolved: 2), now: now)
        }
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == BackupOutcome.allCases.count)
    }

    // MARK: - Relative time

    @Test("a run seconds ago reads as just now, not '0 seconds ago'")
    func recentIsJustNow() {
        #expect(BackupTarget.relativeTime(from: now.addingTimeInterval(-5), to: now)
            == "just now")
    }

    @Test("a timestamp in the FUTURE doesn't read as 'in 3 hours'")
    func futureStampIsClamped() {
        // A clock adjustment, or a defaults plist copied from another Mac. "in 3
        // hours" reads as a bug in the app rather than a quirk of the clock.
        #expect(BackupTarget.relativeTime(from: now.addingTimeInterval(3600), to: now)
            == "just now")
        let line = BackupTarget.statusLine(for: summary(.succeeded, ago: -3600), now: now)
        #expect(line == "Last backed up just now.")
    }

    // MARK: - Persistence

    /// An isolated defaults suite, so tests never touch the real app domain.
    private func makeDefaults() -> UserDefaults {
        let name = "BackupStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a saved summary reads back identically")
    func summaryRoundTrips() {
        let store = BackupSummaryStore(defaults: makeDefaults())
        let saved = summary(.incomplete, ago: 120, unresolved: 2)
        store.save(saved)
        #expect(store.load() == saved)
    }

    @Test("with nothing saved there is no record — not a fabricated one")
    func emptyStoreIsNil() {
        #expect(BackupSummaryStore(defaults: makeDefaults()).load() == nil)
    }

    @Test("clearing forgets the record")
    func clearForgets() {
        let store = BackupSummaryStore(defaults: makeDefaults())
        store.save(summary(.succeeded))
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("a record this build can't understand reads as NO record")
    func unreadableRecordIsNil() {
        // A summary written by a future build (a new `BackupOutcome` case) must
        // not decode into something plausible-but-wrong. A missing status line
        // is a small lie; a confidently wrong one is a big one.
        let defaults = makeDefaults()
        defaults.set(Data(#"{"outcome":"teleported","finishedAt":0}"#.utf8),
                     forKey: BackupSummaryStore.key)
        #expect(BackupSummaryStore(defaults: defaults).load() == nil)
        #expect(BackupTarget.statusLine(for: BackupSummaryStore(defaults: defaults).load(),
                                        now: now) == "Never backed up.")
    }

    @Test("junk in the defaults key doesn't crash the Settings window")
    func garbageRecordIsNil() {
        let defaults = makeDefaults()
        defaults.set(Data("not json at all".utf8), forKey: BackupSummaryStore.key)
        #expect(BackupSummaryStore(defaults: defaults).load() == nil)
    }

    // MARK: - Run-failure words

    @Test("every run failure names a different next action")
    func runErrorMessagesAreDistinct() {
        let all: [BackupRunner.RunError] = [
            .destinationUnwritable, .databaseCopyFailed, .databaseCopyCorrupt,
            .databaseInstallFailed, .manifestWriteFailed,
        ]
        let messages = all.map(BackupTarget.message(for:))
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == all.count)
    }

    @Test("a failure that spared the previous backup SAYS so")
    func failuresReassureAboutThePreviousBackup() {
        // The user's first question after "backup failed" is whether they still
        // have the old one. Three of these five cases can answer it, so they do.
        for error in [BackupRunner.RunError.databaseCopyFailed,
                      .databaseCopyCorrupt, .databaseInstallFailed] {
            #expect(BackupTarget.message(for: error)
                .localizedCaseInsensitiveContains("previous backup is untouched"))
        }
    }

    @Test("a full drive is named as the likely cause, not left to guesswork")
    func fullDriveIsNamed() {
        #expect(BackupTarget.message(for: .databaseCopyFailed)
            .localizedCaseInsensitiveContains("full"))
    }

    @Test("the run-failure words don't collide with the target-choosing words")
    func runAndTargetMessagesAreDisjoint() {
        // Two different problems (this folder won't do / this run didn't work)
        // must not produce the same sentence.
        let target = [BackupTarget.message(for: .insideLibrary),
                      BackupTarget.message(for: FolderAccessError.bookmarkUnresolvable),
                      BackupTarget.message(for: FolderAccessError.accessDenied),
                      BackupTarget.couldNotRemember,
                      BackupTarget.unidentifiableLibrary,
                      BackupTarget.unknownRunFailure]
        let run: [BackupRunner.RunError] = [
            .destinationUnwritable, .databaseCopyFailed, .databaseCopyCorrupt,
            .databaseInstallFailed, .manifestWriteFailed,
        ]
        #expect(Set(target).intersection(Set(run.map(BackupTarget.message(for:)))).isEmpty)
    }
}
