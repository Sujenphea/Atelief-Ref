//
//  LibraryArchiveExportTests.swift
//  AtelierRefsTests
//
//  008 · H6 — the writer and the controller, driven against a real (temp)
//  library and a `DirectFolderAccess` destination, so nothing here needs the
//  sandbox, a bookmark or a panel.
//
//  What these cover is the half a golden file can't: that the tree on disk and
//  the manifest beside it describe the SAME library — one asset entry per asset
//  however many folders hold its bytes — and that a stopped run is reported as
//  stopped and leaves no manifest claiming otherwise.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Rig

/// A real library, and a destination folder beside it.
@MainActor
private struct Rig {
    let services: AppServices
    let store: MediaStore
    let libraryRoot: URL
    let destination: URL
    let root: URL

    var folder: DirectFolderAccess { DirectFolderAccess(url: destination) }

    var writer: LibraryArchiveWriter {
        LibraryArchiveWriter(
            services: services, store: store, appVersion: "1.0-test",
            schemaVersion: "v18")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func make() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArchiveExportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        // NOT created up front: the writer must create its own destination, the
        // way the save panel's freshly-named folder arrives.
        let destination = root.appendingPathComponent("Atelier Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryRoot, withIntermediateDirectories: true)
        let services = try AppServices(
            databasePath: libraryRoot.appendingPathComponent("library.sqlite").path)
        return Rig(
            services: services, store: MediaStore(root: libraryRoot),
            libraryRoot: libraryRoot, destination: destination, root: root)
    }

    /// Ingest one byte-backed asset with its blob really on disk.
    @discardableResult
    func seedImage(
        hash: String, into collectionID: UUID, title: String? = "Hero",
        url: String? = nil, bytes: String = "payload"
    ) async throws -> Asset {
        if !store.hasBlob(hash: hash, fileExtension: "png") {
            try store.storeBlob(Data(bytes.utf8), hash: hash, fileExtension: "png")
        }
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: bytes.utf8.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .pinterest, originalURL: url ?? "https://example.com/\(hash)",
            authorHandle: "@designer", authorName: "A Designer", title: title,
            capturedAt: Date(), rawMetadata: .object(["board": .string("Refs")]))
        return try await services.ingest(draft, from: source, into: collectionID).asset
    }

    func manifest() throws -> ArchiveManifest {
        try ArchiveManifest.read(
            from: destination.appendingPathComponent(ArchiveLayout.manifestFilename))
    }

    /// Every regular file in the archive, archive-relative.
    func files() -> [String] {
        let base = destination.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walk.compactMap { entry -> String? in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return String(url.standardizedFileURL.path.dropFirst(base.count + 1))
        }.sorted()
    }

    /// Every directory in the archive, deepest first — so permissions can be
    /// changed without a parent locking its own children out of reach.
    func directories() -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let found = walk.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return url
        }
        return (found + [destination])
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    func write() async throws -> LibraryArchiveWriter.Result {
        try await writer.write(to: destination, isCancelled: { false }, onProgress: { _ in })
    }
}

// MARK: - The tree and the manifest

@MainActor
@Suite("LibraryArchive: writing an archive (008 H6)")
struct LibraryArchiveWriterTests {

