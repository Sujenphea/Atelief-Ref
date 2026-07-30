// AtelierCore — referencedBlobs(): the live-blob read (008 · F1)
//
// The read half of the file-level operations Core can't perform itself: the
// copy set for an off-device backup. Where `referencedBlobHashes` answers "may
// I reap this?", this answers "which FILE do I copy?" — so the mime that yields
// the stored extension travels with each hash. These pin the contract the
// backup differ depends on: one row per distinct hash, deterministic mime
// choice, NULL mime → "" (the dotless-path case MediaStore already stores).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: referencedBlobs (008 F1)")
struct ServicesReferencedBlobsTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func draft(hash: String, mime: String = "image/png") -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: mime,
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    /// Ingest one asset with a distinct source so 18A dedup doesn't collapse it.
    @discardableResult
    private func seed(
        _ services: AppServices, into collection: UUID,
        hash: String, mime: String = "image/png", url: String? = nil
    ) async throws -> UUID {
        let source = SourceDraft(
            platform: .web,
            originalURL: url ?? "https://example.com/\(hash)-\(UUID().uuidString)",
            capturedAt: Date())
        return try await services.ingest(draft(hash: hash, mime: mime), from: source,
                                         into: collection).asset.id
    }

    @Test("an empty library references no blobs")
    func emptyLibrary() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        #expect(try await services.referencedBlobs().isEmpty)
    }

    @Test("each referenced blob is reported once, with the mime that names its file")
    func reportsHashAndMime() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        try await seed(services, into: c, hash: "aa11", mime: "image/png")
        try await seed(services, into: c, hash: "bb22", mime: "image/jpeg")

        let blobs = try await services.referencedBlobs()

        #expect(blobs == [
            BlobRef(blobHash: "aa11", mimeType: "image/png"),
            BlobRef(blobHash: "bb22", mimeType: "image/jpeg"),
        ])
    }

    @Test("a blob shared by several assets is reported ONCE (the copy set is per file)")
    func sharedBlobReportedOnce() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        // Same bytes, different provenance → two assets, one blob on disk.
        try await seed(services, into: c, hash: "d0be", url: "https://a.example/1")
        try await seed(services, into: c, hash: "d0be", url: "https://b.example/2")

        let blobs = try await services.referencedBlobs()

        #expect(blobs == [BlobRef(blobHash: "d0be", mimeType: "image/png")])
    }

    @Test("conflicting mimes for one hash resolve deterministically, not arbitrarily")
    func conflictingMimeIsDeterministic() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        // Nothing enforces one mime per hash; a reproducible backup diff needs
        // the read to pick the same one every run regardless of insert order.
        try await seed(services, into: c, hash: "5a3e", mime: "image/png",
                       url: "https://a.example/1")
        try await seed(services, into: c, hash: "5a3e", mime: "image/gif",
                       url: "https://b.example/2")

        let first = try await services.referencedBlobs()
        let second = try await services.referencedBlobs()

        #expect(first.count == 1)
        #expect(first == second)
        #expect(first.first?.mimeType == "image/gif") // MIN of {gif, png}
    }

    @Test("a NULL mime yields \"\" — the dotless-path case, not a dropped row")
    func nullMimeBecomesEmptyString() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        let assetID = try await seed(services, into: c, hash: "c0ffee")
        // Drafts require a mime; NULL is only reachable for rows written before
        // that invariant (or by a future kind), so force the state directly.
        try temp.database.write { db in
            try db.execute(sql: "UPDATE asset SET mime_type = NULL WHERE id = ?",
                           arguments: [assetID.uuidString.lowercased()])
        }

        let blobs = try await services.referencedBlobs()

        #expect(blobs == [BlobRef(blobHash: "c0ffee", mimeType: "")])
    }

    @Test("assets with no blob (link/color kinds) are excluded entirely")
    func blobless() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        let assetID = try await seed(services, into: c, hash: "4ea1")
        let bloblessID = try await seed(services, into: c, hash: "b10b1e")
        try temp.database.write { db in
            try db.execute(sql: "UPDATE asset SET blob_hash = NULL WHERE id = ?",
                           arguments: [bloblessID.uuidString.lowercased()])
        }
        _ = assetID

        let blobs = try await services.referencedBlobs()

        #expect(blobs.map(\.blobHash) == ["4ea1"])
    }

    @Test("deleting the last referencing asset drops the blob from the live set")
    func deleteRemovesFromLiveSet() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        let keep = try await seed(services, into: c, hash: "beef")
        let drop = try await seed(services, into: c, hash: "d40b")
        _ = keep

        let reclaimed = try await services.deleteAssets([drop])

        // The two halves agree: what delete reports reclaimable is exactly what
        // leaves the live set — same descriptor type, opposite guarantee.
        #expect(reclaimed == [BlobRef(blobHash: "d40b", mimeType: "image/png")])
        #expect(try await services.referencedBlobs()
            == [BlobRef(blobHash: "beef", mimeType: "image/png")])
    }

    @Test("referencedBlobs and referencedBlobHashes describe the same set")
    func agreesWithHashesRead() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        for hash in ["a1", "b2", "c3"] {
            try await seed(services, into: c, hash: hash)
        }
        try await seed(services, into: c, hash: "a1", url: "https://dupe.example/x")

        let refs = try await services.referencedBlobs()
        let hashes = try await services.referencedBlobHashes()

        #expect(Set(refs.map(\.blobHash)) == hashes)
    }
}
