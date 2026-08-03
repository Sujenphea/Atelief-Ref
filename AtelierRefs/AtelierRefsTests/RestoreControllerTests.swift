//
//  RestoreControllerTests.swift
//  AtelierRefsTests
//
//  008 · H5c — restoring a library from its backup folder, driven against real
//  (temp) libraries and a `DirectFolderAccess` destination, so nothing here
//  needs the sandbox or a bookmark.
//
//  The engine's own correctness is `AtelierIngestionTests`' job. What these
//  cover is the part only the app has: which outcome the user is shown, that a
//  stopped restore is never called a failure, that an unreachable drive is a
//  message rather than a crash — and the hand-off to the SHIPPED restore seam,
//  including the library identity the restored library adopts (and, just as
//  importantly, does not adopt when the restore never lands).
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("RestoreController (008 H5c)")
struct RestoreControllerTests {

    /// An "origin" library that gets backed up, a target folder, and a SEPARATE
    /// replacement library to restore into — the shape restore exists for.
    private struct Rig {
        let controller: RestoreController
        let origin: AppServices
        let originStore: MediaStore
        let originRoot: URL
        let target: URL
        /// The replacement library.
        let liveRoot: URL
        let root: URL

        var live: MediaStore { MediaStore(root: liveRoot) }
        var snapshots: URL { LibraryLayout(root: liveRoot).snapshots }
        var folder: any FolderAccess { DirectFolderAccess(url: target) }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originRoot = root.appendingPathComponent("origin", isDirectory: true)
        let liveRoot = root.appendingPathComponent("replacement", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for directory in [originRoot, liveRoot, target] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let origin = try AppServices(
            databasePath: originRoot.appendingPathComponent("library.sqlite").path)
        return Rig(
            controller: RestoreController(), origin: origin,
            originStore: MediaStore(root: originRoot), originRoot: originRoot,
            target: target, liveRoot: liveRoot, root: root)
    }

    private func seed(_ rig: Rig, hash: String, bytes: String = "payload") async throws {
        try rig.originStore.storeBlob(Data(bytes.utf8), hash: hash, fileExtension: "png")
        let collection = try await rig.origin.createCollection(name: "C-\(hash)")
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: bytes.utf8.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(hash)", capturedAt: Date())
        _ = try await rig.origin.ingest(draft, from: source, into: collection.id)
    }

    /// Back the origin library up into the target, and return its library id.
    @discardableResult
    private func backUp(_ rig: Rig) async throws -> String {
        let id = try LibraryIdentity.resolve(root: rig.originRoot)
        try await BackupRunner(
            services: rig.origin, source: rig.originStore,
            layout: BackupLayout(target: rig.target, libraryID: id),
            appVersion: "1.0-test").run()
        return id
    }

    /// Scan and wait.
    private func scan(_ rig: Rig, folder: (any FolderAccess)? = nil) async throws {
        rig.controller.scan(folder: folder ?? rig.folder)
        for _ in 0 ..< 400 where rig.controller.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!rig.controller.isScanning)
    }

    /// Start a restore of the first candidate and wait for it to settle.
    private func run(
        _ rig: Rig, source: BackupSource, folder: (any FolderAccess)? = nil,
        onStaged: (@MainActor (URL, BackupSource) -> Void)? = nil
    ) async throws {
        rig.controller.start(
            source: source, live: rig.live, snapshotsDirectory: rig.snapshots,
            folder: folder ?? rig.folder, onStaged: onStaged ?? { _, _ in })
        try await settle(rig.controller)
    }

