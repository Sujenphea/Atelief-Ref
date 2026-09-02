//
//  BlobSweepMarkerTests.swift
//  AtelierRefsTests
//
//  099 · 16A — the launch orphan-blob sweep stops running for no reason.
//
//  The sweep enumerates every file under `blobs/` and diffs it against the set of
//  hashes the database still references. It exists because a recoverable delete
//  deliberately does NOT reap: an in-session ⌘Z has to find the bytes on disk, so
//  a delete that is never undone leaves orphans for the next launch to reclaim.
//
//  What was wrong is not the sweep, it is when it ran: EVERY launch, whether or
//  not anything had been deleted. Orphans can only exist if a delete happened, so
//  the walk is a full directory enumeration of the library, at launch, almost
//  always to discover there is nothing to do — and it grows with the library, not
//  with the deleting.
//
//  So a delete leaves `snapshots/.gc-pending`, and the launch looks only when that
//  marker is there. The three states are a pure function (``LaunchBlobPass``), the
//  marker is best-effort like every other marker in that directory, and the clear
//  happens only on a sweep that actually completed — a sweep that refused to run
//  (it could not read the referenced set, and never reaps on uncertainty) must
//  leave the marker behind or the orphans it declined to look at go invisible.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing

@testable import AtelierRefs

@MainActor
@Suite("The launch blob sweep runs on a marker (099 · 16A)")
struct BlobSweepMarkerTests {

