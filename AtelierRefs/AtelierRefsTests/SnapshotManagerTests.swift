//
//  SnapshotManagerTests.swift
//  AtelierRefsTests
//
//  008 H3b — the snapshot retention policy (pure) and the SnapshotManager over a
//  real temp AppServices: snapshots get taken, listed, and pruned; the daily
//  check doesn't re-snapshot when a fresh daily already exists.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SnapshotManager (008 H3)")
struct SnapshotManagerTests {

    private let dir = URL(fileURLWithPath: "/tmp/snaps", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snap(_ reason: SnapshotReason, daysAgo: Int, _ id: String) -> SnapshotFile {
        let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return SnapshotFile(url: SnapshotFile.makeURL(
            in: dir, reason: reason, date: date, id: id))!
    }

    @Test("retention keeps 7 newest + 4 weekly; pre-migration never pruned")
    func retention() {
        var snapshots = (0...6).map { snap(.daily, daysAgo: $0, "r\($0)") }   // 7 recent
        snapshots += [10, 20, 30, 40, 50, 60].map { snap(.daily, daysAgo: $0, "w\($0)") }
        snapshots += [snap(.preMigration, daysAgo: 100, "pm")]                // sacrosanct

        let deleted = Set(SnapshotRetention().prunable(snapshots, now: now).map(\.url))

        // Kept: the 7 recent, the 4 newest-per-week older ones (10/20/30/40),
        // and the pre-migration snapshot. Pruned: the 5th/6th older weeks.
        #expect(deleted == Set([snap(.daily, daysAgo: 50, "w50").url,
                                snap(.daily, daysAgo: 60, "w60").url]))
        #expect(!deleted.contains(snap(.preMigration, daysAgo: 100, "pm").url))
    }

    @Test("pre-migration snapshots are exempt even when they are the oldest many")
    func preMigrationExempt() {
        let snapshots = (0..<20).map { snap(.preMigration, daysAgo: $0 * 7, "pm\($0)") }
        #expect(SnapshotRetention().prunable(snapshots, now: now).isEmpty)
    }

    @Test("pre-destructive snapshots inside the 30-day floor are exempt; older ones roll")
    func preDestructiveFloor() {
        let young = snap(.preDestructive, daysAgo: 8, "young")
        let old = snap(.preDestructive, daysAgo: 40, "old")
        // 8 dailies newer than both, so the recent-7 window is fully occupied
        // and everything older is prunable (weekly ladder disabled).
        let snapshots = (0...7).map { snap(.daily, daysAgo: $0, "r\($0)") } + [young, old]

        let deleted = Set(
            SnapshotRetention(weeklyWeeks: 0).prunable(snapshots, now: now).map(\.url))

        #expect(!deleted.contains(young.url)) // 8 days old: floor-protected
        #expect(deleted.contains(old.url))    // 40 days old: rolls like any other
        #expect(deleted.contains(snap(.daily, daysAgo: 7, "r7").url))
    }

    /// A mutable clock for the manager's injected `now` (11A).
    @MainActor final class TestClock {
        var now: Date
        init(_ date: Date) { self.now = date }
    }

    private func makeManager(
        now: @escaping () -> Date = Date.init
    ) throws -> (SnapshotManager, cleanup: () -> Void) {
        let dbPath = NSTemporaryDirectory() + "snapmgr-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let snapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snaps-\(UUID().uuidString)", isDirectory: true)
        let manager = SnapshotManager(services: services, directory: snapDir, now: now)
        return (manager, { try? FileManager.default.removeItem(at: snapDir) })
    }

    @Test("snapshot(reason:) writes a file that list() then reports")
    func snapshotAndList() async throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }

        let url = try await manager.snapshot(reason: .manual)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let list = manager.list()
        #expect(list.count == 1)
        #expect(list.first?.reason == .manual)
        #expect(try AppServices.isHealthy(databaseFileAt: url))
    }

    @Test("byteSize reports a real size; delete removes the file from disk + list")
    func byteSizeAndDelete() async throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }

        _ = try await manager.snapshot(reason: .manual)
        let snapshot = try #require(manager.list().first)
        #expect(manager.byteSize(of: snapshot) > 0)

        manager.delete(snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.url.path))
        #expect(manager.list().isEmpty)
        #expect(manager.byteSize(of: snapshot) == 0)   // gone → 0
    }

    @Test("snapshotIfStale takes one daily, then no-ops while it's fresh")
    func staleCheck() async throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }

        await manager.snapshotIfStale()
        #expect(manager.list().filter { $0.reason == .daily }.count == 1)
        await manager.snapshotIfStale() // a fresh daily exists → no second one
        #expect(manager.list().filter { $0.reason == .daily }.count == 1)
    }

    @Test("snapshotIfStale boundary: no-op just under 24h, snapshots just over")
    func staleBoundary() async throws {
        let clock = TestClock(now)
        let (manager, cleanup) = try makeManager(now: { clock.now })
        defer { cleanup() }

        await manager.snapshotIfStale()
        #expect(manager.list().filter { $0.reason == .daily }.count == 1)

        clock.now = now.addingTimeInterval(24 * 60 * 60 - 60) // 23h59m: fresh
        await manager.snapshotIfStale()
        #expect(manager.list().filter { $0.reason == .daily }.count == 1)

        clock.now = now.addingTimeInterval(24 * 60 * 60 + 60) // 24h01m: stale
        await manager.snapshotIfStale()
        #expect(manager.list().filter { $0.reason == .daily }.count == 2)
    }

    @Test("snapshotBeforeDestruction skips while any snapshot is <10 min old, fires after")
    func destructionFreshnessGate() async throws {
        let clock = TestClock(now)
        let (manager, cleanup) = try makeManager(now: { clock.now })
        defer { cleanup() }

        _ = try await manager.snapshot(reason: .manual)
        clock.now = now.addingTimeInterval(5 * 60) // 5 min later: gated
        #expect(try await manager.snapshotBeforeDestruction() == nil)
        #expect(manager.list().count == 1)

        clock.now = now.addingTimeInterval(11 * 60) // 11 min later: fires
        let url = try await manager.snapshotBeforeDestruction()
        #expect(url != nil)
        #expect(manager.list().filter { $0.reason == .preDestructive }.count == 1)
    }

    @Test("consumePreMigrationSnapshotFailure fires once, then clears the marker")
    func consumeFailureMarker() async throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        try FileManager.default.createDirectory(
            at: manager.directory, withIntermediateDirectories: true)
        let marker = manager.directory
            .appendingPathComponent(".pre-migration-snapshot-failed")
        try "2026-07-31T00:00:00Z".write(to: marker, atomically: true, encoding: .utf8)

        #expect(manager.consumePreMigrationSnapshotFailure())
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!manager.consumePreMigrationSnapshotFailure()) // once only
    }

    @Test("stageRestore + applyPendingRestore reverts the live DB to the snapshot")
    func restoreRoundTrip() async throws {
        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let dbURL = dbDir.appendingPathComponent("library.sqlite")
        let snapDir = dbDir.appendingPathComponent("snapshots", isDirectory: true)

        // Phase 1: "Before" → snapshot → add "After" → stage restore. Scope the
        // services + manager so the pool closes before the file swap.
        do {
            let services = try AppServices(databasePath: dbURL.path)
            _ = try await services.createCollection(name: "Before")
            let manager = SnapshotManager(services: services, directory: snapDir)
            let snapURL = try await manager.snapshot(reason: .manual)
            _ = try await services.createCollection(name: "After")
            try manager.stageRestore(SnapshotFile(url: snapURL)!)
            #expect(manager.hasPendingRestore())
        }

        // Phase 2 (simulated relaunch): apply the staged restore before reopening.
        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        let reopened = try AppServices(databasePath: dbURL.path)
        let names = Set(try await reopened.listCollections().map(\.name))
        #expect(names.contains("Before"))
        #expect(!names.contains("After")) // reverted to the pre-mutation snapshot
        // The marker is consumed, and the displaced live DB is preserved aside.
        #expect(!FileManager.default.fileExists(
            atPath: snapDir.appendingPathComponent(".pending-restore").path))
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dbDir.path)) ?? []
        let asideName = try #require(aside.first {
            $0.hasPrefix("library.corrupt-") && $0.hasSuffix(".sqlite")
        })
        // "Set aside, NOT deleted" (the sheet's literal promise): the displaced
        // live DB opens and still holds the post-snapshot mutation verbatim.
        let asideDB = try AppServices(
            databasePath: dbDir.appendingPathComponent(asideName).path)
        let asideNames = Set(try await asideDB.listCollections().map(\.name))
        #expect(asideNames.contains("After"))

        // A successful restore announces itself to the next bootstrap (3A):
        // the just-restored marker exists and consumes exactly once.
        let manager = SnapshotManager(services: reopened, directory: snapDir)
        #expect(manager.consumeJustRestored())
        #expect(!manager.consumeJustRestored())
    }

    @Test("prune (through the manager) deletes rolled-off snapshot files from disk")
    func pruneDeletesFromDisk() async throws {
        let clock = TestClock(now)
        let (manager, cleanup) = try makeManager(now: { clock.now })
        defer { cleanup() }
        try FileManager.default.createDirectory(
            at: manager.directory, withIntermediateDirectories: true)
        // 7 recent dailies fill the rolling window; five older ones sit ≥7 days
        // apart (distinct ISO weeks), so the weekly ladder keeps 4 and rolls the
        // fifth. Files are fabricated — prune never opens them.
        var urls: [Int: URL] = [:]
        for daysAgo in [0, 1, 2, 3, 4, 5, 6, 60, 70, 80, 90, 100] {
            let url = SnapshotFile.makeURL(
                in: manager.directory, reason: .daily,
                date: now.addingTimeInterval(-Double(daysAgo) * 86_400), id: "d\(daysAgo)")
            try Data("x".utf8).write(to: url)
            urls[daysAgo] = url
        }

        manager.prune()

        for (daysAgo, url) in urls {
            let exists = FileManager.default.fileExists(atPath: url.path)
            #expect(exists == (daysAgo != 100), "daysAgo \(daysAgo)")
        }
    }

    @Test("byteSize sums the base file and any sidecars a snapshot carries")
    func byteSizeSumsSidecars() throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        try FileManager.default.createDirectory(
            at: manager.directory, withIntermediateDirectories: true)
        let url = SnapshotFile.makeURL(
            in: manager.directory, reason: .preMigration, date: now, id: "abcd1234")
        try Data(repeating: 1, count: 10).write(to: url)
        try Data(repeating: 1, count: 6)
            .write(to: URL(fileURLWithPath: url.path + "-wal"))

        let snapshot = try #require(SnapshotFile(url: url))
        #expect(manager.byteSize(of: snapshot) == 16)
    }

    // MARK: - Failure paths (008 review, 9A)

    /// A temp library dir with a real live DB (one "Live" collection), a
    /// snapshots dir, and a helper to write the restore marker verbatim.
    private func makeRestoreFixture() async throws -> (
        dbDir: URL, dbURL: URL, snapDir: URL, writeMarker: (String) throws -> Void
    ) {
        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-fail-\(UUID().uuidString)", isDirectory: true)
        let snapDir = dbDir.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let dbURL = dbDir.appendingPathComponent("library.sqlite")
        do {
            let services = try AppServices(databasePath: dbURL.path)
            _ = try await services.createCollection(name: "Live")
        } // pool closes with the scope
        let marker = snapDir.appendingPathComponent(".pending-restore")
        return (dbDir, dbURL, snapDir, { text in
            try text.write(to: marker, atomically: true, encoding: .utf8)
        })
    }

    /// The live DB still opens and contains the fixture's "Live" collection
    /// (alongside the migration-seeded ones, e.g. Unsorted).
    private func expectLiveUntouched(_ dbURL: URL) async throws {
        let services = try AppServices(databasePath: dbURL.path)
        let names = try await services.listCollections().map(\.name)
        #expect(names.contains("Live"))
    }

    private func markerExists(in snapDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapDir.appendingPathComponent(".pending-restore").path)
    }

    private func justRestoredExists(in snapDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapDir.appendingPathComponent(".just-restored").path)
    }

    @Test("a whitespace-only marker is cleared and the live DB is untouched")
    func emptyMarker() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        try writeMarker("  \n")

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        #expect(!markerExists(in: snapDir))
        #expect(!justRestoredExists(in: snapDir)) // no restore → no announcement
        try await expectLiveUntouched(dbURL)
    }

    @Test("a dangling marker (snapshot deleted) is cleared; live DB untouched")
    func danglingMarker() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        try writeMarker("manual-20260101-000000-deadbeef.sqlite")

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        #expect(!markerExists(in: snapDir))
        try await expectLiveUntouched(dbURL)
    }

    @Test("a marker naming an unhealthy snapshot is refused; live DB untouched")
    func unhealthyMarker() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let garbageName = "manual-20260101-000000-deadbeef.sqlite"
        try Data("not a database".utf8).write(
            to: snapDir.appendingPathComponent(garbageName))
        try writeMarker(garbageName)

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        #expect(!markerExists(in: snapDir))
        try await expectLiveUntouched(dbURL)
    }

    @Test("stageRestore throws .unhealthySnapshot for a corrupt file and writes no marker")
    func stageRefusesCorrupt() async throws {
        let (dbDir, dbURL, snapDir, _) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let garbage = snapDir.appendingPathComponent("manual-20260101-000000-deadbeef.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        let snapshot = try #require(SnapshotFile(url: garbage))

        let services = try AppServices(databasePath: dbURL.path)
        let manager = SnapshotManager(services: services, directory: snapDir)
        #expect(throws: SnapshotError.unhealthySnapshot) {
            try manager.stageRestore(snapshot)
        }
        #expect(!markerExists(in: snapDir))
    }

    @Test("restore over a corrupt live DB installs the snapshot, corrupt file kept aside")
    func restoreOverCorruptLive() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        // Take a healthy snapshot of the live DB, then truncate the live DB —
        // the exact state a crashed install used to leave behind.
        let snapURL: URL
        do {
            let services = try AppServices(databasePath: dbURL.path)
            let manager = SnapshotManager(services: services, directory: snapDir)
            snapURL = try await manager.snapshot(reason: .manual)
        }
        SQLiteFileSet(base: dbURL).remove()
        try Data("truncated garbage".utf8).write(to: dbURL)
        try writeMarker(snapURL.lastPathComponent)

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        #expect(!markerExists(in: snapDir))
        try await expectLiveUntouched(dbURL) // snapshot content = "Live"
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dbDir.path)) ?? []
        #expect(aside.contains { $0.hasPrefix("library.corrupt-") })
    }

    @Test("restore with no live DB at all (crash resume) still installs the snapshot")
    func restoreWithoutLiveDB() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let snapURL: URL
        do {
            let services = try AppServices(databasePath: dbURL.path)
            let manager = SnapshotManager(services: services, directory: snapDir)
            snapURL = try await manager.snapshot(reason: .manual)
        }
        SQLiteFileSet(base: dbURL).remove() // crashed after set-aside, before install
        try writeMarker(snapURL.lastPathComponent)

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        #expect(!markerExists(in: snapDir))
        try await expectLiveUntouched(dbURL)
    }

    @Test("install failure (unwritable library dir) leaves live DB + marker cleared, no litter")
    func installFailureRollsBack() async throws {
        let (dbDir, dbURL, snapDir, writeMarker) = try await makeRestoreFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
            try? FileManager.default.removeItem(at: dbDir)
        }
        let snapURL: URL
        do {
            let services = try AppServices(databasePath: dbURL.path)
            let manager = SnapshotManager(services: services, directory: snapDir)
            snapURL = try await manager.snapshot(reason: .manual)
        }
        try writeMarker(snapURL.lastPathComponent)
        // The library dir refuses new files → the staging copy fails before the
        // live set is ever touched.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dbDir.path)

        SnapshotManager.applyPendingRestore(snapshotsDir: snapDir, livePath: dbURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
        #expect(!markerExists(in: snapDir))
        #expect(!justRestoredExists(in: snapDir)) // failed restore never announces
        try await expectLiveUntouched(dbURL)
        let litter = (try? FileManager.default.contentsOfDirectory(atPath: dbDir.path)) ?? []
        #expect(!litter.contains { $0.hasPrefix(".restore-staging-") })
        #expect(!litter.contains { $0.hasPrefix("library.corrupt-") })
    }

    @Test("PostRestoreBlobReport counts both divergence directions")
    func postRestoreReport() {
        let report = PostRestoreBlobReport(
            referenced: ["a", "b", "c"], onDisk: ["b", "c", "d", "e"])
        #expect(report.missingReferenced == 1) // "a" vanished after the snapshot
        #expect(report.keptUnreferenced == 2)  // "d"/"e" captured after it
        #expect(!report.isClean)

        #expect(PostRestoreBlobReport(referenced: [], onDisk: []).isClean)
        #expect(PostRestoreBlobReport(referenced: ["x"], onDisk: ["x"]).isClean)
    }
}
