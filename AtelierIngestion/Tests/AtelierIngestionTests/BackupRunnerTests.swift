// AtelierIngestion tests — one backup run, end to end (008 · H5).
//
// The ordering claims in `BackupRunner`'s header are what these pin: blobs
// before the database, the database verified before it replaces the previous
// copy, the manifest written last as the run's commit record. Every "what if it
// dies here" question has a test, because the answer is the feature.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("BackupRunner (008 H5)")
struct BackupRunnerTests {

    /// A live library (real SQLite + blob store) and a backup target beside it.
    private struct Fixture {
        let pipeline: TempPipeline
        let target: URL
        let layout: BackupLayout

        var services: AppServices { pipeline.services }
        var store: MediaStore { pipeline.store }

        var runner: BackupRunner {
            BackupRunner(
                services: services, source: store, layout: layout, appVersion: "1.0-test")
        }

        func cleanup() {
            pipeline.cleanup()
            try? FileManager.default.removeItem(at: target)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let pipeline = try await makeTempPipeline()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBackupRunnerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return Fixture(
            pipeline: pipeline, target: target,
            layout: BackupLayout(target: target, libraryID: "0123456789abcdef"))
    }

    /// Add one asset to the library AND write its blob bytes, so the row and the
    /// file agree — the normal state a backup copies.
    @discardableResult
    private func seed(
        _ fixture: Fixture, hash: String, bytes: String, mime: String = "image/png"
    ) async throws -> UUID {
        try fixture.store.storeBlob(Data(bytes.utf8), hash: hash,
                                    fileExtension: ImageMetadata.fileExtension(forMIMEType: mime))
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: mime,
            width: 10, height: 10, duration: nil, fileSize: bytes.utf8.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(hash)", capturedAt: Date())
        return try await fixture.services
            .ingest(draft, from: source, into: fixture.pipeline.collectionID).asset.id
    }

    // MARK: - A full run

    @Test("a first run copies every blob, the database, and a manifest")
    func firstRunCopiesEverything() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await seed(fixture, hash: "bbbb2222", bytes: "two")

        let result = try await fixture.runner.run(now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(result.copy.copied == 2)
        #expect(result.isComplete)
        #expect(fixture.layout.store.hasBlob(hash: "aaaa1111", fileExtension: "png"))
        #expect(fixture.layout.store.hasBlob(hash: "bbbb2222", fileExtension: "png"))
        #expect(FileManager.default.fileExists(atPath: fixture.layout.database.path))

        let manifest = try BackupManifest.read(from: fixture.layout.manifest)
        #expect(manifest == result.manifest)
        #expect(manifest.libraryID == "0123456789abcdef")
        #expect(manifest.schemaVersion == AppServices.schemaVersion)
        #expect(manifest.appVersion == "1.0-test")
        #expect(manifest.completedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("the copied database is intact and holds the same assets")
    func databaseCopyIsUsable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await seed(fixture, hash: "bbbb2222", bytes: "two")

        try await fixture.runner.run()

        // The whole point of `VACUUM INTO`: a single self-contained file with no
        // `-wal` sidecar, openable on its own.
        #expect(try AppServices.isHealthy(databaseFileAt: fixture.layout.database))
        let restored = try AppServices(databasePath: fixture.layout.database.path)
        let blobs = try await restored.referencedBlobs().map(\.blobHash).sorted()
        #expect(blobs == ["aaaa1111", "bbbb2222"])
    }

    @Test("the manifest counts what the DESTINATION holds, not what this run copied")
    func manifestReportsDestinationTotals() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await fixture.runner.run()

        try await seed(fixture, hash: "bbbb2222", bytes: "twelve")
        let second = try await fixture.runner.run()

        #expect(second.copy.copied == 1)
        // 2 files total, though this run moved one — the number describes the
        // backup, which is what someone reading it wants to know.
        #expect(second.manifest?.blobCount == 2)
        #expect(second.manifest?.blobBytes == Int64("one".utf8.count + "twelve".utf8.count))
        #expect((second.manifest?.databaseBytes ?? 0) > 0)
    }

    // MARK: - Incremental

    @Test("a second run with no changes copies nothing")
    func secondRunIsANoop() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await fixture.runner.run()

