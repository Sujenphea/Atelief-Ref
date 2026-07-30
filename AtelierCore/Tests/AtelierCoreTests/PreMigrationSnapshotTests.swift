// AtelierCore — pre-migration snapshot tests (008 H3)
//
// Opening a library whose on-disk schema is behind takes a `pre-migration-…`
// snapshot before migrating; opening an already-current library takes none.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("LibraryDatabase: pre-migration snapshot")
struct PreMigrationSnapshotTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreMigTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func preMigrationSnapshots(in dir: URL) -> [String] {
        let snapDir = dir.appendingPathComponent("snapshots")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapDir.path)) ?? []
        return names.filter { $0.hasPrefix("pre-migration-") && $0.hasSuffix(".sqlite") }
    }

    @Test("a behind-schema open snapshots first; an up-to-date open does not")
    func snapshotsOnVersionBump() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("library.sqlite").path

        // Create a DB migrated only up to v3 (v4 pending), then close it.
        do {
            let pool = try DatabasePool(path: path)
            try Migrator.makeMigrator().migrate(pool, upTo: "v3")
        }

        // Opening through LibraryDatabase sees v4 pending → snapshots, then migrates.
        let db = try LibraryDatabase(path: path)
        #expect(preMigrationSnapshots(in: dir).count == 1)

        // The snapshot itself is a healthy, openable database.
        let snapDir = dir.appendingPathComponent("snapshots")
        let snapshot = snapDir.appendingPathComponent(preMigrationSnapshots(in: dir)[0])
        #expect(try AppServices.isHealthy(databaseFileAt: snapshot))

        // Re-opening the now-current library adds no further pre-migration snapshot.
        _ = db
        let db2 = try LibraryDatabase(path: path)
        _ = db2
        #expect(preMigrationSnapshots(in: dir).count == 1)
    }

    @Test("an unclean-close library (live -wal) yields a self-contained, healthy snapshot")
    func uncleanWALSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let liveURL = dir.appendingPathComponent("library.sqlite")

        // Build a v3 library whose latest committed rows live ONLY in the -wal:
        // autocheckpoint off, write, then copy the whole file set aside while the
        // pool is still open — the copy is exactly what an unclean exit leaves
        // behind (main file without the newest rows, live -wal, stale -shm).
        let workURL = dir.appendingPathComponent("work.sqlite")
        do {
            let pool = try DatabasePool(path: workURL.path)
            try Migrator.makeMigrator().migrate(pool, upTo: "v3")
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
                try db.execute(sql: "CREATE TABLE wal_probe(x TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO wal_probe VALUES ('committed-in-wal')")
            }
            for sidecar in ["", "-wal", "-shm"] {
                try FileManager.default.copyItem(
                    atPath: workURL.path + sidecar, toPath: liveURL.path + sidecar)
            }
        }
        #expect(FileManager.default.fileExists(atPath: liveURL.path + "-wal"))

        // Opening through LibraryDatabase stages + promotes a pre-migration snapshot.
        let db = try LibraryDatabase(path: liveURL.path)
        _ = db
        let names = preMigrationSnapshots(in: dir)
        #expect(names.count == 1)
        let snapshot = dir.appendingPathComponent("snapshots")
            .appendingPathComponent(names[0])

        // The snapshot is ONE self-contained file — no sidecars…
        #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-shm"))
        // …that passes the read-only health check (a read-only open must not need
        // WAL recovery — the exact failure a raw file-copy snapshot hits)…
        #expect(try AppServices.isHealthy(databaseFileAt: snapshot))
        // …and contains the rows that were only in the WAL at copy time.
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: snapshot.path, configuration: config)
        let probe = try queue.read { try String.fetchAll($0, sql: "SELECT x FROM wal_probe") }
        #expect(probe == ["committed-in-wal"])
    }

    @Test("a fresh library (first open) takes no pre-migration snapshot")
    func noSnapshotOnFirstOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("library.sqlite").path

        let db = try LibraryDatabase(path: path)
        _ = db
        #expect(preMigrationSnapshots(in: dir).isEmpty)
    }
}