    /// A fresh library holds only the seeded Unsorted folder. The archive is a
    /// folder for it and a manifest with nothing in it — not a failure, and not
    /// an empty directory with no manifest (which would read as interrupted).
    @Test("An empty library still produces a manifest and a folder")
    func emptyLibrary() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }

        let result = try await rig.write()
        let manifest = try rig.manifest()

        #expect(result.assets == 0)
        #expect(result.files == 0)
        #expect(result.skipped == 0)
        #expect(manifest.assets.isEmpty)
        #expect(manifest.sources.isEmpty)
        #expect(manifest.collections.count == 1)
        #expect(manifest.collections[0].id == Collection.unsortedID)
        #expect(manifest.collections[0].items.isEmpty)
        #expect(manifest.schemaVersion == "v18")
        #expect(manifest.manifestVersion == ArchiveManifest.currentVersion)
        #expect(rig.files() == [ArchiveLayout.manifestFilename])
    }

    @Test("An empty collection still gets a folder and a manifest entry")
    func emptyCollection() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let empty = try await rig.services.createCollection(name: "Nothing Here")

        _ = try await rig.write()
        let manifest = try rig.manifest()
        let entry = try #require(manifest.collections.first { $0.id == empty.id })

        #expect(entry.items.isEmpty)
        #expect(entry.path == "Collections/Nothing Here")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: rig.destination.appendingPathComponent(entry.path).path,
            isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    /// The archive's defining asymmetry: the tree duplicates for browsability,
    /// the manifest does not, so a re-import yields ONE asset with N
    /// memberships rather than N assets.
    @Test("A multi-collection asset is copied N times but recorded once")
    func multiCollectionAsset() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let a = try await rig.services.createCollection(name: "Alpha")
        let b = try await rig.services.createCollection(name: "Beta")
        let c = try await rig.services.createCollection(name: "Gamma")
        let asset = try await rig.seedImage(hash: "ab12cd34ef01", into: a.id)
        try await rig.services.addAssets([asset.id], to: b.id)
        try await rig.services.addAssets([asset.id], to: c.id)

        let result = try await rig.write()
        let manifest = try rig.manifest()

        #expect(result.files == 3)
        #expect(result.assets == 1)
        #expect(manifest.assets.count == 1)
        #expect(manifest.sources.count == 1)

        let files = rig.files().filter { $0.hasSuffix(".png") }
        #expect(files.count == 3)
        #expect(files.contains("Collections/Alpha/Hero-ab12cd34.png"))
        #expect(files.contains("Collections/Beta/Hero-ab12cd34.png"))
        #expect(files.contains("Collections/Gamma/Hero-ab12cd34.png"))

        // Every membership points at the copy in ITS own folder.
        let memberships = manifest.collections.flatMap(\.items).filter { $0.assetID == asset.id }
        #expect(memberships.count == 3)
        #expect(Set(memberships.compactMap(\.file)).count == 3)
    }

    @Test("Nesting is written as folders AND as parent_collection_id")
    func nesting() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let parent = try await rig.services.createCollection(name: "Design")
        let child = try await rig.services.createCollection(name: "Refs", parent: parent.id)
        try await rig.seedImage(hash: "beef0001aaaa", into: child.id)

        _ = try await rig.write()
        let manifest = try rig.manifest()
        let entry = try #require(manifest.collections.first { $0.id == child.id })

        #expect(entry.parentID == parent.id)
        #expect(entry.path == "Collections/Design/Refs")
        #expect(rig.files().contains("Collections/Design/Refs/Hero-beef0001.png"))
        // Parents are written before their children, so the tree can be replayed
        // in manifest order without a second pass.
        let parentIndex = manifest.collections.firstIndex { $0.id == parent.id }
        let childIndex = manifest.collections.firstIndex { $0.id == child.id }
        #expect(parentIndex! < childIndex!)
    }

    /// The live counterpart of `ArchiveLayoutTests.deepNestingRelocates`: a tree
    /// deep enough to overrun the path budget still exports, and the graph
    /// survives even though the folder didn't nest.
    @Test("A tree too deep to nest still exports, with the real parent recorded")
    func deepNesting() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let long = String(repeating: "n", count: 60)
        var parent: Collection?
        var chain: [Collection] = []
        for index in 0..<20 {
            let made = try await rig.services.createCollection(
                name: "\(long)\(index)", parent: parent?.id)
            chain.append(made)
            parent = made
        }
        let deepest = try #require(chain.last)
        try await rig.seedImage(hash: "cafe0002bbbb", into: deepest.id)

        let result = try await rig.write()
        let manifest = try rig.manifest()
        let entry = try #require(manifest.collections.first { $0.id == deepest.id })

        #expect(result.files == 1)
        #expect(result.skipped == 0)
        // Depth was given up somewhere along the chain — the folder is shallower
        // than its 20 real ancestors — and every path stayed inside the budget.
        #expect(entry.path.split(separator: "/").count < 20)
        #expect(entry.path.hasPrefix("Collections/"))
        for collection in manifest.collections {
            #expect(ArchiveLayout.fits(collection.path.split(separator: "/").map(String.init)))
        }
        // …but the graph is intact, which is what an importer reads.
        #expect(entry.parentID == chain[chain.count - 2].id)
        #expect(manifest.collections.count == chain.count + 1)      // + Unsorted
        // And the bytes are really where the manifest says.
        let file = try #require(entry.items.first?.file)
        #expect(FileManager.default.fileExists(
            atPath: rig.destination.appendingPathComponent(file).path))
        #expect(file.utf8.count <= ArchiveLayout.maxRelativeBytes)
    }

    @Test("Manual order, tags and provenance ride into the manifest")
    func graphFidelity() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Ordered")
        let first = try await rig.seedImage(hash: "1111aaaabbbb", into: collection.id)
        let second = try await rig.seedImage(hash: "2222aaaabbbb", into: collection.id)
        try await rig.services.setGridOrder(
            collectionID: collection.id, orderedAssetIDs: [second.id, first.id])
        _ = try await rig.services.applyTag("moody", to: first.id, source: .user)
        _ = try await rig.services.applyTag("agentic", to: first.id, source: .agent)

        _ = try await rig.write()
        let manifest = try rig.manifest()
        let entry = try #require(manifest.collections.first { $0.id == collection.id })

        #expect(entry.items.map(\.assetID) == [second.id, first.id])
        #expect(entry.items.map(\.manualOrder) == [0, 1])

        let tagged = try #require(manifest.assets.first { $0.id == first.id })
        #expect(tagged.tags == [
            ArchiveManifest.TagEntry(Tag(id: UUID(), name: "agentic", source: .agent)),
            ArchiveManifest.TagEntry(Tag(id: UUID(), name: "moody", source: .user)),
        ])

        let source = try #require(manifest.sources.first { $0.id == tagged.sourceID })
        #expect(source.originalURL == "https://example.com/1111aaaabbbb")
        #expect(source.authorHandle == "@designer")
        #expect(source.rawMetadata == .object(["board": .string("Refs")]))
    }

    /// A media-less ref has no bytes to carry — its substance is the manifest's
    /// `payload` — so it must not be counted as something that failed to copy.
    @Test("A media-less asset has no file and is NOT a skip")
    func mediaLessAsset() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Colors")
        _ = try await rig.services.ingestContent(
            .color(hex: "#ff0000"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: collection.id)

        let result = try await rig.write()
        let manifest = try rig.manifest()

        #expect(result.skipped == 0)
        #expect(result.files == 0)
        #expect(manifest.assets.count == 1)
        #expect(manifest.assets[0].kind == .color)
        #expect(manifest.assets[0].payload != nil)
        #expect(manifest.assets[0].dedupKey == "#ff0000")
        let entry = try #require(manifest.collections.first { $0.id == collection.id })
        #expect(entry.items.count == 1)
        #expect(entry.items[0].file == nil)
    }

    /// A blob reaped or trashed since it was ingested. The archive can't invent
    /// the bytes; what it must not do is claim they are there.
    @Test("A byte-backed asset whose blob is gone is a reported skip, not a lie")
    func missingBlob() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Gappy")
        let asset = try await rig.seedImage(hash: "dead0003cccc", into: collection.id)
        try FileManager.default.removeItem(
            at: rig.store.blobURL(hash: "dead0003cccc", fileExtension: "png"))

        let result = try await rig.write()
        let manifest = try rig.manifest()

        #expect(result.skipped == 1)
        #expect(result.files == 0)
        // The asset is still described — only its bytes are missing.
        #expect(manifest.assets.count == 1)
        #expect(manifest.assets[0].id == asset.id)
        let entry = try #require(manifest.collections.first { $0.id == collection.id })
        #expect(entry.items[0].file == nil)
    }

    /// The disk-full shape: the destination refuses every copy. Distinct from
    /// ``missingBlob`` — there the SOURCE was gone and archiving around it is
    /// correct; here the destination is the problem, and a manifest over an
    /// empty tree would read as a finished archive of nothing.
    @Test("A destination that refuses every copy gets no manifest")
    func destinationRefusesEveryCopy() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Refs")
        try await rig.seedImage(hash: "beef0001aaaa", into: collection.id)

        // One good run builds the folder tree; emptying it and making every
        // directory read-only then reproduces a full volume exactly where it
        // bites — `createDirectory` is a no-op on a directory that exists, so the
        // walk proceeds and every `copyItem` is what throws.
        _ = try await rig.write()
        for relative in rig.files() {
            try FileManager.default.removeItem(
                at: rig.destination.appendingPathComponent(relative))
        }
        let directories = rig.directories()
        for directory in directories {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer {
            for directory in directories {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }

        await #expect(throws: ArchiveWriteError.nothingCopied) { try await rig.write() }
        // The commit record is absent, so the folder is visibly unfinished
        // rather than plausibly whole.
        #expect(!FileManager.default.fileExists(
            atPath: rig.destination
                .appendingPathComponent(ArchiveLayout.manifestFilename).path))
    }

    /// The other side of that guard: a source blob that is gone is a fact about
    /// the library, not the destination, so the archive still commits.
    @Test("A library whose only blob is gone still writes its manifest")
    func missingBlobStillCommits() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Gappy")
        try await rig.seedImage(hash: "dead0009cccc", into: collection.id)
        try FileManager.default.removeItem(
            at: rig.store.blobURL(hash: "dead0009cccc", fileExtension: "png"))

        let result = try await rig.write()

        #expect(result.files == 0)
        #expect(result.skipped == 1)
        // The skip was the SOURCE's, so it is not a write failure and does not
        // withhold the manifest.
        #expect(result.writeFailures == 0)
        #expect(try rig.manifest().assets.count == 1)
    }

    /// Two collections whose names sanitize to the same string, and an asset
    /// whose name repeats inside one folder — the two ways a folder export
    /// silently overwrites instead of erroring.
    @Test("Sanitized name collisions are disambiguated, never overwritten")
    func nameCollisions() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let first = try await rig.services.createCollection(name: "Refs / Q3")
        let second = try await rig.services.createCollection(name: "Refs : Q3")
        try await rig.seedImage(hash: "aaaa0004dddd", into: first.id)
        try await rig.seedImage(hash: "bbbb0005eeee", into: second.id)

        let result = try await rig.write()
        let manifest = try rig.manifest()
        let paths = manifest.collections.map(\.path)

        #expect(result.files == 2)
        #expect(Set(paths.map { $0.lowercased() }).count == paths.count)
        #expect(rig.files().filter { $0.hasSuffix(".png") }.count == 2)
    }

    @Test("The same blob in one folder is copied once and shared by both rows")
    func sharedBlobInOneFolder() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Twice")
        // Two assets, same bytes, different provenance — so 18A dedup does NOT
        // merge them and the folder really does hold two rows over one blob.
        try await rig.seedImage(
            hash: "eeee0006ffff", into: collection.id, url: "https://a.example/1")
        try await rig.seedImage(
            hash: "eeee0006ffff", into: collection.id, url: "https://b.example/2")

        let result = try await rig.write()
        let manifest = try rig.manifest()
        let entry = try #require(manifest.collections.first { $0.id == collection.id })

        #expect(manifest.assets.count == 2)
        #expect(result.files == 1)
        #expect(entry.items.count == 2)
        #expect(Set(entry.items.compactMap(\.file)).count == 1)
    }

    /// The manifest is the export's commit record — as `BackupRunner`'s is for a
    /// backup. Written last, so a folder with one is a folder that finished.
    @Test("A cancelled write leaves NO manifest behind")
    func cancelledLeavesNoManifest() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Stopped")
        try await rig.seedImage(hash: "9999000700aa", into: collection.id)

        await #expect(throws: CancellationError.self) {
            _ = try await rig.writer.write(
                to: rig.destination, isCancelled: { true }, onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(
            atPath: rig.destination
                .appendingPathComponent(ArchiveLayout.manifestFilename).path))
    }

    @Test("Re-exporting into the same folder refreshes it rather than failing")
    func reExport() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Again")
        try await rig.seedImage(hash: "7777000800bb", into: collection.id)

        _ = try await rig.write()
        let second = try await rig.write()
        #expect(second.files == 1)
        #expect(second.skipped == 0)
        #expect(rig.files().filter { $0.hasSuffix(".png") }.count == 1)
    }

    @Test("Progress ends at 1 and never goes backwards")
    func progressIsMonotonic() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        for index in 0..<3 {
            let collection = try await rig.services.createCollection(name: "C\(index)")
            try await rig.seedImage(hash: "5555000\(index)00cc", into: collection.id)
        }

        let recorder = ProgressRecorder()
        _ = try await rig.writer.write(
            to: rig.destination, isCancelled: { false },
            onProgress: { recorder.record($0) })

        let values = recorder.values
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(values.allSatisfy { (0...1).contains($0) })
    }
}

