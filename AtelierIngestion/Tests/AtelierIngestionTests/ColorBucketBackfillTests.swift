// AtelierIngestion — color bucket derivation pass (085 · C1)
//
// The seam between the stored swatch JSON and the searchable integer. What can
// go wrong here is not the arithmetic (`ColorPaletteTests` owns that) but the
// LOOP: an asset that can never be satisfied must not be handed out forever, and
// a partial failure must not abort the batch.

import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("ColorBucketBackfill (085 · C1)")
struct ColorBucketBackfillTests {

    private func makeEnv() async throws -> TempPipeline {
        try await makeTempPipeline()
    }

    @discardableResult
    private func seedAnalyzed(
        _ services: AppServices, into collectionID: UUID, colors: String?
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        let asset = try await services.ingest(draft, from: source, into: collectionID).asset.id
        try await services.upsertAnalysis(assetID: asset, colors: colors, analyzerVersion: 1)
        return asset
    }

    @Test("swatches become buckets, merged and stored")
    func filesBuckets() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        // Two reds and a green: the reds merge to 0.5, which is the point.
        let asset = try await seedAnalyzed(services, into: refs.id, colors: ##"""
            [{"hex":"#ff0000","coverage":0.3},
             {"hex":"#e02020","coverage":0.2},
             {"hex":"#00ff00","coverage":0.5}]
            """##)

        let outcome = try await ColorBucketBackfill(services: services)
            .fileNextBatch(limit: 10)
        #expect(outcome.filed == 1)
        #expect(outcome.failed == 0)

        let stored = try await services.colors(for: asset)
        #expect(stored.count == 2)
        let byBucket: [Int: Double] = Dictionary(
            uniqueKeysWithValues: stored.map { ($0.bucket, $0.coverage) })
        #expect(abs((byBucket[ColorBucket.red.rawValue] ?? 0) - 0.5) < 1e-9)
        #expect(abs((byBucket[ColorBucket.green.rawValue] ?? 0) - 0.5) < 1e-9)
    }

    @Test("a filed asset drops out of the queue — the pass is resumable")
    func isResumable() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        for _ in 0..<3 {
            try await seedAnalyzed(
                services, into: refs.id, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##)
        }
        let backfill = ColorBucketBackfill(services: services)

        #expect(try await backfill.fileNextBatch(limit: 2).filed == 2)
        #expect(try await backfill.fileNextBatch(limit: 2).filed == 1)
        #expect(try await backfill.fileNextBatch(limit: 2).attempted == 0)
    }

    /// The loop-safety property. Unparseable JSON is written as an empty bucket
    /// set, so the asset LEAVES the candidate set. Skipping it would hand it back
    /// on every pass forever — a queue that never drains and a `drain()` that
    /// never returns.
    @Test("an unparseable palette is filed as empty, not retried forever")
    func badJSONDoesNotWedgeTheQueue() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        let broken = try await seedAnalyzed(services, into: refs.id, colors: "not json")

        let backfill = ColorBucketBackfill(services: services)
        #expect(try await backfill.fileNextBatch(limit: 10).filed == 1)
        #expect(try await services.colors(for: broken).isEmpty)
        // The load-bearing half: it is GONE from the queue.
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: ColorPalette.version).isEmpty)
        #expect(try await backfill.fileNextBatch(limit: 10).attempted == 0)
    }

    @Test("a swatch list of only unreadable hexes files as empty")
    func unreadableHexesFileEmpty() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAnalyzed(
            services, into: refs.id, colors: ##"[{"hex":"nope","coverage":1.0}]"##)

        try await ColorBucketBackfill(services: services).fileNextBatch(limit: 10)
        #expect(try await services.colors(for: asset).isEmpty)
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: ColorPalette.version).isEmpty)
    }

    @Test("drain empties the queue in one call")
    func drainEmptiesTheQueue() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        for _ in 0..<7 {
            try await seedAnalyzed(
                services, into: refs.id, colors: ##"[{"hex":"#0000ff","coverage":1.0}]"##)
        }

        let total = try await ColorBucketBackfill(services: services)
            .drain(batchSize: 3)
        #expect(total.filed == 7)
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: ColorPalette.version).isEmpty)
    }

    /// A palette bump must re-queue everything, from the hex already on disk.
    /// This is the second thing the version marker buys, and the reason it is a
    /// version rather than a boolean.
    @Test("a newer palette version re-queues an already-filed asset")
    func paletteBumpRequeues() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAnalyzed(
            services, into: refs.id, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##)

        try await ColorBucketBackfill(services: services).drain()
        #expect(try await services.assetIDsNeedingColorBuckets(
            paletteVersion: ColorPalette.version).isEmpty)

        let queued = try await services.assetIDsNeedingColorBuckets(
            paletteVersion: ColorPalette.version + 1)
        #expect(queued == [asset])
    }

    /// Re-analysis produces NEW colors, so the old buckets are stale by
    /// definition. `upsertAnalysis` writes a fresh row whose palette version is
    /// nil, which re-queues the asset — the correct behaviour, and worth pinning
    /// because it falls out of the write rather than being asked for.
    @Test("re-analysis re-queues the asset")
    func reanalysisRequeues() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAnalyzed(
            services, into: refs.id, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##)
        try await ColorBucketBackfill(services: services).drain()

        try await services.upsertAnalysis(
            assetID: asset, colors: ##"[{"hex":"#0000ff","coverage":1.0}]"##,
            analyzerVersion: 2)

        #expect(try await services.assetIDsNeedingColorBuckets(
            paletteVersion: ColorPalette.version) == [asset])
    }

    @Test("nothing to do is not a failure")
    func emptyQueueIsFine() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let outcome = try await ColorBucketBackfill(services: services).drain()
        #expect(outcome.attempted == 0)
    }

    /// The pass exists so the filter has something to match. This is the only
    /// test that runs the whole chain — swatch JSON in, search hit out.
    @Test("after the pass, a color search finds the asset")
    func endToEnd() async throws {
        let env = try await makeEnv()
        defer { env.cleanup() }
        let services = env.services
        let refs = try await services.createCollection(name: "Refs")
        let blue = try await seedAnalyzed(
            services, into: refs.id, colors: ##"[{"hex":"#0000ff","coverage":0.9}]"##)
        try await seedAnalyzed(
            services, into: refs.id, colors: ##"[{"hex":"#00ff00","coverage":0.9}]"##)

        try await ColorBucketBackfill(services: services).drain()

        let hits = try await services.searchAssets(
            colorBuckets: [ColorBucket.blue.rawValue]).map(\.asset.id)
        #expect(hits == [blue])
    }
}
