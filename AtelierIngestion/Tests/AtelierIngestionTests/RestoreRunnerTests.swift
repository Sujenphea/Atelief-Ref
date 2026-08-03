// AtelierIngestion tests — restoring a library from a backup folder (008 · H5c).
//
// The test the feature exists for is `roundTripRestoresRowsAndBytes`: back up
// library A, restore into a DIFFERENT library B, and assert the row counts and
// the blob bytes match. Everything else here guards the ways that can go wrong
// quietly — a half-copied database that looks restorable, a cancelled run that
// looks like a failure, a backup found under the wrong library's id.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("RestoreRunner (008 H5c)")
struct RestoreRunnerTests {

    /// A source library, a backup target, and a SECOND (empty) library to
    /// restore into — the "my Mac died" shape, not a self-restore.
    private struct Fixture {
        let origin: TempPipeline
        let target: URL
        let originLayout: BackupLayout
        /// The replacement library: its own blob store and snapshots directory.
        let liveRoot: URL

        var live: MediaStore { MediaStore(root: liveRoot) }
        var snapshots: URL { LibraryLayout(root: liveRoot).snapshots }

        func cleanup() {
            origin.cleanup()
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: liveRoot)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let origin = try await makeTempPipeline()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierRestoreRunnerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let liveRoot = root.appendingPathComponent("replacement", isDirectory: true)
        for directory in [target, liveRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return Fixture(
            origin: origin, target: target,
            originLayout: BackupLayout(target: target, libraryID: "00aa11bb22cc33dd"),
            liveRoot: liveRoot)
    }

    @discardableResult
    private func seed(
        _ fixture: Fixture, hash: String, bytes: String, mime: String = "image/png"
    ) async throws -> UUID {
        try fixture.origin.store.storeBlob(
            Data(bytes.utf8), hash: hash,
            fileExtension: ImageMetadata.fileExtension(forMIMEType: mime))
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: mime,
            width: 10, height: 10, duration: nil, fileSize: bytes.utf8.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(hash)", capturedAt: Date())
        return try await fixture.origin.services
            .ingest(draft, from: source, into: fixture.origin.collectionID).asset.id
    }

    /// Run a full backup of the origin library into the target.
    @discardableResult
    private func backUp(_ fixture: Fixture) async throws -> BackupRunResult {
        try await BackupRunner(
            services: fixture.origin.services, source: fixture.origin.store,
            layout: fixture.originLayout, appVersion: "1.0-test").run()
    }

    /// The one backup the target holds.
    private func source(_ fixture: Fixture) throws -> BackupSource {
        try #require(BackupCatalog.sources(in: fixture.target).first)
    }

    private func runner(_ fixture: Fixture, source: BackupSource) -> RestoreRunner {
        RestoreRunner(
            source: source, live: fixture.live, snapshotsDirectory: fixture.snapshots)
    }

    // MARK: - The round trip

    @Test("A → folder → B restores every row and every blob byte")
    func roundTripRestoresRowsAndBytes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let payloads = ["aaaa1111": "one", "bbbb2222": "two", "cccc3333": "three"]
        for (hash, bytes) in payloads.sorted(by: { $0.key < $1.key }) {
            try await seed(fixture, hash: hash, bytes: bytes)
        }
        try await backUp(fixture)

        let result = try await runner(fixture, source: try source(fixture)).run()
        #expect(result.isComplete)
        let snapshot = try #require(result.snapshot)

        // The restored DATABASE: same rows, reachable through a real open of the
        // file the restore seam would install.
        let restored = try AppServices(databasePath: snapshot.path)
        let originalBlobs = try await fixture.origin.services.referencedBlobs()
        let restoredBlobs = try await restored.referencedBlobs()
        #expect(restoredBlobs.map(\.blobHash).sorted() == originalBlobs.map(\.blobHash).sorted())
        #expect(restoredBlobs.count == payloads.count)
        let collections = try await restored.listCollections()
        let originalCollections = try await fixture.origin.services.listCollections()
        #expect(collections.count == originalCollections.count)

        // The restored BYTES: not merely present — identical.
        for (hash, bytes) in payloads {
            let landed = try fixture.live.readBlob(hash: hash, fileExtension: "png")
            #expect(String(decoding: landed, as: UTF8.self) == bytes)
        }
        #expect(fixture.live.enumerateBlobFiles().count == payloads.count)
    }

