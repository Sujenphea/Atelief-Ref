// AtelierIngestion — shared test store helper (chunk 2, decision T9/T10)
//
// One place that builds a `MediaStore` rooted in a UNIQUE temp directory per
// test, mirroring AtelierCore's `makeTempDatabase()` pattern. The caller
// `defer`s `cleanup()` to delete the whole tree (blobs / thumbnails / cache).

import Foundation
import AtelierCore
@testable import AtelierIngestion

/// A `MediaStore` rooted in a temp directory, plus that directory so a test can
/// tear it down.
struct TempLibrary {
    let store: MediaStore
    let root: URL

    /// The layout backing `store`, for tests that assert on shard/cache paths.
    var layout: LibraryLayout { store.layout }

    /// Delete the temp directory and everything under it. Safe to call once.
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Build a `MediaStore` in a fresh unique temp directory under the system temp
/// dir. `Foundation.UUID()` is fine for test isolation. Creates only the root
/// directory — the store creates `blobs`/`thumbnails`/`cache` on demand.
func makeTempLibrary() throws -> TempLibrary {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierIngestionTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TempLibrary(store: MediaStore(root: root), root: root)
}

// MARK: - Full pipeline environment (chunk 4, T12)

/// A complete, throwaway ingestion environment in ONE temp directory: a
/// `MediaStore` + an `AppServices` (a real migrated SQLite library) + a freshly
/// created collection + a wired `IngestPipeline` and `IngestCoordinator`.
///
/// The caller `defer`s `cleanup()` to delete the whole tree (blobs / thumbnails
/// / cache / the SQLite files). `AtelierIngestion` depends on `AtelierCore`, so
/// `AppServices` is constructed directly here — no fakes.
struct TempPipeline {
    let store: MediaStore
    let services: AppServices
    let collectionID: UUID
    let pipeline: IngestPipeline
    let coordinator: IngestCoordinator
    let root: URL

    /// The layout backing `store`, for tests that assert on blob/thumbnail paths.
    var layout: LibraryLayout { store.layout }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every regular file under `blobs/` (recursing the shard dirs). Used to
    /// assert dedup (one file), completeness, and "no blob on failure".
    func blobFiles() -> [URL] { regularFiles(under: layout.blobs) }

    /// Every regular file under `thumbnails/`.
    func thumbnailFiles() -> [URL] { regularFiles(under: layout.thumbnails) }

    /// Every regular file under `cache/` (staging temp files) — should be empty
    /// once all atomic writes have completed.
    func cacheFiles() -> [URL] { regularFiles(under: layout.cache) }

    /// Recursively enumerate the regular files under `directory` (absent
    /// directory ⇒ empty).
    private func regularFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular { files.append(url) }
        }
        return files
    }
}

/// Build a fresh ``TempPipeline`` under a unique temp directory: opens a real
/// migrated library at `<root>/library.sqlite`, creates one collection to ingest
/// into, and wires the pipeline + coordinator over the same `MediaStore`.
func makeTempPipeline(maxConcurrent: Int = 4) async throws -> TempPipeline {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierIngestionTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = MediaStore(root: root)
    let dbPath = root.appendingPathComponent("library.sqlite").path
    let services = try AppServices(databasePath: dbPath)
    let collection = try await services.createCollection(name: "Test Collection")

    let pipeline = IngestPipeline(store: store, services: services)
    let coordinator = IngestCoordinator(pipeline: pipeline, maxConcurrent: maxConcurrent)

    return TempPipeline(
        store: store, services: services, collectionID: collection.id,
        pipeline: pipeline, coordinator: coordinator, root: root)
}