    private func settle(_ controller: RestoreController) async throws {
        for _ in 0 ..< 400 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isRunning)
    }

    // MARK: - Discovery

    @Test("the backup is found under ITS id, not the restoring library's")
    func discoveryIsNotALookup() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        let originID = try await backUp(rig)
        // The replacement library has its own, different id — the "new Mac"
        // case. Looking under it would find nothing and report an empty folder
        // while the user's whole library sat one directory away.
        let liveID = try LibraryIdentity.resolve(root: rig.liveRoot)
        #expect(liveID != originID)

        try await scan(rig)

        #expect(rig.controller.candidates.map(\.libraryID) == [originID])
        #expect(rig.controller.scanMessage == nil)
    }

    @Test("an empty folder says so rather than looking broken")
    func emptyFolderIsExplained() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await scan(rig)

        #expect(rig.controller.candidates.isEmpty)
        #expect(rig.controller.scanMessage == BackupTarget.noBackupsFound)
    }

    @Test("an unreachable drive is a message, not a crash")
    func unreachableFolderScansToAMessage() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await scan(rig, folder: UnreachableRestoreFolder())

        #expect(rig.controller.candidates.isEmpty)
        #expect(rig.controller.scanMessage
            == BackupTarget.message(for: FolderAccessError.bookmarkUnresolvable))
    }

    @Test("a revoked grant is reported as denied, not as a missing folder")
    func deniedGrantScansToItsOwnMessage() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await scan(rig, folder: DeniedRestoreFolder(url: rig.target))

        #expect(rig.controller.scanMessage
            == BackupTarget.message(for: FolderAccessError.accessDenied))
    }

    // MARK: - A successful restore

    @Test("a restore copies the blobs back and hands a snapshot to the seam")
    func successfulRestore() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111", bytes: "one")
        try await seed(rig, hash: "bbbb2222", bytes: "two")
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)

        let staged = StagedSnapshots()
        try await run(rig, source: source, onStaged: { url, _ in staged.record(url) })

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .succeeded)
        #expect(summary.copiedFiles == 2)
        #expect(summary.message == nil)
        #expect(rig.controller.progress == 1)
        // Bytes back in the live library…
        #expect(String(decoding: try rig.live.readBlob(
            hash: "aaaa1111", fileExtension: "png"), as: UTF8.self) == "one")
        // …and exactly one snapshot handed on, parseable by the shipped seam.
        let url = try #require(staged.urls.first)
        #expect(staged.urls.count == 1)
        #expect(SnapshotFile(url: url)?.reason == .manual)
    }

    @Test("a restore whose media is incomplete is INCOMPLETE, not a success")
    func incompleteRestore() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111", bytes: "one")
        try await seed(rig, hash: "bbbb2222", bytes: "two")
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)
        // A FILE where the live store's "aa/aa" shard directory needs to be, so
        // that one blob cannot land. (Standing in for the realistic causes: a
        // full local disk, an iCloud file that won't download.)
        let blobs = rig.live.layout.blobs
        try FileManager.default.createDirectory(
            at: blobs.appendingPathComponent("aa"), withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blobs.appendingPathComponent("aa/aa"))

        let staged = StagedSnapshots()
        try await run(rig, source: source, onStaged: { url, _ in staged.record(url) })

        let summary = try #require(rig.controller.lastRun)
        // The database still restores — that is why this isn't `.failed` — but
        // a restore that quietly dropped media must never read as clean.
        #expect(summary.outcome == .incomplete)
        #expect(summary.unresolvedFiles == 1)
        #expect(summary.copiedFiles == 1)
        // One bad file must not cost the user the rest of the restore.
        #expect(rig.live.hasBlob(hash: "bbbb2222", fileExtension: "png"))
        #expect(staged.urls.count == 1)
    }

    // MARK: - Failures

    @Test("an unreachable drive during a restore fails with the reason")
    func unreachableFolderFailsTheRun() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)

        try await run(rig, source: source, folder: UnreachableRestoreFolder())

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message
            == BackupTarget.message(for: FolderAccessError.bookmarkUnresolvable))
    }

    @Test("a corrupt backup database refuses, stages nothing, says what to do")
    func corruptDatabaseRefuses() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)
        try Data("not a database".utf8).write(to: source.layout.database)

        let staged = StagedSnapshots()
        try await run(rig, source: source, onStaged: { url, _ in staged.record(url) })

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message
            == BackupTarget.message(for: RestoreRunner.RestoreError.databaseUnhealthy))
        // Nothing offered to the restore seam, and nothing left in `snapshots/`
        // that a later glance could mistake for a restore point.
        #expect(staged.urls.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(
            atPath: rig.snapshots.path)) ?? []).isEmpty)
    }

    // MARK: - Cancellation

    @Test("cancelling records a cancellation, not a failure")
    func cancelRecordsCancelled() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xAAA0_0000 + index))
        }
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)

        let staged = StagedSnapshots()
        rig.controller.start(
            source: source, live: rig.live, snapshotsDirectory: rig.snapshots,
            folder: rig.folder, onStaged: { url, _ in staged.record(url) })
        rig.controller.cancel()
        try await settle(rig.controller)

        let summary = try #require(rig.controller.lastRun)
        // Cancelling tears down in-flight work, which throws. Those throws are a
        // consequence of pressing Stop — never a failure to report.
        #expect(summary.outcome == .cancelled)
        #expect(summary.message == nil)
        // And nothing is staged, so the live library is exactly as it was.
        #expect(staged.urls.isEmpty)
    }

    @Test("a second start while running is ignored")
    func concurrentStartIsIgnored() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xCCC0_0000 + index))
        }
        try await backUp(rig)
        try await scan(rig)
        let source = try #require(rig.controller.candidates.first)

        let staged = StagedSnapshots()
        for _ in 0 ..< 2 {
            rig.controller.start(
                source: source, live: rig.live, snapshotsDirectory: rig.snapshots,
                folder: rig.folder, onStaged: { url, _ in staged.record(url) })
        }
        try await settle(rig.controller)

        #expect(rig.controller.lastRun?.outcome == .succeeded)
        // Two runs would both stage a snapshot, and the second would silently
        // replace the first as the pending restore.
        #expect(staged.urls.count == 1)
    }
}