    @Test("the restored database is a parseable snapshot the shipped seam accepts")
    func restoredDatabaseIsAValidSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)

        let result = try await runner(fixture, source: try source(fixture)).run(
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = try #require(result.snapshot)

        // `SnapshotManager` finds snapshots by PARSING filenames; a name it
        // can't parse would be invisible and the restore would never apply.
        let parsed = try #require(SnapshotFile(url: snapshot))
        #expect(parsed.reason == .manual)
        #expect(parsed.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try AppServices.isHealthy(databaseFileAt: snapshot))
    }

    @Test("an empty backup restores an empty, healthy library")
    func emptyBackupRestores() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await backUp(fixture)

        let result = try await runner(fixture, source: try source(fixture)).run()
        #expect(result.copy.copied == 0)
        #expect(result.isComplete)
        #expect(try AppServices.isHealthy(databaseFileAt: try #require(result.snapshot)))
    }

    // MARK: - Idempotence and resumption

    @Test("blobs already in the live library are not re-copied")
    func alreadyPresentBlobsAreSkipped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await seed(fixture, hash: "bbbb2222", bytes: "two")
        try await backUp(fixture)
        try fixture.live.storeBlob(Data("one".utf8), hash: "aaaa1111", fileExtension: "png")

        let result = try await runner(fixture, source: try source(fixture)).run()
        // Content-addressed, so "already there" means "already correct" — the
        // property that makes a restore safe to run while the app is open.
        #expect(result.copy.copied == 1)
        #expect(result.isComplete)
    }

    @Test("an interrupted restore leaves no partial file and resumes cleanly")
    func interruptedRestoreResumes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        for index in 0 ..< 6 {
            try await seed(
                fixture, hash: String(format: "%08x", 0xAAA0_0000 + index),
                bytes: "payload-\(index)")
        }
        try await backUp(fixture)
        let backup = try source(fixture)

        let counter = RestoreCounter()
        let stopped = try await runner(fixture, source: backup).run(
            maxConcurrent: 1, isCancelled: { counter.bump() > 2 })
        #expect(stopped.cancelled)
        #expect(stopped.copy.copied == 2)
        // Nothing staged: a cancelled restore must leave the live library
        // exactly as it was, so no snapshot file may exist to be restored from.
        #expect(stopped.snapshot == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(
            atPath: fixture.snapshots.path)) ?? []).isEmpty)
        // Every file that landed is whole — nothing half-written at a
        // content-addressed path for the resume to mistake for done.
        for file in fixture.live.enumerateBlobFiles() {
            let bytes = try fixture.live.readBlob(
                hash: file.hash, fileExtension: file.fileExtension)
            #expect(String(decoding: bytes, as: UTF8.self).hasPrefix("payload-"))
        }
        // No staging litter at the live library either.
        let cache = (try? FileManager.default.contentsOfDirectory(
            at: LibraryLayout(root: fixture.liveRoot).cache,
            includingPropertiesForKeys: nil)) ?? []
        #expect(cache.isEmpty)

        let finished = try await runner(fixture, source: backup).run()
        #expect(finished.copy.copied == 4)
        #expect(finished.isComplete)
        #expect(fixture.live.enumerateBlobFiles().count == 6)
    }

    @Test("cancelling before the database step stages nothing at all")
    func cancelStagesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)

        let result = try await runner(fixture, source: try source(fixture)).run(
            isCancelled: { true })
        #expect(result.cancelled)
        #expect(result.snapshot == nil)
        #expect(!result.isComplete)
        #expect(fixture.live.enumerateBlobFiles().isEmpty)
    }

    // MARK: - Refusals

    @Test("a corrupt backup database is refused and nothing is staged")
    func corruptDatabaseIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)
        let backup = try source(fixture)
        // What a destination that filled up mid-copy leaves.
        try Data("this is not a database".utf8)
            .write(to: backup.layout.database)

        await #expect(throws: RestoreRunner.RestoreError.databaseUnhealthy) {
            try await runner(fixture, source: backup).run()
        }
        // The blobs still landed — they are content-addressed and harmless —
        // but there is nothing in `snapshots/` to restore from, which is the
        // guarantee that matters.
        let staged = (try? FileManager.default.contentsOfDirectory(
            atPath: fixture.snapshots.path)) ?? []
        #expect(staged.isEmpty)
    }

    @Test("a backup with no database is refused before anything is copied")
    func missingDatabaseIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)
        let backup = try source(fixture)
        try FileManager.default.removeItem(at: backup.layout.database)

        await #expect(throws: RestoreRunner.RestoreError.databaseMissing) {
            try await runner(fixture, source: backup).run()
        }
        #expect(fixture.live.enumerateBlobFiles().isEmpty)
    }

    @Test("a backup from a newer schema is refused, not half-applied")
    func newerSchemaIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)
        let backup = try source(fixture)

        let runner = RestoreRunner(
            source: backup, live: fixture.live,
            snapshotsDirectory: fixture.snapshots, schemaVersion: "v2")
        await #expect(throws: RestoreRunner.RestoreError.schemaTooNew(
            AppServices.schemaVersion)) {
            try await runner.run()
        }
        // Refused BEFORE the copy: nothing at all happened.
        #expect(fixture.live.enumerateBlobFiles().isEmpty)
    }

    @Test("the version rules refuse only what is genuinely newer")
    func refusalMatrix() throws {
        func manifest(_ manifestVersion: Int, _ schema: String) -> BackupManifest {
            BackupManifest(
                manifestVersion: manifestVersion, schemaVersion: schema,
                appVersion: "1.0", libraryID: "00aa11bb22cc33dd", completedAt: Date(),
                blobCount: 0, blobBytes: 0, databaseBytes: 0)
        }
        #expect(RestoreRunner.refusal(
            for: manifest(1, "v18"), schemaVersion: "v18") == nil)
        #expect(RestoreRunner.refusal(
            for: manifest(1, "v17"), schemaVersion: "v18") == nil)
        #expect(RestoreRunner.refusal(
            for: manifest(1, "v19"), schemaVersion: "v18") == .schemaTooNew("v19"))
        #expect(RestoreRunner.refusal(
            for: manifest(2, "v18"), schemaVersion: "v18") == .manifestTooNew)
        // "I can't tell" is not evidence of "newer than me": an unparseable
        // version must not brick the one feature people reach for last.
        #expect(RestoreRunner.refusal(
            for: manifest(1, "weird"), schemaVersion: "v18") == nil)
        #expect(RestoreRunner.refusal(
            for: manifest(1, "v19"), schemaVersion: "weird") == nil)
    }

    @Test("an unwritable snapshots directory fails before the copy")
    func unwritableSnapshotsIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)
        // A FILE where `snapshots/` needs to be.
        try Data("blocker".utf8).write(to: fixture.snapshots)

        await #expect(throws: RestoreRunner.RestoreError.snapshotsUnwritable) {
            try await runner(fixture, source: try source(fixture)).run()
        }
    }

    // MARK: - Deletes still do not propagate

    @Test("restore copies blobs the live library never had, and removes none")
    func restoreNeitherPrunesNorSkips() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let id = try await seed(fixture, hash: "aaaa1111", bytes: "one")
        try await backUp(fixture)
        // Deleted after the backup: the blob STAYS in the backup (H5a's rule),
        // so a restore brings it back — which is the case people restore for.
        try await fixture.origin.services.deleteAssets([id])
        try await backUp(fixture)
        // Something the live library has and the backup has never seen.
        try fixture.live.storeBlob(Data("newer".utf8), hash: "dddd4444", fileExtension: "png")

        let result = try await runner(fixture, source: try source(fixture)).run()
        #expect(result.isComplete)
        #expect(fixture.live.hasBlob(hash: "aaaa1111", fileExtension: "png"))
        // Restore adds; it never removes. Pruning here would delete media
        // captured since the backup was taken.
        #expect(fixture.live.hasBlob(hash: "dddd4444", fileExtension: "png"))
    }

    // MARK: - Progress

    @Test("progress runs 1…N over the files this restore has to copy")
    func progressCoversTheDiffOnly() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        for index in 0 ..< 3 {
            try await seed(
                fixture, hash: String(format: "%08x", 0xBBB0_0000 + index), bytes: "b\(index)")
        }
        try await backUp(fixture)
        try fixture.live.storeBlob(
            Data("b0".utf8), hash: String(format: "%08x", 0xBBB0_0000), fileExtension: "png")

        let recorder = RestoreProgress()
        try await runner(fixture, source: try source(fixture)).run(
            onProgress: { done, total in recorder.record(done, total) })

        #expect(recorder.pairs == [(1, 2), (2, 2)].map { RestorePair(done: $0.0, total: $0.1) })
    }
}

