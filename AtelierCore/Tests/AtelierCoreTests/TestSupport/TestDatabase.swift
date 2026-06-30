// AtelierCore — shared test store helper (chunk 4, decision T9)
//
// One place that builds an isolated, migrated, temp-file `DatabasePool` per
// test (real WAL, faithful to production A3 — an in-memory `DatabaseQueue`
// would not exercise the pool). Each call gets a UNIQUE temp directory; the
// caller `defer`s `cleanup()` to delete it.

import Foundation
import Testing
@testable import AtelierCore

/// A migrated temp-file store plus its owning directory, so a test can tear it
/// down. The whole directory is removed (the `.sqlite` file plus the WAL/SHM
/// sidecars a `DatabasePool` creates).
struct TempDatabase {
    let database: LibraryDatabase
    let directory: URL

    /// Delete the temp directory and everything in it. Safe to call once.
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Build a fresh, migrated `LibraryDatabase` in a unique temp directory under
/// the system temp dir. `Foundation.UUID()` is fine for test isolation.
func makeTempDatabase() throws -> TempDatabase {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierCoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("library.sqlite").path
    let database = try LibraryDatabase(path: path)
    return TempDatabase(database: database, directory: directory)
}
