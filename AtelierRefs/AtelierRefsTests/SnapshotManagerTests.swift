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

        let deleted = Set(SnapshotRetention().prunable(snapshots).map(\.url))

        // Kept: the 7 recent, the 4 newest-per-week older ones (10/20/30/40),
        // and the pre-migration snapshot. Pruned: the 5th/6th older weeks.
        #expect(deleted == Set([snap(.daily, daysAgo: 50, "w50").url,
                                snap(.daily, daysAgo: 60, "w60").url]))
        #expect(!deleted.contains(snap(.preMigration, daysAgo: 100, "pm").url))
    }

    @Test("pre-migration snapshots are exempt even when they are the oldest many")
    func preMigrationExempt() {
        let snapshots = (0..<20).map { snap(.preMigration, daysAgo: $0 * 7, "pm\($0)") }
        #expect(SnapshotRetention().prunable(snapshots).isEmpty)
    }

    private func makeManager() throws -> (SnapshotManager, cleanup: () -> Void) {
        let dbPath = NSTemporaryDirectory() + "snapmgr-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let snapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snaps-\(UUID().uuidString)", isDirectory: true)
        let manager = SnapshotManager(services: services, directory: snapDir)
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
        #expect(aside.contains { $0.hasPrefix("library.corrupt-") })
    }
}
