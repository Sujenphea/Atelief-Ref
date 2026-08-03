//
//  BackupCadenceTests.swift
//  AtelierRefsTests
//
//  008 · H5d — the on-launch cadence: when a backup runs by itself, and the four
//  situations in which it deliberately does not.
//
//  Every staleness assertion here is made against an INJECTED clock, the way
//  `SnapshotManagerTests` makes its daily-snapshot ones. A boundary tested by
//  waiting is a boundary that is either untested or slow, and this one guards a
//  job that copies a whole library.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Backup cadence (008 H5d)")
struct BackupCadenceTests {

    // MARK: - Rig

    /// A real library, a destination folder beside it, an isolated defaults
    /// suite, and a clock the test moves by hand.
    private struct Rig {
        let controller: BackupController
        let services: AppServices
        let store: MediaStore
        let libraryRoot: URL
        let target: URL
        let defaults: UserDefaults
        let defaultsName: String
        let clock: TestClock
        let root: URL

        func cleanup() {
            UserDefaults().removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// `seeded` is written to the summary store BEFORE the controller is built,
    /// so it arrives the way a previous launch's record does.
    private func makeRig(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        seeded: BackupRunSummary? = nil,
        cadence: BackupCadence? = nil
    ) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCadenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for directory in [libraryRoot, target] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let services = try AppServices(
            databasePath: libraryRoot.appendingPathComponent("library.sqlite").path)

        let name = "BackupCadenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let summaries = BackupSummaryStore(defaults: defaults)
        if let seeded { summaries.save(seeded) }
        let cadences = BackupCadenceStore(defaults: defaults)
        let libraryID = try LibraryIdentity.resolve(root: libraryRoot)
        if let cadence { cadences.save(cadence, libraryID: libraryID) }

        let clock = TestClock(now)
        let controller = BackupController(
            summaries: summaries, cadences: cadences, now: { clock.now })
        controller.activate(libraryID: libraryID)

        return Rig(
            controller: controller, services: services,
            store: MediaStore(root: libraryRoot), libraryRoot: libraryRoot,
            target: target, defaults: defaults, defaultsName: name,
            clock: clock, root: root)
    }

    /// One asset with its blob bytes on disk, so a run has something to copy.
    private func seed(_ rig: Rig, hash: String) async throws {
        try rig.store.storeBlob(Data("payload".utf8), hash: hash, fileExtension: "png")
        let collection = try await rig.services.createCollection(name: "C-\(hash)")
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 7,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(hash)", capturedAt: Date())
        _ = try await rig.services.ingest(draft, from: source, into: collection.id)
    }

    /// The cadence check, awaited to completion.
    @discardableResult
    private func backUpIfStale(
        _ rig: Rig,
        folder: (any FolderAccess)? = nil,
        restorePending: Bool = false
    ) async -> Bool {
        await rig.controller.backUpIfStale(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: folder ?? DirectFolderAccess(url: rig.target),
            appVersion: "1.0-test", restorePending: restorePending)
    }

    private func succeeded(at date: Date) -> BackupRunSummary {
        BackupRunSummary(outcome: .succeeded, finishedAt: date, copiedFiles: 3)
    }

    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - The staleness boundary

    @Test("a library that has never backed up is stale")
    func neverRunIsStale() {
        #expect(BackupController.isStale(lastRun: nil, maxAge: 86_400, now: Date()))
    }

    @Test("the boundary: not stale just inside maxAge, stale just outside")
    func boundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inside = succeeded(at: now.addingTimeInterval(-86_400 + 1))
        let outside = succeeded(at: now.addingTimeInterval(-86_400 - 1))
        #expect(!BackupController.isStale(lastRun: inside, maxAge: 86_400, now: now))
        #expect(BackupController.isStale(lastRun: outside, maxAge: 86_400, now: now))
        // Exactly at the boundary counts as due — the same `< maxAge` ⇒ skip
        // rule `SnapshotManager.snapshotIfStale` uses, from the other side.
        let exact = succeeded(at: now.addingTimeInterval(-86_400))
        #expect(BackupController.isStale(lastRun: exact, maxAge: 86_400, now: now))
    }

