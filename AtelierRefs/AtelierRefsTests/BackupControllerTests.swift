//
//  BackupControllerTests.swift
//  AtelierRefsTests
//
//  008 · H5 — the app-side orchestrator, driven against a real (temp) library
//  and a `DirectFolderAccess` destination, so nothing here needs the sandbox or
//  a bookmark. The engine's own correctness is `AtelierIngestionTests`' job;
//  what these cover is the part only the app has: which run outcome the user is
//  shown, and whether that outcome survives a relaunch.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("BackupController (008 H5)")
struct BackupControllerTests {

    /// A real library, a destination folder beside it, and a controller wired to
    /// an isolated defaults suite.
    private struct Rig {
        let controller: BackupController
        let services: AppServices
        let store: MediaStore
        let libraryRoot: URL
        let target: URL
        let defaultsName: String
        let root: URL

        func cleanup() {
            UserDefaults().removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for directory in [libraryRoot, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let services = try AppServices(
            databasePath: libraryRoot.appendingPathComponent("library.sqlite").path)

        let name = "BackupControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        return Rig(
            controller: BackupController(summaries: BackupSummaryStore(defaults: defaults)),
            services: services, store: MediaStore(root: libraryRoot),
            libraryRoot: libraryRoot, target: target, defaultsName: name, root: root)
    }

    /// Add one asset with its blob bytes on disk — the normal state a run copies.
    private func seed(_ rig: Rig, hash: String, bytes: String = "payload") async throws {
        try rig.store.storeBlob(Data(bytes.utf8), hash: hash, fileExtension: "png")
        let collection = try await rig.services.createCollection(name: "C-\(hash)")
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: bytes.utf8.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(hash)", capturedAt: Date())
        _ = try await rig.services.ingest(draft, from: source, into: collection.id)
    }

    /// Start a run and wait for it to settle.
    private func run(_ rig: Rig, folder: (any FolderAccess)? = nil) async throws {
        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: folder ?? DirectFolderAccess(url: rig.target),
            appVersion: "1.0-test")
        try await settle(rig.controller)
    }

