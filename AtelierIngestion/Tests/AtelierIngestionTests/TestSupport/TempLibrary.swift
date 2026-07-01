// AtelierIngestion — shared test store helper (chunk 2, decision T9/T10)
//
// One place that builds a `MediaStore` rooted in a UNIQUE temp directory per
// test, mirroring AtelierCore's `makeTempDatabase()` pattern. The caller
// `defer`s `cleanup()` to delete the whole tree (blobs / thumbnails / cache).

import Foundation
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