    // MARK: - Fixtures

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-pending-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        snapshotsDirectory: URL?
    ) async throws -> (model: IngestionModel, services: AppServices, store: MediaStore) {
        let dbPath = NSTemporaryDirectory() + "gc-marker-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: tempDirectory())
        let model = IngestionModel(
            services: services, store: store, snapshotsDirectory: snapshotsDirectory)
        await model.refreshFolders()
        return (model, services, store)
    }

    /// One byte-backed asset with its blob actually on disk, so a sweep has
    /// something real to reclaim.
    @discardableResult
    private func seedBlobAsset(
        hash: String, into collectionID: UUID, _ services: AppServices, _ store: MediaStore
    ) async throws -> UUID {
        let asset = try await services.ingest(
            AssetDraft(
                kind: .image, blobHash: hash, mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 4,
                downloadState: .downloaded),
            from: SourceDraft(
                platform: .web, originalURL: "https://x/\(hash)", capturedAt: Date()),
            into: collectionID).asset
        try store.storeBlob(Data("img".utf8), hash: hash, fileExtension: "png")
        return asset.id
    }

    // MARK: - The decision, pure

    @Test("a restore always wins — a sweep would trash media the reconcile protects")
    func restoreBeatsPending() {
        // The restored database is OLDER than the disk, so "unreferenced" includes
        // everything captured after the snapshot. Sweeping then is the one case
        // where the GC destroys data rather than reclaiming it.
        #expect(SnapshotManager.launchBlobPass(justRestored: true, gcPending: true)
                    == .reconcile)
        #expect(SnapshotManager.launchBlobPass(justRestored: true, gcPending: false)
                    == .reconcile)
    }

    @Test("with a marker and no restore, the launch sweeps")
    func markerSweeps() {
        #expect(SnapshotManager.launchBlobPass(justRestored: false, gcPending: true)
                    == .sweep)
    }

    @Test("with neither, the launch does nothing at all")
    func nothingToDo() {
        // The change this phase is: this used to be `.sweep`, which is a full walk
        // of `blobs/` on every launch of every library that has never deleted
        // anything.
        #expect(SnapshotManager.launchBlobPass(justRestored: false, gcPending: false)
                    == .none)
    }

    // MARK: - The marker itself

    @Test("the marker is absent until something writes it, and idempotent after")
    func markerLifecycle() {
        let dir = tempDirectory()
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))
        SnapshotManager.markGCPending(snapshotsDir: dir)
        #expect(SnapshotManager.hasGCPending(snapshotsDir: dir))
        SnapshotManager.markGCPending(snapshotsDir: dir)   // twice is once
        #expect(SnapshotManager.hasGCPending(snapshotsDir: dir))
        SnapshotManager.clearGCPending(snapshotsDir: dir)
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))
        SnapshotManager.clearGCPending(snapshotsDir: dir)  // clearing nothing is fine
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))
    }

    @Test("the marker creates the snapshots directory if the library has none yet")
    func markerCreatesItsDirectory() {
        // A library can be deleted from before it has ever taken a snapshot, and a
        // marker that silently failed to write there would mean the first delete
        // of a library's life never gets swept.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-nodir-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        SnapshotManager.markGCPending(snapshotsDir: dir)
        #expect(SnapshotManager.hasGCPending(snapshotsDir: dir))
    }

    @Test("the marker is not mistaken for a snapshot by the snapshots list")
    func markerIsNotASnapshot() throws {
        // `list()` hands every entry of the directory to `SnapshotFile(url:)`.
        // Every marker in there relies on that initialiser refusing it; this one
        // is a new marker and gets the same assertion the others earned.
        let dbPath = NSTemporaryDirectory() + "gc-list-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let dir = tempDirectory()
        SnapshotManager.markGCPending(snapshotsDir: dir)
        let manager = SnapshotManager(services: services, directory: dir)
        #expect(manager.list().isEmpty)
    }

    // MARK: - The delete writes it

    @Test("a recoverable delete marks the library for a sweep")
    func recoverableDeleteMarks() async throws {
        let dir = tempDirectory()
        let (model, services, store) = try await makeModel(snapshotsDirectory: dir)
        let folder = try await services.createCollection(name: "Bin")
        let id = try await seedBlobAsset(
            hash: String(repeating: "a", count: 64), into: folder.id, services, store)
        model.selectedFolderID = folder.id
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))

        model.requestDelete(assetIDs: [id])
        model.confirmPendingDeletion()
        await model.waitForWrites()

        #expect(SnapshotManager.hasGCPending(snapshotsDir: dir),
                "the delete left an orphaned blob and nothing recorded it")
    }

    @Test("a REDO of a delete marks too — it orphans exactly as the original did")
    func redoMarks() async throws {
        // The redo path takes the non-recoverable `deleteAssets`, which also defers
        // reaping so a second ⌘Z still restores. Without its own mark, a
        // delete → undo → redo sequence would leave orphans behind a marker the
        // undo's sweep had already cleared.
        let dir = tempDirectory()
        let (model, services, store) = try await makeModel(snapshotsDirectory: dir)
        let folder = try await services.createCollection(name: "Bin")
        let id = try await seedBlobAsset(
            hash: String(repeating: "b", count: 64), into: folder.id, services, store)
        model.selectedFolderID = folder.id

        model.requestDelete(assetIDs: [id])
        model.confirmPendingDeletion()
        await model.waitForWrites()
        model.undo()
        await model.waitForWrites()
        SnapshotManager.clearGCPending(snapshotsDir: dir)   // as a completed sweep would

        model.redo()
        await model.waitForWrites()
        #expect(SnapshotManager.hasGCPending(snapshotsDir: dir))
    }

    @Test("a model with no snapshots directory marks nothing and still deletes")
    func noDirectoryIsNotAFailure() async throws {
        // The injectable test init has no library layout, and neither does any
        // caller that is not `bootstrap()`. The marker is a hint, so its absence
        // must never be a delete failure.
        let (model, services, store) = try await makeModel(snapshotsDirectory: nil)
        let folder = try await services.createCollection(name: "Bin")
        let id = try await seedBlobAsset(
            hash: String(repeating: "c", count: 64), into: folder.id, services, store)
        model.selectedFolderID = folder.id

        model.requestDelete(assetIDs: [id])
        model.confirmPendingDeletion()
        await model.waitForWrites()
        #expect(try await services.collectionItems(
            in: folder.id, includeArchived: false).isEmpty)
        #expect(model.lastError == nil)
    }

    // MARK: - The sweep clears it

    @Test("a completed sweep reclaims the orphan and clears the marker")
    func sweepReclaimsAndClears() async throws {
        let dir = tempDirectory()
        let (model, services, store) = try await makeModel(snapshotsDirectory: dir)
        let folder = try await services.createCollection(name: "Bin")
        let orphan = String(repeating: "d", count: 64)
        let kept = String(repeating: "e", count: 64)
        let id = try await seedBlobAsset(hash: orphan, into: folder.id, services, store)
        try await seedBlobAsset(hash: kept, into: folder.id, services, store)
        model.selectedFolderID = folder.id

        model.requestDelete(assetIDs: [id])
        model.confirmPendingDeletion()
        await model.waitForWrites()
        // Deferred, exactly as 010 requires — the bytes are still there for ⌘Z.
        #expect(store.hasBlob(hash: orphan, fileExtension: "png"))

        let reaped = await IngestionModel.sweepOrphanBlobs(
            services: services, store: store, snapshotsDir: dir)

        #expect(reaped == 1)
        #expect(!store.hasBlob(hash: orphan, fileExtension: "png"))
        #expect(store.hasBlob(hash: kept, fileExtension: "png"),
                "the sweep reaped a blob an asset still references")
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))
    }

    @Test("a sweep with nothing to reclaim still clears the marker")
    func emptySweepClears() async throws {
        // Otherwise a marker written by a delete that turned out to orphan nothing
        // (a content-identical asset still holds the blob) would make every
        // subsequent launch walk the library forever.
        let dir = tempDirectory()
        let (_, services, store) = try await makeModel(snapshotsDirectory: dir)
        SnapshotManager.markGCPending(snapshotsDir: dir)

        let reaped = await IngestionModel.sweepOrphanBlobs(
            services: services, store: store, snapshotsDir: dir)

        #expect(reaped == 0)
        #expect(!SnapshotManager.hasGCPending(snapshotsDir: dir))
    }
}