        let second = try await fixture.runner.run()
        #expect(second.copy.copied == 0)
        #expect(second.copy.alreadyPresent == 0)   // filtered out by the diff
        #expect(second.isComplete)
        // The database is refreshed every run regardless — it is the cheap part
        // and it is what makes the blob tree meaningful.
        #expect(try AppServices.isHealthy(databaseFileAt: fixture.layout.database))
    }

    @Test("a run copies only what is new since the last one")
    func incrementalRunCopiesOnlyNew() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await fixture.runner.run()

        try await seed(fixture, hash: "bbbb2222", bytes: "two")
        let second = try await fixture.runner.run()

        #expect(second.copy.copied == 1)
        #expect(second.copy.bytesCopied == Int64("two".utf8.count))
    }

    @Test("blobs deleted from the library STAY in the backup")
    func deletesDoNotPropagate() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let id = try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await fixture.runner.run()

        try await fixture.services.deleteAssets([id])
        let second = try await fixture.runner.run()

        #expect(second.isComplete)
        // A backup that mirrors deletions is not a backup — the accidental
        // delete is exactly the case someone restores from.
        #expect(fixture.layout.store.hasBlob(hash: "aaaa1111", fileExtension: "png"))
        #expect(second.manifest?.blobCount == 1)
    }

    @Test("an empty library still produces a valid, restorable destination")
    func emptyLibraryRuns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.runner.run()
        #expect(result.copy.copied == 0)
        #expect(result.isComplete)
        #expect(try AppServices.isHealthy(databaseFileAt: fixture.layout.database))
        #expect(result.manifest?.blobCount == 0)
        #expect(result.manifest?.blobBytes == 0)
    }

    // MARK: - Partial failure

    @Test("a referenced blob with no file is reported without failing the run")
    func missingSourceFileDoesNotFailTheRun() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        // A row whose bytes are gone from disk.
        let draft = AssetDraft(
            kind: .image, blobHash: "cccc3333", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 3,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/ghost", capturedAt: Date())
        _ = try await fixture.services.ingest(
            draft, from: source, into: fixture.pipeline.collectionID)

        let result = try await fixture.runner.run()

        #expect(result.copy.missingAtSource == ["cccc3333"])
        #expect(!result.isComplete)
        // The run still finished: the database and manifest are there, so the
        // backup is usable — it just isn't whole, and it says so.
        #expect(result.manifest != nil)
        #expect(fixture.layout.store.hasBlob(hash: "aaaa1111", fileExtension: "png"))
    }

    // MARK: - Cancellation

    @Test("cancelling stops before the database and writes NO manifest")
    func cancelledRunWritesNoManifest() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")

        let result = try await fixture.runner.run(isCancelled: { true })

        #expect(result.cancelled)
        #expect(result.manifest == nil)
        // No manifest means no commit record: a reader can tell this destination
        // is mid-flight rather than finished.
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.manifest.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.database.path))
    }

    @Test("a cancelled run leaves the PREVIOUS backup fully intact")
    func cancelPreservesPreviousBackup() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        let first = try await fixture.runner.run()
        let firstManifest = try #require(first.manifest)

        try await seed(fixture, hash: "bbbb2222", bytes: "two")
        let cancelled = try await fixture.runner.run(isCancelled: { true })

        #expect(cancelled.cancelled)
        // Everything the completed run produced is untouched — the destination
        // never regresses because a later run was interrupted.
        #expect(try BackupManifest.read(from: fixture.layout.manifest) == firstManifest)
        #expect(try AppServices.isHealthy(databaseFileAt: fixture.layout.database))
        #expect(fixture.layout.store.hasBlob(hash: "aaaa1111", fileExtension: "png"))
    }

    @Test("a run resumes from a cancelled one instead of starting over")
    func runResumesAfterCancel() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        for index in 0 ..< 6 {
            try await seed(fixture, hash: String(format: "%08x", 0xAAA0_0000 + index),
                           bytes: "payload-\(index)")
        }

        let counter = RunCounter()
        let stopped = try await fixture.runner.run(
            maxConcurrent: 1, isCancelled: { counter.bump() > 2 })
        #expect(stopped.cancelled)
        #expect(stopped.copy.copied == 2)

        let finished = try await fixture.runner.run()
        #expect(finished.copy.copied == 4)   // the four that were skipped
        #expect(finished.isComplete)
        #expect(finished.manifest?.blobCount == 6)
    }

    // MARK: - Progress

    @Test("progress runs 1…N over the files this run actually has to copy")
    func progressCoversTheDiffOnly() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await fixture.runner.run()

        try await seed(fixture, hash: "bbbb2222", bytes: "two")
        try await seed(fixture, hash: "cccc3333", bytes: "three")

        let recorder = RunProgress()
        try await fixture.runner.run(onProgress: { done, total in
            recorder.record(done, total)
        })

        // Two files, not three: an incremental run's progress must reflect the
        // work left, or the bar sits at 100% before it starts.
        #expect(recorder.pairs == [(1, 2), (2, 2)].map { Pair(done: $0.0, total: $0.1) })
    }

    // MARK: - Destination failures

    @Test("an unwritable destination fails loudly rather than half-succeeding")
    func unwritableDestinationThrows() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")

        // A FILE where the library's backup root needs to be.
        try Data("blocker".utf8).write(to: fixture.layout.root)

        await #expect(throws: BackupRunner.RunError.destinationUnwritable) {
            try await fixture.runner.run()
        }
    }

    @Test("a leftover half-written database from a dead run is discarded")
    func staleIncomingDatabaseIsReplaced() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try FileManager.default.createDirectory(
            at: fixture.layout.root, withIntermediateDirectories: true)
        // What a run killed between VACUUM and rename leaves behind. `VACUUM
        // INTO` refuses an existing path, so a run that didn't clear this would
        // fail forever after one bad crash.
        try Data("garbage".utf8).write(to: fixture.layout.incomingDatabase)

        let result = try await fixture.runner.run()
        #expect(result.isComplete)
        #expect(try AppServices.isHealthy(databaseFileAt: fixture.layout.database))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.incomingDatabase.path))
    }
}

// MARK: - Test doubles

/// A thread-safe counter for tripping cancellation after N reads.
private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private struct Pair: Equatable {
    let done: Int
    let total: Int
}

/// Records progress callbacks in order.
private final class RunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Pair] = []

    func record(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Pair(done: done, total: total))
    }

    var pairs: [Pair] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
