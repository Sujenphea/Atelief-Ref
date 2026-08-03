// AtelierIngestion — regenerating missing thumbnail tiers (016 · A).
//
// The counterpart to `MediaReaperTests`: where those prove a blob's derived
// files leave, these prove they come back. The report is asserted field by
// field because "N rebuilt / N skipped" is the whole point of having a report —
// a run that quietly did nothing must be distinguishable from a healthy one.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("ThumbnailBackfill (016 A)")
struct ThumbnailBackfillTests {

    private static let hash =
        "beef0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab"

    /// Store a real decodable PNG as the blob for `hash`, and nothing else.
    private func seedBlobOnly(_ lib: TempLibrary, hash: String) throws {
        let png = try FixtureImages.solidImage(width: 64, height: 48, format: .png)
        try lib.store.storeBlob(png, hash: hash, fileExtension: "png")
    }

    private func hasAllTiers(_ lib: TempLibrary, hash: String) -> Bool {
        ThumbnailTier.allCases.allSatisfy {
            lib.store.hasThumbnail(hash: hash, size: $0.rawValue, fileExtension: "jpg")
        }
    }

    private func ref(_ hash: String, mime: String = "image/png") -> BlobRef {
        BlobRef(blobHash: hash, mimeType: mime)
    }

    @Test("every missing tier is regenerated from the blob's bytes")
    func regeneratesMissingTiers() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)
        #expect(!hasAllTiers(lib, hash: Self.hash))

        let result = try await ThumbnailBackfill(store: lib.store).run(blobs: [ref(Self.hash)])

        #expect(hasAllTiers(lib, hash: Self.hash))
        #expect(result.generated == ThumbnailTier.allCases.count)
        #expect(result.repaired == 1)
        #expect(result.skipped == 0)
        #expect(result.didWork)
    }

    @Test("only the MISSING tiers are written — a complete blob is left alone")
    func onlyMissingTiers() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)
        _ = try await ThumbnailBackfill(store: lib.store).run(blobs: [ref(Self.hash)])

        // Second run over a now-complete blob.
        let again = try await ThumbnailBackfill(store: lib.store).run(blobs: [ref(Self.hash)])

        #expect(again.generated == 0)
        #expect(again.alreadyComplete == 1)
        #expect(again.repaired == 0)
        #expect(!again.didWork)
    }

    @Test("a single purged tier is refilled without touching the others")
    func refillsOnePurgedTier() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)
        _ = try await ThumbnailBackfill(store: lib.store).run(blobs: [ref(Self.hash)])
        let medium = lib.store.thumbnailURL(
            hash: Self.hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg")
        try FileManager.default.removeItem(at: medium)

        let result = try await ThumbnailBackfill(store: lib.store).run(blobs: [ref(Self.hash)])

        #expect(result.generated == 1)
        #expect(result.repaired == 1)
        #expect(hasAllTiers(lib, hash: Self.hash))
    }

    @Test("a blob whose bytes are gone is SKIPPED, not fatal")
    func missingBlobIsSkipped() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)
        let present = Self.hash
        let absent = String("cafe".padding(
            toLength: 64, withPad: "0", startingAt: 0))

        let result = try await ThumbnailBackfill(store: lib.store)
            .run(blobs: [ref(present), ref(absent)])

        #expect(result.repaired == 1)
        #expect(result.skipped == 1)
        #expect(hasAllTiers(lib, hash: present))
    }

    @Test("unreadable bytes are skipped — the run continues past them")
    func undecodableBlobIsSkipped() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let junk = String("dead".padding(toLength: 64, withPad: "0", startingAt: 0))
        try lib.store.storeBlob(
            Data("not an image".utf8), hash: junk, fileExtension: "png")
        try seedBlobOnly(lib, hash: Self.hash)

        let result = try await ThumbnailBackfill(store: lib.store)
            .run(blobs: [ref(junk), ref(Self.hash)])

        #expect(result.skipped == 1)
        #expect(result.repaired == 1)
        #expect(hasAllTiers(lib, hash: Self.hash))
    }

    @Test("an empty blob list is a no-op, not an error")
    func emptyInput() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let result = try await ThumbnailBackfill(store: lib.store).run(blobs: [])

        #expect(result == ThumbnailBackfill.Result())
    }

    @Test("cancelling throws and leaves the remaining blobs untouched")
    func cancellationThrows() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)

        await #expect(throws: CancellationError.self) {
            try await ThumbnailBackfill(store: lib.store)
                .run(blobs: [self.ref(Self.hash)], isCancelled: { true })
        }
        #expect(!hasAllTiers(lib, hash: Self.hash))
    }

    @Test("progress ends at 1")
    func progressReachesOne() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlobOnly(lib, hash: Self.hash)
        final class Box: @unchecked Sendable { var last: Double = -1 }
        let box = Box()

        _ = try await ThumbnailBackfill(store: lib.store)
            .run(blobs: [ref(Self.hash)], onProgress: { box.last = $0 })

        #expect(box.last == 1)
    }
}
