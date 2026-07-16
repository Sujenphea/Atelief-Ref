// AtelierIngestion — launch orphan-blob GC (010 · delete-undo).
//
// enumerateBlobFiles walks the sharded blobs tree; reapOrphanedBlobs Trashes every
// on-disk blob (+ its thumbnail tiers) NOT in the live referenced set, and keeps
// referenced/shared blobs. This is the sweep that reclaims a delete that was never
// undone. Trashed files are cleaned up so the suite never pollutes the Trash.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("Orphan-blob GC (enumerate + reap)")
struct OrphanGCTests {

    // Distinct valid hex hashes.
    static let a = String(repeating: "a", count: 64)
    static let b = String(repeating: "b", count: 64)
    static let c = String(repeating: "c", count: 64)

    private func emptyTrash(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func seedFullBlob(_ store: MediaStore, hash: String, ext: String) throws {
        try store.storeBlob(Data("blob".utf8), hash: hash, fileExtension: ext)
        for tier in ThumbnailTier.allCases {
            try store.storeThumbnail(
                Data("t".utf8), hash: hash, size: tier.rawValue, fileExtension: "jpg")
        }
    }

    // MARK: - enumerateBlobFiles

    @Test("enumerateBlobFiles returns every stored blob's (hash, ext)")
    func enumerates() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try lib.store.storeBlob(Data("1".utf8), hash: Self.a, fileExtension: "png")
        try lib.store.storeBlob(Data("2".utf8), hash: Self.b, fileExtension: "jpg")

        let found = Dictionary(uniqueKeysWithValues:
            lib.store.enumerateBlobFiles().map { ($0.hash, $0.fileExtension) })
        #expect(found == [Self.a: "png", Self.b: "jpg"])
    }

    @Test("enumerateBlobFiles ignores thumbnails (separate tree) and empty store")
    func enumerateScope() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        #expect(lib.store.enumerateBlobFiles().isEmpty) // empty store

        try lib.store.storeThumbnail(Data("t".utf8), hash: Self.a, size: 512, fileExtension: "jpg")
        #expect(lib.store.enumerateBlobFiles().isEmpty) // thumbnails are not blobs
    }

    // MARK: - reapOrphanedBlobs

    @Test("reaps orphans (blob + thumbnails), keeps referenced, is a no-op when all referenced")
    func reapsOrphansKeepsReferenced() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedFullBlob(lib.store, hash: Self.a, ext: "png") // referenced
        try seedFullBlob(lib.store, hash: Self.b, ext: "png") // orphan
        try seedFullBlob(lib.store, hash: Self.c, ext: "png") // orphan

        let reaper = MediaReaper(store: lib.store)
        let trashed = reaper.reapOrphanedBlobs(referenced: [Self.a])
        defer { emptyTrash(trashed) }

        // Referenced blob + its thumbnails survive.
        #expect(lib.store.hasBlob(hash: Self.a, fileExtension: "png"))
        #expect(lib.store.hasThumbnail(hash: Self.a, size: 512, fileExtension: "jpg"))
        // Orphans + their thumbnails are gone.
        #expect(!lib.store.hasBlob(hash: Self.b, fileExtension: "png"))
        #expect(!lib.store.hasBlob(hash: Self.c, fileExtension: "png"))
        #expect(!lib.store.hasThumbnail(hash: Self.b, size: 512, fileExtension: "jpg"))

        // Nothing to reap when everything is referenced.
        try seedFullBlob(lib.store, hash: Self.b, ext: "png")
        let second = reaper.reapOrphanedBlobs(referenced: [Self.a, Self.b])
        defer { emptyTrash(second) }
        #expect(second.isEmpty)
        #expect(lib.store.hasBlob(hash: Self.b, fileExtension: "png"))
    }

    @Test("empty store: reap is a no-op even with an empty referenced set")
    func reapEmptyStore() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let trashed = MediaReaper(store: lib.store).reapOrphanedBlobs(referenced: [])
        #expect(trashed.isEmpty)
    }
}
