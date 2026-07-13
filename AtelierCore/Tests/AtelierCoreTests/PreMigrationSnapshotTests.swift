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