// MARK: - Identity adoption

@MainActor
@Suite("Restore identity adoption (008 H5c)")
struct RestoreIdentityAdoptionTests {

    /// A library root with a `snapshots/` directory beside its database.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreIdentityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: LibraryLayout(root: root).snapshots, withIntermediateDirectories: true)
        return root
    }

    @Test("a restore that lands adopts the backup's library id")
    func adoptionAppliesOnARealRestore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        let manager = SnapshotManager(services: services, directory: snapshots)
        let own = try LibraryIdentity.resolve(root: root)

        try manager.stageIdentityAdoption("00aa11bb22cc33dd")
        #expect(SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: true))

        // The library now IS the backed-up library, so its backups keep updating
        // that library's folder instead of starting a second copy beside it.
        #expect(try LibraryIdentity.resolve(root: root) == "00aa11bb22cc33dd")
        #expect(own != "00aa11bb22cc33dd")
    }

    @Test("a restore that did NOT land leaves the identity alone")
    func adoptionIsSkippedWhenTheRestoreFailed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        let manager = SnapshotManager(services: services, directory: snapshots)
        let own = try LibraryIdentity.resolve(root: root)

        try manager.stageIdentityAdoption("00aa11bb22cc33dd")
        #expect(!SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: false))

        // Still holding its OWN database, so it is still its own library —
        // claiming the backup's id here would point its next backup at that
        // folder and overwrite the recovery point it failed to restore from.
        #expect(try LibraryIdentity.resolve(root: root) == own)
    }

    @Test("the request is consumed either way, so it can't fire on a later restore")
    func markerIsConsumedEvenWhenSkipped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        let manager = SnapshotManager(services: services, directory: snapshots)
        let own = try LibraryIdentity.resolve(root: root)

        try manager.stageIdentityAdoption("00aa11bb22cc33dd")
        _ = SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: false)
        // A later, UNRELATED snapshot restore must not inherit that request.
        #expect(!SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: true))
        #expect(try LibraryIdentity.resolve(root: root) == own)
    }

    @Test("no request means no change, and no error")
    func noMarkerIsANoop() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let own = try LibraryIdentity.resolve(root: root)

        #expect(!SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: true))
        #expect(try LibraryIdentity.resolve(root: root) == own)
    }

    @Test("a malformed request is refused rather than written into a path")
    func malformedIDIsRefused() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        let manager = SnapshotManager(services: services, directory: snapshots)
        let own = try LibraryIdentity.resolve(root: root)

        try manager.stageIdentityAdoption("../escape")
        #expect(!SnapshotManager.applyPendingIdentityAdoption(
            snapshotsDir: snapshots, libraryRoot: root, restored: true))
        #expect(try LibraryIdentity.resolve(root: root) == own)
    }

    @Test("applyPendingRestore reports whether it actually restored")
    func applyPendingRestoreReportsTruthfully() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = LibraryLayout(root: root).snapshots
        let dbURL = root.appendingPathComponent("library.sqlite")

        // Nothing staged.
        #expect(!SnapshotManager.applyPendingRestore(snapshotsDir: snapshots, livePath: dbURL))

        // A marker naming a file that isn't there — the shape a pruned or
        // hand-deleted snapshot leaves.
        try "manual-20260101-000000-abcd1234.sqlite".write(
            to: snapshots.appendingPathComponent(".pending-restore"),
            atomically: true, encoding: .utf8)
        #expect(!SnapshotManager.applyPendingRestore(snapshotsDir: snapshots, livePath: dbURL))

        // A real staged snapshot.
        let staged: URL
        do {
            let services = try AppServices(databasePath: dbURL.path)
            _ = try await services.createCollection(name: "Before")
            let manager = SnapshotManager(services: services, directory: snapshots)
            staged = try await manager.snapshot(reason: .manual)
            try manager.stageRestore(try #require(SnapshotFile(url: staged)))
        }
        #expect(SnapshotManager.applyPendingRestore(snapshotsDir: snapshots, livePath: dbURL))
    }
}

// MARK: - Test doubles

/// A target whose bookmark won't resolve — the unplugged-drive case.
private struct UnreachableRestoreFolder: FolderAccess {
    func resolve() throws -> URL { throw FolderAccessError.bookmarkUnresolvable }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}

/// A target that resolves but whose security scope is refused.
private struct DeniedRestoreFolder: FolderAccess {
    let url: URL
    func resolve() throws -> URL { url }
    func beginAccess(to url: URL) throws { throw FolderAccessError.accessDenied }
    func endAccess(to url: URL) {}
}

/// Collects what the controller handed to the restore seam.
@MainActor
private final class StagedSnapshots {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