    @Test("a FAILED run does not reset the clock")
    func failedRunIsStillStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = BackupRunSummary(outcome: .failed, finishedAt: now, message: "nope")
        // Finished one second ago and still due: the destination is exactly as
        // stale as it was, so counting a failure as a backup would buy a whole
        // cadence period of silence for a backup that never happened.
        #expect(BackupController.isStale(lastRun: failed, maxAge: 86_400, now: now))
    }

    @Test("a CANCELLED run does not reset the clock")
    func cancelledRunIsStillStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cancelled = BackupRunSummary(outcome: .cancelled, finishedAt: now)
        #expect(BackupController.isStale(lastRun: cancelled, maxAge: 86_400, now: now))
    }

    @Test("an INCOMPLETE run does reset the clock")
    func incompleteRunResetsTheClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let incomplete = BackupRunSummary(
            outcome: .incomplete, finishedAt: now, copiedFiles: 9, unresolvedFiles: 1)
        // It finished and installed a verified database. Its one unresolved file
        // is a blob missing at the SOURCE, which re-running cannot conjure back —
        // treating it as stale would attempt a full backup on every launch
        // forever over a fault the status line already reports.
        #expect(!BackupController.isStale(lastRun: incomplete, maxAge: 86_400, now: now))
    }

    // MARK: - The automatic run

    @Test("a stale library backs up on launch and records it")
    func staleLibraryBacksUp() async throws {
        let rig = try makeRig(cadence: .daily)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig))

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .succeeded)
        #expect(summary.copiedFiles == 1)
        // Stamped from the injected clock, so the next launch's staleness test
        // is a decision about this date rather than about how long the test took.
        #expect(summary.finishedAt == rig.clock.now)
    }

    @Test("a fresh successful run means the next launch does nothing")
    func freshRunIsSkipped() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rig = try makeRig(
            now: now, seeded: succeeded(at: now.addingTimeInterval(-3_600)), cadence: .daily)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig) == false)
        // Untouched — not merely "no new files copied", but no run at all.
        #expect(rig.controller.lastRun?.copiedFiles == 3)
        #expect(!FileManager.default.fileExists(atPath: rig.target
            .appendingPathComponent(try LibraryIdentity.resolve(root: rig.libraryRoot)).path))
    }

    @Test("crossing the boundary starts the run the next launch would")
    func boundaryDrivesTheRun() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inside = try makeRig(
            now: now, seeded: succeeded(at: now.addingTimeInterval(-day + 60)),
            cadence: .daily)
        defer { inside.cleanup() }
        #expect(await backUpIfStale(inside) == false)

        let outside = try makeRig(
            now: now, seeded: succeeded(at: now.addingTimeInterval(-day - 60)),
            cadence: .daily)
        defer { outside.cleanup() }
        #expect(await backUpIfStale(outside))
    }

    @Test("weekly leaves a two-day-old backup alone that daily would replace")
    func weeklyIsLongerThanDaily() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let last = succeeded(at: now.addingTimeInterval(-2 * day))
        let weekly = try makeRig(now: now, seeded: last, cadence: .weekly)
        defer { weekly.cleanup() }
        #expect(await backUpIfStale(weekly) == false)

        let daily = try makeRig(now: now, seeded: last, cadence: .daily)
        defer { daily.cleanup() }
        #expect(await backUpIfStale(daily))
    }

    @Test("a failed run is retried on the next launch")
    func failedRunIsRetried() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = BackupRunSummary(
            outcome: .failed, finishedAt: now.addingTimeInterval(-60), message: "drive gone")
        let rig = try makeRig(now: now, seeded: failed, cadence: .daily)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig))
        #expect(rig.controller.lastRun?.outcome == .succeeded)
    }

    // MARK: - The four refusals

    @Test("MANUAL never runs automatically")
    func manualNeverRuns() async throws {
        let rig = try makeRig(cadence: .manual)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig) == false)
        // Nothing recorded either: a cadence of "manual" is the absence of an
        // automatic path, not a very long one.
        #expect(rig.controller.lastRun == nil)
    }

    @Test("a PENDING RESTORE blocks the automatic run")
    func pendingRestoreBlocksTheRun() async throws {
        let rig = try makeRig(cadence: .daily)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig, restorePending: true) == false)
        // The same guard "Back Up Now" carries, and for a sharper reason: if the
        // staged restore came from THIS target, an unattended run would overwrite
        // the backup the user is one relaunch away from restoring.
        #expect(rig.controller.lastRun == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.target
            .appendingPathComponent(try LibraryIdentity.resolve(root: rig.libraryRoot)).path))
    }

    @Test("an unresolvable bookmark is skipped SILENTLY, not recorded as a failure")
    func unresolvableBookmarkIsSkipped() async throws {
        let rig = try makeRig(cadence: .daily)
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        #expect(await backUpIfStale(rig, folder: AbsentFolder()) == false)
        // An unplugged external drive is the NORMAL state of a backup disk. A
        // "Last backup failed" line at every launch would train the user to
        // ignore the one time it means something.
        #expect(rig.controller.lastRun == nil)
    }

    @Test("a run already in flight is not joined by the automatic one")
    func runningRunIsNotDoubled() async throws {
        let rig = try makeRig(cadence: .daily)
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xDDD0_0000 + index))
        }

        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: DirectFolderAccess(url: rig.target), appVersion: "1.0-test")
        #expect(rig.controller.isRunning)
        #expect(await backUpIfStale(rig) == false)

        for _ in 0 ..< 400 where rig.controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.controller.lastRun?.outcome == .succeeded)
    }

    // MARK: - The preference

    @Test("the cadence defaults to manual and is remembered per library")
    func cadenceIsPersistedPerLibrary() throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        // Automatic backup is opt-in: an install that already has a folder
        // chosen must not start copying itself somewhere because it updated.
        #expect(rig.controller.cadence == .manual)

        rig.controller.setCadence(.weekly)
        let libraryID = try LibraryIdentity.resolve(root: rig.libraryRoot)
        let relaunched = BackupController(
            summaries: BackupSummaryStore(defaults: rig.defaults),
            cadences: BackupCadenceStore(defaults: rig.defaults))
        relaunched.activate(libraryID: libraryID)
        #expect(relaunched.cadence == .weekly)

        // A DIFFERENT library in the same defaults keeps its own answer — two
        // libraries pointed at one folder must be able to disagree.
        let other = BackupController(
            summaries: BackupSummaryStore(defaults: rig.defaults),
            cadences: BackupCadenceStore(defaults: rig.defaults))
        other.activate(libraryID: "fedcba9876543210")
        #expect(other.cadence == .manual)
    }

    @Test("a cadence written by a future build degrades to daily, not to off")
    func unknownCadenceDegradesToDaily() throws {
        let name = "BackupCadenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set("fortnightly", forKey: BackupCadenceStore.key(libraryID: "0123456789abcdef"))

        // NOT the `manual` default: a value written at all is evidence the user
        // chose automatic, and falling back to `manual` would silently stop the
        // backups of anyone who ran a newer build once.
        #expect(BackupCadenceStore(defaults: defaults)
            .load(libraryID: "0123456789abcdef") == .daily)
    }

    @Test("no stored cadence reads as manual, not as an unrecognised one")
    func absentCadenceIsManual() throws {
        let name = "BackupCadenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        // The pair the two fallbacks exist to keep apart: nothing recorded means
        // never asked; something unreadable means asked, in words we don't know.
        #expect(BackupCadenceStore(defaults: defaults)
            .load(libraryID: "0123456789abcdef") == .manual)
    }

    @Test("a cadence set before the library opens isn't written under no id")
    func cadenceWithoutALibraryIsNotPersisted() throws {
        let name = "BackupCadenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }

        let controller = BackupController(
            summaries: BackupSummaryStore(defaults: defaults),
            cadences: BackupCadenceStore(defaults: defaults))
        // Deliberately NOT the default — the assertion below has to be able to
        // tell "never persisted" apart from "persisted and read back".
        controller.setCadence(.weekly)
        #expect(controller.cadence == .weekly)

        // In memory only: a preference filed under no library is one nothing
        // ever reads back, and writing it would leave a key with no owner.
        controller.activate(libraryID: "0123456789abcdef")
        #expect(controller.cadence == .manual)
        #expect(defaults.string(
            forKey: BackupCadenceStore.key(libraryID: "0123456789abcdef")) == nil)
    }

    @Test("maxAge is nil for manual and ordered for the rest")
    func maxAges() {
        #expect(BackupCadence.manual.maxAge == nil)
        #expect(BackupCadence.daily.maxAge == day)
        #expect(BackupCadence.weekly.maxAge == 7 * day)
    }
}

// MARK: - Test doubles

/// A target whose bookmark won't resolve — the unplugged-drive case.
private struct AbsentFolder: FolderAccess {
    func resolve() throws -> URL { throw FolderAccessError.bookmarkUnresolvable }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}

/// A clock the test sets by hand, shared with the controller it was injected
/// into. `@unchecked Sendable` because the closure that reads it crosses into a
/// detached task; the tests move it only between awaits.
private nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