/// Collects the writer's progress callbacks from whatever thread they arrive on.
nonisolated private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - The controller

@MainActor
@Suite("LibraryArchive: ArchiveExportController (008 H6)")
struct ArchiveExportControllerTests {

    private func settle(_ controller: ArchiveExportController) async throws {
        for _ in 0..<600 {
            if !controller.isExporting, controller.lastRun != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("the archive run never finished")
    }

    private func start(_ rig: Rig, _ controller: ArchiveExportController) {
        controller.start(
            services: rig.services, store: rig.store,
            folder: rig.folder, appVersion: "1.0-test")
    }

    @Test("A clean run reports what it wrote, and where")
    func success() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Kept")
        try await rig.seedImage(hash: "3333000900dd", into: collection.id)

        let controller = ArchiveExportController()
        start(rig, controller)
        try await settle(controller)

        let run = try #require(controller.lastRun)
        #expect(run.outcome == .succeeded)
        #expect(run.assets == 1)
        #expect(run.files == 1)
        #expect(run.skipped == 0)
        #expect(run.url == rig.destination)
        #expect(run.message == nil)
        #expect(controller.progress == 1)
        #expect(!controller.isExporting)
    }

    @Test("A run that couldn't copy everything reports incomplete, not success")
    func incomplete() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Gappy")
        try await rig.seedImage(hash: "2222001000ee", into: collection.id)
        try FileManager.default.removeItem(
            at: rig.store.blobURL(hash: "2222001000ee", fileExtension: "png"))

