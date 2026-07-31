// AtelierIngestion tests — where a backup puts things (008 · H5).
//
// Pure path math, but load-bearing path math: the incremental diff is only
// correct because the destination shards blobs EXACTLY as the live library
// does, and the database swap is only safe because the incoming copy has its
// own name until it is proven.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("BackupLayout (008 H5)")
struct BackupLayoutTests {

    private let target = URL(fileURLWithPath: "/Volumes/Backup/Atelier")
    private let id = "0123456789abcdef"

    private var layout: BackupLayout {
        BackupLayout(target: target, libraryID: id)
    }

    @Test("each library gets its own directory under the chosen folder")
    func rootIsNamespacedByLibrary() {
        #expect(layout.root.path == "/Volumes/Backup/Atelier/0123456789abcdef")
    }

    @Test("two libraries in one folder don't collide")
    func distinctLibrariesDistinctRoots() {
        let other = BackupLayout(target: target, libraryID: "fedcba9876543210")
        #expect(layout.root != other.root)
        #expect(layout.root.deletingLastPathComponent() == other.root.deletingLastPathComponent())
    }

    @Test("the destination shards blobs exactly like the live library")
    func shardSchemeMatchesLive() {
        // Not a coincidence to be maintained by hand — the destination store is
        // a `MediaStore` over the same `LibraryLayout`, so there is one
        // implementation. This test exists to catch anyone "simplifying" that.
        let live = MediaStore(root: URL(fileURLWithPath: "/live"))
        let backup = layout.store

        let liveTail = live.blobURL(hash: "abcd1234", fileExtension: "png")
            .pathComponents.suffix(4)
        let backupTail = backup.blobURL(hash: "abcd1234", fileExtension: "png")
            .pathComponents.suffix(4)
        #expect(Array(liveTail) == Array(backupTail))
        #expect(Array(backupTail) == ["blobs", "ab", "cd", "abcd1234.png"])
    }

    @Test("staging lives inside the destination, on the same volume as the blobs")
    func cacheIsUnderTheDestination() {
        // The atomic rename is only a rename if source and destination share a
        // volume; staging under the LIVE library's cache would silently become a
        // cross-volume copy plus delete.
        #expect(layout.library.cache.path
            == "/Volumes/Backup/Atelier/0123456789abcdef/cache")
        #expect(layout.library.blobs.deletingLastPathComponent()
            == layout.library.cache.deletingLastPathComponent())
    }

    @Test("the incoming database copy has its own name until it is proven")
    func incomingDatabaseIsSeparate() {
        #expect(layout.database.lastPathComponent == "library.sqlite")
        #expect(layout.incomingDatabase.lastPathComponent == "library.sqlite.new")
        #expect(layout.database != layout.incomingDatabase)
    }

    @Test("the manifest sits at the library's backup root")
    func manifestPath() {
        #expect(layout.manifest.lastPathComponent == "backup-manifest.json")
        #expect(layout.manifest.deletingLastPathComponent() == layout.root)
    }

    @Test("thumbnails and snapshots are not part of the destination")
    func derivedDirectoriesAreNotBackedUp() {
        // Named here so the omission reads as a decision rather than an
        // oversight: thumbnails regenerate, and the source machine's snapshots
        // add footprint without adding recovery the database copy lacks.
        let names = [layout.database, layout.incomingDatabase, layout.manifest]
            .map(\.lastPathComponent)
        #expect(!names.contains { $0.contains("thumbnail") })
        #expect(!names.contains { $0.contains("snapshot") })
    }
}