    /// Poll until the run finishes. Bounded so a hang fails the test rather than
    /// wedging the suite.
    private func settle(_ controller: BackupController) async throws {
        for _ in 0 ..< 400 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isRunning)
    }

    // MARK: - A successful run

    @Test("a run copies the library and records a success")
    func successfulRun() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await seed(rig, hash: "bbbb2222")

        try await run(rig)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .succeeded)
        #expect(summary.copiedFiles == 2)
        #expect(summary.message == nil)
        #expect(rig.controller.progress == 1)
    }

    @Test("the copy lands under the library's own id inside the chosen folder")
    func destinationIsNamespaced() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await run(rig)

        // Two libraries backing up to one folder must not overwrite each other,
        // which is the whole reason for the id level in the path.
        let id = try LibraryIdentity.resolve(root: rig.libraryRoot)
        let layout = BackupLayout(target: rig.target, libraryID: id)
        #expect(layout.store.hasBlob(hash: "aaaa1111", fileExtension: "png"))
        #expect(FileManager.default.fileExists(atPath: layout.manifest.path))
    }

    @Test("a second run copies nothing and still records a success")
    func secondRunIsANoop() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await run(rig)
        try await run(rig)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .succeeded)
        // Nothing to do IS success — reporting "0 files copied" as a problem
        // would train the user to ignore the status line.
        #expect(summary.copiedFiles == 0)
    }

    // MARK: - Partial and failed runs

    @Test("a run that couldn't copy everything is INCOMPLETE, not a success")
    func incompleteRun() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        // A row whose blob file is gone from disk.
        let collection = try await rig.services.createCollection(name: "Ghosts")
        let draft = AssetDraft(
            kind: .image, blobHash: "cccc3333", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 3,
            downloadState: .downloaded)
        _ = try await rig.services.ingest(
            draft,
            from: SourceDraft(platform: .web, originalURL: "https://x/ghost", capturedAt: Date()),
            into: collection.id)

        try await run(rig)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .incomplete)
        #expect(summary.unresolvedFiles == 1)
        #expect(summary.copiedFiles == 1)
        // The destination is still usable — that is why this isn't `.failed`.
        let id = try LibraryIdentity.resolve(root: rig.libraryRoot)
        let layout = BackupLayout(target: rig.target, libraryID: id)
        #expect(FileManager.default.fileExists(atPath: layout.database.path))
    }

    @Test("an unreachable target fails with the reason and does not hang")
    func unreachableTargetFails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")

        try await run(rig, folder: UnreachableFolder())

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        // The specific remedy, not a generic apology.
        #expect(summary.message == BackupTarget.message(for: FolderAccessError.bookmarkUnresolvable))
    }

    @Test("a denied grant is reported as denied, not as a missing folder")
    func deniedGrantFails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await run(rig, folder: DeniedFolder(url: rig.target))

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message == BackupTarget.message(for: FolderAccessError.accessDenied))
    }

    @Test("an unwritable destination is reported with its own remedy")
    func unwritableDestinationFails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        // A FILE where the library's backup directory needs to be. Minting the
        // id first (it persists) is how the test knows which name to block.
        let id = try LibraryIdentity.resolve(root: rig.libraryRoot)
        try Data("blocker".utf8).write(to: rig.target.appendingPathComponent(id))

        try await run(rig)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message == BackupTarget.message(for: .destinationUnwritable))
    }

    @Test("a damaged library-id file fails loudly instead of backing up twice")
    func malformedIdentityFails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try "not-an-id".write(
            to: rig.libraryRoot.appendingPathComponent(LibraryIdentity.fileName),
            atomically: true, encoding: .utf8)

        try await run(rig)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message == BackupTarget.unidentifiableLibrary)
    }

    // MARK: - Cancellation

    @Test("cancelling before anything runs records a cancellation, not a failure")
    func cancelRecordsCancelled() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xAAA0_0000 + index))
        }

        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: DirectFolderAccess(url: rig.target), appVersion: "1.0-test")
        rig.controller.cancel()
        try await settle(rig.controller)

        let summary = try #require(rig.controller.lastRun)
        #expect(summary.outcome == .cancelled)
        // Stopping is not an error; the next run resumes from what landed.
        #expect(summary.message == nil)
    }

    @Test("a cancelled run leaves the destination resumable, and a re-run finishes it")
    func cancelThenResume() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xBBB0_0000 + index))
        }

        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: DirectFolderAccess(url: rig.target), appVersion: "1.0-test")
        rig.controller.cancel()
        try await settle(rig.controller)
        #expect(rig.controller.lastRun?.outcome == .cancelled)

        try await run(rig)
        #expect(rig.controller.lastRun?.outcome == .succeeded)

        let id = try LibraryIdentity.resolve(root: rig.libraryRoot)
        let layout = BackupLayout(target: rig.target, libraryID: id)
        for index in 0 ..< 8 {
            #expect(layout.store.hasBlob(
                hash: String(format: "%08x", 0xBBB0_0000 + index), fileExtension: "png"))
        }
    }

    // MARK: - State

    @Test("a second start while running is ignored")
    func concurrentStartIsIgnored() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 8 {
            try await seed(rig, hash: String(format: "%08x", 0xCCC0_0000 + index))
        }

        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: DirectFolderAccess(url: rig.target), appVersion: "1.0-test")
        #expect(rig.controller.isRunning)
        // Two runs would both succeed (installs are atomic), but the progress
        // bar would stop meaning anything and the second does no useful work.
        rig.controller.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: DirectFolderAccess(url: rig.target), appVersion: "1.0-test")
        try await settle(rig.controller)

        #expect(rig.controller.lastRun?.outcome == .succeeded)
    }

    @Test("the last run survives a relaunch")
    func lastRunIsPersisted() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await run(rig)

        // A fresh controller over the same defaults is what the next launch
        // builds — "Never backed up" there would read as a broken backup.
        let relaunched = BackupController(
            summaries: BackupSummaryStore(defaults: UserDefaults(suiteName: rig.defaultsName)!))
        #expect(relaunched.lastRun == rig.controller.lastRun)
        #expect(relaunched.isRunning == false)
    }

    @Test("forgetting the last run clears it everywhere, not just in memory")
    func forgetLastRunClearsStorage() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, hash: "aaaa1111")
        try await run(rig)

        rig.controller.forgetLastRun()
        #expect(rig.controller.lastRun == nil)
        let relaunched = BackupController(
            summaries: BackupSummaryStore(defaults: UserDefaults(suiteName: rig.defaultsName)!))
        #expect(relaunched.lastRun == nil)
    }
}

// MARK: - Test doubles

/// A target whose bookmark won't resolve — the unplugged-drive case.
private struct UnreachableFolder: FolderAccess {
    func resolve() throws -> URL { throw FolderAccessError.bookmarkUnresolvable }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}

/// A target that resolves but whose security scope is refused — a revoked grant.
private struct DeniedFolder: FolderAccess {
    let url: URL
    func resolve() throws -> URL { url }
    func beginAccess(to url: URL) throws { throw FolderAccessError.accessDenied }
    func endAccess(to url: URL) {}
}