// MARK: - Catalog

@Suite("BackupCatalog (008 H5c)")
struct BackupCatalogTests {

    private func makeTarget() throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBackupCatalogTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Write a plausible backup directory: a database file and a manifest.
    private func writeBackup(
        in target: URL, id: String, at date: Date, database: Bool = true, manifest: Bool = true
    ) throws {
        let layout = BackupLayout(target: target, libraryID: id)
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        if database { try Data("db".utf8).write(to: layout.database) }
        if manifest {
            try BackupManifest(
                schemaVersion: "v18", appVersion: "1.0", libraryID: id, completedAt: date,
                blobCount: 0, blobBytes: 0, databaseBytes: 2).write(to: layout.manifest)
        }
    }

    @Test("a backup is found under the BACKUP's id, not the restoring library's")
    func findsBackupsByTheirOwnID() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date())

        // The restoring library's id is irrelevant — the "my Mac died" case has
        // a brand-new library whose id has never appeared in this folder.
        let sources = BackupCatalog.sources(in: target)
        #expect(sources.map(\.libraryID) == ["00aa11bb22cc33dd"])
        #expect(sources.first?.manifest.libraryID == "00aa11bb22cc33dd")
    }

    @Test("several libraries in one folder are all listed, newest first")
    func listsAllBackupsNewestFirst() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date(timeIntervalSince1970: 100))
        try writeBackup(in: target, id: "11bb22cc33dd44ee", at: Date(timeIntervalSince1970: 900))

        #expect(BackupCatalog.sources(in: target).map(\.libraryID)
            == ["11bb22cc33dd44ee", "00aa11bb22cc33dd"])
    }

    @Test("a directory with no manifest is NOT offered — that run never finished")
    func incompleteBackupIsNotOffered() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date(), manifest: false)

        // The manifest is a backup run's commit record. Without it, an unknown
        // fraction of a library would be offered as though it were the whole.
        #expect(BackupCatalog.sources(in: target).isEmpty)
    }

    @Test("a manifest with no database is NOT offered")
    func manifestWithoutDatabaseIsNotOffered() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date(), database: false)
        #expect(BackupCatalog.sources(in: target).isEmpty)
    }

    @Test("directories that aren't identity-named are ignored")
    func strayDirectoriesAreIgnored() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date())
        // Someone else's folder living in the same backup drive.
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("Family Photos"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("readme.txt"))

        #expect(BackupCatalog.sources(in: target).map(\.libraryID) == ["00aa11bb22cc33dd"])
    }

    @Test("an unparseable manifest is skipped rather than failing the whole scan")
    func unparseableManifestIsSkipped() throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target) }
        try writeBackup(in: target, id: "00aa11bb22cc33dd", at: Date())
        try writeBackup(in: target, id: "11bb22cc33dd44ee", at: Date())
        try Data("{ truncated".utf8).write(
            to: BackupLayout(target: target, libraryID: "11bb22cc33dd44ee").manifest)

        // One bad neighbour must not hide a good backup.
        #expect(BackupCatalog.sources(in: target).map(\.libraryID) == ["00aa11bb22cc33dd"])
    }

    @Test("a folder that doesn't exist reads as no backups, not a crash")
    func missingTargetIsEmpty() throws {
        let target = try makeTarget()
        try FileManager.default.removeItem(at: target)
        #expect(BackupCatalog.sources(in: target).isEmpty)
    }
}

