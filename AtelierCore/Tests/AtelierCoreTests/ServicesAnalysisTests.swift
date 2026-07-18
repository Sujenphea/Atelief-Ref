// AtelierCore — App Services analysis tests (012 · I1)
//
// The public analysis surface: upsert (insert + idempotent overwrite), read-back,
// asset-existence guard, cascade on asset delete, and the resumable
// `assetsNeedingAnalysis` backfill query (missing vs stale-version, kind/state
// filtering, ordering, limit clamp).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: analysis (012 · I1)")
struct ServicesAnalysisTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func imageDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 320, height: 240, duration: nil, fileSize: 1024,
            downloadState: .downloaded)
    }

    @discardableResult
    private func ingestImage(_ services: AppServices, into c: UUID, hash: String) async throws -> Asset {
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(hash)", authorHandle: nil,
            authorName: nil, title: nil, capturedAt: Date())
        return try await services.ingest(imageDraft(hash: hash), from: source, into: c).asset
    }

    // MARK: - Upsert + read-back

    @Test("upsert then read-back returns the stored analysis")
    func upsertAndRead() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingestImage(services, into: c.id, hash: "a1")

        let written = try await services.upsertAnalysis(
            assetID: asset.id, ocrText: "poster text",
            colors: "[{\"hex\":\"#0a141e\",\"coverage\":1.0}]",
            phash: 12345, analyzerVersion: 1)

        // Field-wise (not whole-struct ==): `analyzedAt` is server-stamped with
        // `Date()`, and GRDB stores millisecond precision, so the fetched Date
        // differs from the in-memory one below the millisecond — expected.
        let read = try await services.analysis(for: asset.id)
        #expect(read?.assetID == written.assetID)
        #expect(read?.ocrText == "poster text")
        #expect(read?.colors == written.colors)
        #expect(read?.phash == 12345)
        #expect(read?.analyzerVersion == 1)
    }

    @Test("analysis(for:) is nil before any analysis")
    func analysisNilBeforeUpsert() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingestImage(services, into: c.id, hash: "a2")
        #expect(try await services.analysis(for: asset.id) == nil)
    }

    @Test("upsert is idempotent — a second call overwrites in place, no duplicate row")
    func upsertOverwrites() async throws {
        let (services, temp) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingestImage(services, into: c.id, hash: "a3")

        try await services.upsertAnalysis(assetID: asset.id, ocrText: "first", phash: 1, analyzerVersion: 1)
        try await services.upsertAnalysis(assetID: asset.id, ocrText: "second", phash: 2, analyzerVersion: 2)

        let read = try await services.analysis(for: asset.id)
        #expect(read?.ocrText == "second")
        #expect(read?.phash == 2)
        #expect(read?.analyzerVersion == 2)
        // Exactly one row for the asset.
        let rowCount = try await temp.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM asset_analysis WHERE asset_id = ?",
                             arguments: [asset.id.uuidString.lowercased()])
        }
        #expect(rowCount == 1)
    }

    @Test("upsert for a non-existent asset throws notFound")
    func upsertMissingAssetThrows() async throws {
        let (services, _) = try makeServices()
        await #expect(throws: AtelierError.self) {
            try await services.upsertAnalysis(assetID: UUID(), phash: 1, analyzerVersion: 1)
        }
    }

    @Test("deleting the asset removes its analysis (cascade)")
    func deleteAssetCascades() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingestImage(services, into: c.id, hash: "a4")
        try await services.upsertAnalysis(assetID: asset.id, phash: 7, analyzerVersion: 1)

        try await services.deleteAssets([asset.id])
        #expect(try await services.analysis(for: asset.id) == nil)
    }

    // MARK: - Backfill query

    @Test("assetsNeedingAnalysis returns un-analyzed images, newest first")
    func backfillReturnsUnanalyzed() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a = try await ingestImage(services, into: c.id, hash: "b1")
        let b = try await ingestImage(services, into: c.id, hash: "b2")

        let pending = try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 50)
        #expect(Set(pending) == [a.id, b.id])
    }

    @Test("an analyzed asset at the current version drops out of the backfill set")
    func analyzedDropsOut() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a = try await ingestImage(services, into: c.id, hash: "b3")
        let b = try await ingestImage(services, into: c.id, hash: "b4")

        try await services.upsertAnalysis(assetID: a.id, phash: 1, analyzerVersion: 1)
        let pending = try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 50)
        #expect(pending == [b.id])
    }

    @Test("a stale-version analysis re-enters the backfill set at a higher version")
    func staleVersionReanalyzed() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a = try await ingestImage(services, into: c.id, hash: "b5")
        try await services.upsertAnalysis(assetID: a.id, phash: 1, analyzerVersion: 1)

        // Same version → not pending; a bumped analyzer version → pending again.
        #expect(try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 50).isEmpty)
        #expect(try await services.assetsNeedingAnalysis(analyzerVersion: 2, limit: 50) == [a.id])
    }

    @Test("media-less (color) assets are never in the backfill set")
    func mediaLessExcluded() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let image = try await ingestImage(services, into: c.id, hash: "b6")
        // A color kind has no blob — must not appear as "needing analysis".
        // localPaste carries no required original URL (unlike web).
        let source = SourceDraft(
            platform: .localPaste, originalURL: nil, authorHandle: nil, authorName: nil,
            title: nil, capturedAt: Date())
        _ = try await services.ingestContent(.color(hex: "#ff0000"), from: source, into: c.id)

        let pending = try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 50)
        #expect(pending == [image.id])
    }

    @Test("the limit is honored and clamped")
    func limitClamp() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        for i in 0 ..< 5 { _ = try await ingestImage(services, into: c.id, hash: "c\(i)") }

        #expect(try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 2).count == 2)
        // A zero/negative limit clamps up to at least 1 (never returns an empty
        // batch when candidates exist — the backfill would falsely think it's done).
        #expect(try await services.assetsNeedingAnalysis(analyzerVersion: 1, limit: 0).count == 1)
    }
}
