// AtelierIngestion — MediaReaper + MediaStore removal tests.
//
// Verifies the delete-side media layout: a reaped blob's file AND every
// thumbnail tier leave their content-addressed paths (moved to Trash), the blob
// extension is recovered from the mime type, removal is idempotent, and the
// batch/[BlobRef] entry point works. Trashed files are cleaned up from the
// returned Trash URLs so the suite never pollutes the developer's Trash.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("MediaReaper + MediaStore removal")
struct MediaReaperTests {
    static let hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

    /// Remove the given Trash items so the test leaves nothing behind.
    private func emptyTrash(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Store a blob (at `blobExt`) plus a thumbnail for every tier (jpg), the
    /// exact on-disk footprint the reaper must reclaim.
    private func seedFullBlob(
        _ store: MediaStore, hash: String, blobExt: String
    ) throws {
        try store.storeBlob(Data("blob".utf8), hash: hash, fileExtension: blobExt)
        for tier in ThumbnailTier.allCases {
            try store.storeThumbnail(
                Data("thumb\(tier.rawValue)".utf8),
                hash: hash, size: tier.rawValue, fileExtension: "jpg")
        }
    }

    // MARK: - MediaStore removal primitives

    @Test("removeBlob moves the blob to Trash and is idempotent")
    func removeBlobTrashes() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try lib.store.storeBlob(Data("x".utf8), hash: Self.hash, fileExtension: "png")
        #expect(lib.store.hasBlob(hash: Self.hash, fileExtension: "png"))

        let trashed = try lib.store.removeBlob(hash: Self.hash, fileExtension: "png")
        defer { emptyTrash([trashed].compactMap { $0 }) }
        #expect(trashed != nil)
        #expect(FileManager.default.fileExists(atPath: trashed!.path)) // recoverable
        #expect(!lib.store.hasBlob(hash: Self.hash, fileExtension: "png"))

        // Second call: already gone → nil, no throw.
        #expect(try lib.store.removeBlob(hash: Self.hash, fileExtension: "png") == nil)
    }

    @Test("removeThumbnail moves one tier to Trash, leaving others")
    func removeThumbnailTrashes() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedFullBlob(lib.store, hash: Self.hash, blobExt: "png")

        let small = ThumbnailTier.small.rawValue
        let trashed = try lib.store.removeThumbnail(hash: Self.hash, size: small, fileExtension: "jpg")
        defer { emptyTrash([trashed].compactMap { $0 }) }
        #expect(trashed != nil)
        #expect(!lib.store.hasThumbnail(hash: Self.hash, size: small, fileExtension: "jpg"))
        // A different tier is untouched.
        #expect(lib.store.hasThumbnail(
            hash: Self.hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg"))
    }

    @Test("removeBlob on an absent file is a no-op returning nil")
    func removeBlobAbsentNoOp() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        #expect(try lib.store.removeBlob(hash: Self.hash, fileExtension: "png") == nil)
    }

    // MARK: - MediaReaper

    @Test("reap trashes the blob AND every thumbnail tier")
    func reapClearsEverything() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        // image/png → blob stored at extension "png" (what the reaper will derive).
        try seedFullBlob(lib.store, hash: Self.hash, blobExt: "png")

        let reaper = MediaReaper(store: lib.store)
        let trashed = reaper.reap(blobHash: Self.hash, mimeType: "image/png")
        defer { emptyTrash(trashed) }

        // blob + 3 tiers = 4 files moved.
        #expect(trashed.count == 1 + ThumbnailTier.allCases.count)
        #expect(!lib.store.hasBlob(hash: Self.hash, fileExtension: "png"))
        for tier in ThumbnailTier.allCases {
            #expect(!lib.store.hasThumbnail(hash: Self.hash, size: tier.rawValue, fileExtension: "jpg"))
        }
    }

    @Test("reap derives the blob extension from the mime type (jpeg)")
    func reapDerivesJpegExtension() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        // A JPEG asset stores its blob at "jpeg" (UTType's preferred extension).
        let jpegExt = ImageMetadata.fileExtension(forMIMEType: "image/jpeg")
        try lib.store.storeBlob(Data("j".utf8), hash: Self.hash, fileExtension: jpegExt)
        #expect(lib.store.hasBlob(hash: Self.hash, fileExtension: jpegExt))

        let trashed = MediaReaper(store: lib.store).reap(blobHash: Self.hash, mimeType: "image/jpeg")
        defer { emptyTrash(trashed) }
        #expect(!lib.store.hasBlob(hash: Self.hash, fileExtension: jpegExt))
    }

    @Test("reap of an already-absent blob is a best-effort no-op")
    func reapAbsentNoOp() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let trashed = MediaReaper(store: lib.store).reap(blobHash: Self.hash, mimeType: "image/png")
        #expect(trashed.isEmpty)
    }

    @Test("reap([BlobRef]) reclaims every blob in the batch")
    func reapBatch() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let other = "0011223344556677889900112233445566778899001122334455667788990011"
        try seedFullBlob(lib.store, hash: Self.hash, blobExt: "png")
        try seedFullBlob(lib.store, hash: other, blobExt: "png")

        let orphans = [
            BlobRef(blobHash: Self.hash, mimeType: "image/png"),
            BlobRef(blobHash: other, mimeType: "image/png"),
        ]
        let trashed = MediaReaper(store: lib.store).reap(orphans)
        defer { emptyTrash(trashed) }

        #expect(trashed.count == 2 * (1 + ThumbnailTier.allCases.count))
        #expect(!lib.store.hasBlob(hash: Self.hash, fileExtension: "png"))
        #expect(!lib.store.hasBlob(hash: other, fileExtension: "png"))
    }
}
