//
//  BackupVerifyControllerTests.swift
//  AtelierRefsTests
//
//  008 · H5d — the app side of the re-hash check, driven against a destination a
//  REAL backup run produced, so what is verified is what the shipping copier
//  actually writes rather than a hand-built approximation of it.
//
//  The engine's own correctness (sampling, cancellation, what counts as a
//  mismatch) is `AtelierIngestionTests`' job. What only the app can get wrong is
//  which verdict the user is shown — and for a verifier the difference between
//  "we couldn't look" and "your backup is damaged" is the entire value.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("BackupVerifyController (008 H5d)")
struct BackupVerifyControllerTests {

    private struct Rig {
        let backup: BackupController
        let verify: BackupVerifyController
        let services: AppServices
        let store: MediaStore
        let libraryRoot: URL
        let target: URL
        let defaultsName: String
        let root: URL

        var folder: any FolderAccess { DirectFolderAccess(url: target) }

        func layout() throws -> BackupLayout {
            BackupLayout(
                target: target, libraryID: try LibraryIdentity.resolve(root: libraryRoot))
        }

        func cleanup() {
            UserDefaults().removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupVerifyControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for directory in [libraryRoot, target] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let services = try AppServices(
            databasePath: libraryRoot.appendingPathComponent("library.sqlite").path)

        let name = "BackupVerifyControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        return Rig(
            backup: BackupController(
                summaries: BackupSummaryStore(defaults: defaults),
                cadences: BackupCadenceStore(defaults: defaults)),
            // A fixed seed, so which files a sampled check looks at is a fact
            // about the test rather than about the time of day it ran.
            verify: BackupVerifyController(seed: { 0 }),
            services: services, store: MediaStore(root: libraryRoot),
            libraryRoot: libraryRoot, target: target, defaultsName: name, root: root)
    }

    /// One asset with real bytes — hashed for real, since the filename being the
    /// hash is the property under test.
    @discardableResult
    private func seed(_ rig: Rig, bytes: String) async throws -> String {
        let data = Data(bytes.utf8)
        let hash = ContentHasher.hash(data)
        try rig.store.storeBlob(data, hash: hash, fileExtension: "png")
        let collection = try await rig.services.createCollection(name: "C-\(bytes)")
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: data.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.com/\(bytes)", capturedAt: Date())
        _ = try await rig.services.ingest(draft, from: source, into: collection.id)
        return hash
    }

