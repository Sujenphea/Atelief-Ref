// AtelierCore — perceptual-hash inventory tests (012 · I5)
//
// `perceptualHashes()` is the whole input to the near-duplicate review surface,
// and the surface's cardinal rule is that it must never propose deleting something
// that isn't there. That rule is enforced HERE, at the read: the JOIN back to
// `asset` is what makes the inventory live, so these tests are mostly about what
// the query must NOT return — a deleted asset, an un-hashed one, a media-less one,
// a still-downloading one.
//
// The grouping itself is a pure function tested in AtelierIngestion
// (`NearDuplicateClusteringTests`); Core groups nothing.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: perceptual-hash inventory (012 · I5)")
struct ServicesDuplicateHashesTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func imageDraft(hash: String, state: DownloadState = .downloaded) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 320, height: 240, duration: nil, fileSize: 1024,
            downloadState: state)
    }

    @discardableResult
    private func ingestImage(
        _ services: AppServices, into collection: UUID, hash: String,
        state: DownloadState = .downloaded
    ) async throws -> Asset {
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(hash)", authorHandle: nil,
            authorName: nil, title: nil, capturedAt: Date())
        return try await services
            .ingest(imageDraft(hash: hash, state: state), from: source, into: collection).asset
    }

    /// Backdate an asset so `created_at` ordering is deterministic — two ingests a
    /// microsecond apart would otherwise fall back to the id tie-break.
    private func backdate(_ temp: TempDatabase, _ assetID: UUID, to stamp: String) throws {
        try temp.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET created_at = ? WHERE id = ?",
                arguments: [stamp, assetID.uuidString.lowercased()])
        }
    }

    // MARK: - The quiet cases

    @Test("an empty library has no signatures")
    func emptyLibrary() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        #expect(try await services.perceptualHashes().isEmpty)
    }

    @Test("an image with no analysis row yet is absent")
    func unanalyzedAbsent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await ingestImage(services, into: c.id, hash: "d0")
        #expect(try await services.perceptualHashes().isEmpty)
    }

    @Test("an analysis row with a NULL phash is skipped, not read as zero")
    func nullHashSkipped() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Analyzed for OCR only — hashing produced nothing. Treating that as 0
        // would collide every such asset into one false "identical" cluster.
        let ocrOnly = try await ingestImage(services, into: c.id, hash: "d1")
        try await services.upsertAnalysis(
            assetID: ocrOnly.id, ocrText: "some text", phash: nil, analyzerVersion: 1)
        let hashed = try await ingestImage(services, into: c.id, hash: "d2")
        try await services.upsertAnalysis(assetID: hashed.id, phash: 77, analyzerVersion: 1)

        #expect(try await services.perceptualHashes().map(\.assetID) == [hashed.id])
    }

    // MARK: - Only live, byte-backed, downloaded images

    @Test("a deleted asset disappears from the inventory")
    func deletedAssetDisappears() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let keep = try await ingestImage(services, into: c.id, hash: "d3")
        let gone = try await ingestImage(services, into: c.id, hash: "d4")
        try await services.upsertAnalysis(assetID: keep.id, phash: 1, analyzerVersion: 1)
        try await services.upsertAnalysis(assetID: gone.id, phash: 1, analyzerVersion: 1)
        #expect(try await services.perceptualHashes().count == 2)

        _ = try await services.deleteAssets([gone.id])
        #expect(try await services.perceptualHashes().map(\.assetID) == [keep.id])
    }

    @Test("a media-less (color) asset is never in the inventory")
    func mediaLessExcluded() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let image = try await ingestImage(services, into: c.id, hash: "d5")
        try await services.upsertAnalysis(assetID: image.id, phash: 5, analyzerVersion: 1)

        let source = SourceDraft(
            platform: .localPaste, originalURL: nil, authorHandle: nil, authorName: nil,
            title: nil, capturedAt: Date())
        let color = try await services
            .ingestContent(.color(hex: "#ff0000"), from: source, into: c.id).asset
        // Even if something wrote it an analysis row, it has no bytes to compare.
        try await services.upsertAnalysis(assetID: color.id, phash: 5, analyzerVersion: 1)

        #expect(try await services.perceptualHashes().map(\.assetID) == [image.id])
    }

    @Test("an image whose bytes haven't landed yet is not offered for comparison")
    func pendingDownloadExcluded() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let ready = try await ingestImage(services, into: c.id, hash: "d6")
        let pending = try await ingestImage(services, into: c.id, hash: "d7", state: .pending)
        try await services.upsertAnalysis(assetID: ready.id, phash: 9, analyzerVersion: 1)
        try await services.upsertAnalysis(assetID: pending.id, phash: 9, analyzerVersion: 1)

        #expect(try await services.perceptualHashes().map(\.assetID) == [ready.id])
    }

    // MARK: - Shape of the result

    @Test("signatures come back oldest-first, so the original heads its cluster")
    func orderedOldestFirst() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let newest = try await ingestImage(services, into: c.id, hash: "d8")
        let oldest = try await ingestImage(services, into: c.id, hash: "d9")
        let middle = try await ingestImage(services, into: c.id, hash: "da")
        for asset in [newest, oldest, middle] {
            try await services.upsertAnalysis(assetID: asset.id, phash: 3, analyzerVersion: 1)
        }
        try backdate(temp, oldest.id, to: "2020-01-01 00:00:00.000")
        try backdate(temp, middle.id, to: "2021-01-01 00:00:00.000")
        try backdate(temp, newest.id, to: "2022-01-01 00:00:00.000")

        #expect(try await services.perceptualHashes().map(\.assetID)
            == [oldest.id, middle.id, newest.id])
    }

    @Test("the full 64-bit signature round-trips through signed storage")
    func signedRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingestImage(services, into: c.id, hash: "db")
        // A hash with the top bit set stores as a NEGATIVE Int64; the bit pattern
        // is what must survive, not the number.
        let signature: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        try await services.upsertAnalysis(
            assetID: asset.id, phash: Int64(bitPattern: signature), analyzerVersion: 1)

        let read = try await services.perceptualHashes()
        #expect(read.count == 1)
        #expect(read.first.map { UInt64(bitPattern: $0.phash) } == signature)
        #expect((read.first?.phash ?? 0) < 0)
    }
}
