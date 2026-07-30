// AtelierCore — SQLiteFileSet tests (008): the {db, -wal, -shm} trio moves,
// copies, sizes, and removes as one unit; the base file is strict, sidecars
// travel iff present, removal is best-effort.

import Foundation
import Testing
@testable import AtelierCore

@Suite("SQLiteFileSet")
struct SQLiteFileSetTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteFileSetTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a fake set: the base file plus the given sidecar suffixes.
    private func plant(
        _ dir: URL, name: String, sidecars: [String], bytes: Int = 4
    ) throws -> SQLiteFileSet {
        let base = dir.appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: base)
        for suffix in sidecars {
            try data.write(to: URL(fileURLWithPath: base.path + suffix))
        }
        return SQLiteFileSet(base: base)
    }

    private func onDisk(_ set: SQLiteFileSet) -> Set<String> {
        var present: Set<String> = []
        for suffix in [""] + SQLiteFileSet.sidecarSuffixes
        where FileManager.default.fileExists(atPath: set.base.path + suffix) {
            present.insert(suffix.isEmpty ? "base" : suffix)
        }
        return present
    }

    @Test("copy brings the base and every present sidecar; absent sidecars are skipped")
    func copyFullAndPartial() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let full = try plant(dir, name: "full.sqlite", sidecars: ["-wal", "-shm"])
        let fullDest = SQLiteFileSet(base: dir.appendingPathComponent("full-copy.sqlite"))
        try full.copy(to: fullDest)
        #expect(onDisk(fullDest) == ["base", "-wal", "-shm"])
        #expect(onDisk(full) == ["base", "-wal", "-shm"]) // source untouched

        let bare = try plant(dir, name: "bare.sqlite", sidecars: [])
        let bareDest = SQLiteFileSet(base: dir.appendingPathComponent("bare-copy.sqlite"))
        try bare.copy(to: bareDest)
        #expect(onDisk(bareDest) == ["base"])
    }

    @Test("copy of a missing base throws; nothing is created")
    func copyMissingBaseThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ghost = SQLiteFileSet(base: dir.appendingPathComponent("ghost.sqlite"))
        let dest = SQLiteFileSet(base: dir.appendingPathComponent("dest.sqlite"))
        #expect(throws: (any Error).self) { try ghost.copy(to: dest) }
        #expect(onDisk(dest).isEmpty)
    }

    @Test("move relocates every member and leaves the source empty")
    func moveRelocates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let set = try plant(dir, name: "a.sqlite", sidecars: ["-wal"])
        let dest = SQLiteFileSet(base: dir.appendingPathComponent("b.sqlite"))
        try set.move(to: dest)
        #expect(onDisk(set).isEmpty)
        #expect(onDisk(dest) == ["base", "-wal"])
    }

    @Test("remove is best-effort: clears what exists, ignores what doesn't")
    func removeBestEffort() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let set = try plant(dir, name: "a.sqlite", sidecars: ["-shm"])
        set.remove()
        #expect(onDisk(set).isEmpty)
        set.remove() // second remove of nothing: no throw, no effect
        #expect(!set.exists)
    }

    @Test("totalByteSize sums base + present sidecars; 0 when nothing exists")
    func byteSizeSums() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let set = try plant(dir, name: "a.sqlite", sidecars: ["-wal", "-shm"], bytes: 10)
        #expect(set.totalByteSize() == 30)
        let ghost = SQLiteFileSet(base: dir.appendingPathComponent("ghost.sqlite"))
        #expect(ghost.totalByteSize() == 0)
    }
}