        let controller = ArchiveExportController()
        start(rig, controller)
        try await settle(controller)

        let run = try #require(controller.lastRun)
        #expect(run.outcome == .incomplete)
        #expect(run.skipped == 1)
        #expect(run.url == rig.destination)
    }

    /// The lesson H5b and H5c both paid for: cancelling tears down in-flight
    /// work, which throws. The flag is asked BEFORE the error is classified, so
    /// a user who pressed Stop is never told their archive failed.
    @Test("A cancelled run classifies as cancelled, not failed, and writes no manifest")
    func cancelled() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        for index in 0..<40 {
            let collection = try await rig.services.createCollection(name: "C\(index)")
            try await rig.seedImage(hash: String(format: "aa%010d", index), into: collection.id)
        }

        let controller = ArchiveExportController()
        start(rig, controller)
        controller.cancel()
        try await settle(controller)

        let run = try #require(controller.lastRun)
        #expect(run.outcome == .cancelled)
        #expect(run.message == nil)
        #expect(!FileManager.default.fileExists(
            atPath: rig.destination
                .appendingPathComponent(ArchiveLayout.manifestFilename).path))
    }

    /// An unreachable destination is the user's problem to fix, and the words
    /// have to say which problem it is.
    @Test("A folder that can't be reached fails with its own message")
    func unreachableFolder() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }

        let controller = ArchiveExportController()
        controller.start(
            services: rig.services, store: rig.store,
            folder: FailingFolderAccess(), appVersion: "1.0-test")
        try await settle(controller)

        let run = try #require(controller.lastRun)
        #expect(run.outcome == .failed)
        #expect(run.message == ArchiveCopy.message(for: .bookmarkUnresolvable))
        #expect(run.url == nil)
    }

    @Test("A second start while one is running is a no-op")
    func noConcurrentRuns() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Once")
        try await rig.seedImage(hash: "1111001100ff", into: collection.id)

        let controller = ArchiveExportController()
        start(rig, controller)
        #expect(controller.isExporting)
        start(rig, controller)          // ignored
        try await settle(controller)

        #expect(controller.lastRun?.outcome == .succeeded)
        #expect(rig.files().filter { $0.hasSuffix(".png") }.count == 1)
    }

    /// A destination refused before any work starts — the model rejects a folder
    /// inside the library. It has to reach the same row a failed run does, or the
    /// button would appear to do nothing at all.
    @Test("A rejection surfaces as a failed run without touching the destination")
    func rejectionSurfaces() {
        let controller = ArchiveExportController()
        controller.reject(ArchiveCopy.insideLibrary)

        #expect(controller.lastRun?.outcome == .failed)
        #expect(controller.lastRun?.message == ArchiveCopy.insideLibrary)
        #expect(controller.lastRun?.url == nil)
        #expect(!controller.isExporting)
    }

    @Test("A rejection mid-run is ignored rather than overwriting the outcome")
    func rejectionIgnoredWhileRunning() async throws {
        let rig = try Rig.make()
        defer { rig.cleanup() }
        let collection = try await rig.services.createCollection(name: "Busy")
        try await rig.seedImage(hash: "3333001200aa", into: collection.id)

        let controller = ArchiveExportController()
        start(rig, controller)
        controller.reject(ArchiveCopy.insideLibrary)     // ignored
        try await settle(controller)

        #expect(controller.lastRun?.outcome == .succeeded)
    }
}