    /// Run a real backup, so the destination under test is the shipping one.
    private func runBackup(_ rig: Rig) async throws {
        rig.backup.start(
            services: rig.services, source: rig.store, libraryRoot: rig.libraryRoot,
            folder: rig.folder, appVersion: "1.0-test")
        for _ in 0 ..< 400 where rig.backup.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.backup.lastRun?.outcome == .succeeded)
    }

    private func settle(_ controller: BackupVerifyController) async throws {
        for _ in 0 ..< 400 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isRunning)
    }

    /// Every blob file at the destination — the "nothing was deleted" witness.
    private func destinationFiles(_ rig: Rig) throws -> Set<String> {
        Set(try rig.layout().store.enumerateBlobFiles().map(\.hash))
    }

    // MARK: - A good destination

    @Test("a freshly made backup checks clean")
    func freshBackupIsClean() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, bytes: "one")
        try await seed(rig, bytes: "two")
        try await runBackup(rig)

        rig.verify.start(libraryRoot: rig.libraryRoot, folder: rig.folder)
        try await settle(rig.verify)

        let summary = try #require(rig.verify.lastRun)
        #expect(summary.outcome == .succeeded)
        #expect(summary.message == nil)
        let result = try #require(summary.result)
        #expect(result.isClean)
        #expect(result.databaseHealthy)
        #expect(rig.verify.progress == 1)
        #expect(BackupTarget.verifyProblem(for: result) == nil)
    }

    @Test("an exhaustive check reads every file and says so")
    func exhaustiveChecksEverything() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 5 { try await seed(rig, bytes: "blob-\(index)") }
        try await runBackup(rig)

        rig.verify.start(
            libraryRoot: rig.libraryRoot, folder: rig.folder, exhaustive: true)
        try await settle(rig.verify)

        let result = try #require(rig.verify.lastRun?.result)
        #expect(result.checked == 5)
        #expect(result.wasExhaustive)
        // The status line says "all N files" only when that is literally true.
        let line = try #require(BackupTarget.verifyStatusLine(for: rig.verify.lastRun))
        #expect(line.contains("all 5 files"))
    }

    // MARK: - A damaged destination

    @Test("a corrupted destination blob fails the check and is NOT deleted")
    func corruptedBlobIsCaughtAndKept() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let hash = try await seed(rig, bytes: "the-one-that-rots")
        try await runBackup(rig)
        let url = try rig.layout().store.blobURL(hash: hash, fileExtension: "png")
        // Flip a byte, keep the name.
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xFF
        try bytes.write(to: url)
        let before = try destinationFiles(rig)

        rig.verify.start(
            libraryRoot: rig.libraryRoot, folder: rig.folder, exhaustive: true)
        try await settle(rig.verify)

        let summary = try #require(rig.verify.lastRun)
        // The check RAN; it just didn't like what it saw. Calling that `.failed`
        // would point the user at the app instead of at their backup.
        #expect(summary.outcome == .incomplete)
        let result = try #require(summary.result)
        #expect(result.mismatched == [hash])
        // Reported loudly, and the sentence says outright that nothing was
        // removed — the first question a user asks on seeing this.
        let problem = try #require(BackupTarget.verifyProblem(for: result))
        #expect(problem.contains("Nothing was deleted"))
        #expect(try destinationFiles(rig) == before)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a verify failure prunes nothing, not even the file it flagged")
    func verifyDeletesNothing() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 4 { try await seed(rig, bytes: "blob-\(index)") }
        let victim = try await seed(rig, bytes: "victim")
        try await runBackup(rig)
        let layout = try rig.layout()
        try Data("wrong bytes entirely".utf8).write(
            to: layout.store.blobURL(hash: victim, fileExtension: "png"))
        let before = try destinationFiles(rig)

        rig.verify.start(
            libraryRoot: rig.libraryRoot, folder: rig.folder, exhaustive: true)
        try await settle(rig.verify)

        #expect(rig.verify.lastRun?.outcome == .incomplete)
        #expect(try destinationFiles(rig) == before)
        // The database and the manifest survive too: a check is a read.
        #expect(FileManager.default.fileExists(atPath: layout.database.path))
        #expect(FileManager.default.fileExists(atPath: layout.manifest.path))
    }

    // MARK: - Checks that couldn't run

    @Test("cancelling classifies as cancelled, not as a failure")
    func cancelIsCancelled() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 6 { try await seed(rig, bytes: "blob-\(index)") }
        try await runBackup(rig)

        rig.verify.start(
            libraryRoot: rig.libraryRoot, folder: rig.folder, exhaustive: true)
        rig.verify.cancel()
        try await settle(rig.verify)

        let summary = try #require(rig.verify.lastRun)
        // A teardown throw reported as a verification failure would read as
        // "your backup is damaged" — the costliest possible lie from this type.
        #expect(summary.outcome == .cancelled)
        #expect(summary.message == nil)
    }

    @Test("no backup in the folder says 'back up first', not 'damaged'")
    func missingBackupIsNotDamage() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, bytes: "never-backed-up")

        rig.verify.start(libraryRoot: rig.libraryRoot, folder: rig.folder)
        try await settle(rig.verify)

        let summary = try #require(rig.verify.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message == BackupTarget.message(for: BackupVerifier.VerifyError.noBackupFound))
        #expect(summary.result == nil)
    }

    @Test("an unreachable folder is reported with its own remedy")
    func unreachableFolderFails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        rig.verify.start(libraryRoot: rig.libraryRoot, folder: MissingFolder())
        try await settle(rig.verify)

        let summary = try #require(rig.verify.lastRun)
        #expect(summary.outcome == .failed)
        #expect(summary.message
            == BackupTarget.message(for: FolderAccessError.bookmarkUnresolvable))
    }

    @Test("a second start while checking is ignored")
    func concurrentStartIsIgnored() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 6 { try await seed(rig, bytes: "blob-\(index)") }
        try await runBackup(rig)

        rig.verify.start(
            libraryRoot: rig.libraryRoot, folder: rig.folder, exhaustive: true)
        #expect(rig.verify.isRunning)
        #expect(rig.verify.isExhaustive)
        // A second, sampled start must not silently downgrade the exhaustive
        // check already in flight.
        rig.verify.start(libraryRoot: rig.libraryRoot, folder: rig.folder)
        #expect(rig.verify.isExhaustive)
        try await settle(rig.verify)

        #expect(rig.verify.lastRun?.result?.wasExhaustive == true)
    }

    // MARK: - Words

    @Test("a clean sampled result never overstates what it looked at")
    func sampledStatusNamesBothCounts() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 3 { try await seed(rig, bytes: "blob-\(index)") }
        try await runBackup(rig)

        rig.verify.start(libraryRoot: rig.libraryRoot, folder: rig.folder)
        try await settle(rig.verify)

        let line = try #require(BackupTarget.verifyStatusLine(for: rig.verify.lastRun))
        // Under the cap, so the sample IS everything — and the line says "all",
        // which is the one case where the stronger claim is honest.
        #expect(line.contains("all 3 files"))
        #expect(line.contains("everything matched"))
    }
}

// MARK: - Test doubles

/// A target whose bookmark won't resolve.
private struct MissingFolder: FolderAccess {
    func resolve() throws -> URL { throw FolderAccessError.bookmarkUnresolvable }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}