// MARK: - Identity adoption

@Suite("LibraryIdentity.adopt (008 H5c)")
struct LibraryIdentityAdoptTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierAdoptTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("adopting replaces the library's id, so it keeps backing up to the same folder")
    func adoptReplacesTheID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try LibraryIdentity.resolve(root: root)
        #expect(original != "00aa11bb22cc33dd")

        try LibraryIdentity.adopt("00aa11bb22cc33dd", root: root)

        // Without this, the restored library would back up into a fresh empty
        // folder and leave the backup it came from stranded.
        #expect(try LibraryIdentity.resolve(root: root) == "00aa11bb22cc33dd")
    }

    @Test("adopting into a library with no id yet works")
    func adoptWithoutAnExistingID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try LibraryIdentity.adopt("00aa11bb22cc33dd", root: root)
        #expect(try LibraryIdentity.resolve(root: root) == "00aa11bb22cc33dd")
    }

    @Test("a malformed id is refused — it becomes a path component")
    func adoptRefusesMalformed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try LibraryIdentity.resolve(root: root)

        #expect(throws: LibraryIdentity.IdentityError.malformed("../escape")) {
            try LibraryIdentity.adopt("../escape", root: root)
        }
        #expect(try LibraryIdentity.resolve(root: root) == original)
    }
}

// MARK: - Test doubles

/// A thread-safe counter for tripping cancellation after N reads.
private final class RestoreCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private struct RestorePair: Equatable {
    let done: Int
    let total: Int
}

/// Records progress callbacks in order.
private final class RestoreProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RestorePair] = []

    func record(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(RestorePair(done: done, total: total))
    }

    var pairs: [RestorePair] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