// MARK: - Words

@Suite("LibraryArchive: what the archive claims to carry (008 H6)")
struct ArchiveCopyScopeTests {

    /// The explainer is the only place a user learns what an archive holds, and
    /// the exclusions are the half that can lose data silently: Space text
    /// elements live nowhere but `space_item`, so archive → wipe → re-import
    /// drops every board. If this test fails because the copy was reworded,
    /// check the new wording still names them before updating it.
    @Test("the explainer names what it does NOT carry")
    func explainerNamesExclusions() {
        #expect(ArchiveCopy.explainer.localizedCaseInsensitiveContains("spaces"))
        #expect(ArchiveCopy.explainer.localizedCaseInsensitiveContains("saved searches"))
        // And points at the thing that DOES carry them.
        #expect(ArchiveCopy.explainer.localizedCaseInsensitiveContains("backup"))
    }

    /// It must not overclaim in the same breath — the sentence this replaced
    /// said "describing the whole library".
    @Test("the explainer no longer claims the whole library")
    func explainerDoesNotOverclaim() {
        #expect(!ArchiveCopy.explainer.localizedCaseInsensitiveContains("whole library"))
    }

    @Test("each refusal names its own remedy, and they don't collide")
    func refusalsAreDistinctAndActionable() {
        #expect(ArchiveCopy.insideLibrary
            .localizedCaseInsensitiveContains("inside your library"))
        #expect(ArchiveCopy.nothingCopied.localizedCaseInsensitiveContains("room"))
        // Two different problems must never produce the same sentence.
        #expect(ArchiveCopy.insideLibrary != ArchiveCopy.nothingCopied)
    }
}

/// A `FolderAccess` whose folder has gone — the unplugged-drive case, without a
/// drive.
private struct FailingFolderAccess: FolderAccess {
    func resolve() throws -> URL { throw FolderAccessError.bookmarkUnresolvable }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}
