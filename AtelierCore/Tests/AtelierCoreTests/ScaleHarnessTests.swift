//
//  ScaleHarnessTests.swift
//  AtelierCoreTests
//
//  010 · Phase 3 — a runnable scale-seeding + timing harness. Seeds N assets into
//  a temp library and times the hot library reads (collection listing + FTS
//  search). The DEFAULT N is small so CI stays fast; a developer bumps it for a
//  real pass:
//
//      ATELIER_SCALE_N=20000 swift test --filter ScaleHarness
//
//  It asserts CORRECTNESS at scale (no latency assertions — those would flake in
//  CI); the printed timings are the measurement. The full 10k–50k Instruments /
//  grid-scroll pass still runs on a dev machine (the app UI isn't exercised here).
//

import Foundation
import Testing
@testable import AtelierCore

@Suite("ScaleHarness")
struct ScaleHarnessTests {

    /// Seed count — env-overridable so CI runs a tiny smoke while a developer can
    /// drive a real 10k–50k pass without editing code.
    private var seedCount: Int {
        if let raw = ProcessInfo.processInfo.environment["ATELIER_SCALE_N"],
           let n = Int(raw), n > 0 { return n }
        return 300
    }

    @Test("seed N assets, then time the collection listing + FTS search")
    func seedAndTimeReads() async throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let services = AppServices(database: temp.database)
        let c = try await services.createCollection(name: "Scale")
        let n = seedCount

        // Seed: N byte-backed assets, each with a distinct hash + a searchable
        // title token ("ref<i>") plus a shared token ("swatch") for a broad match.
        let seedStart = ContinuousClock.now
        for i in 0..<n {
            let source = SourceDraft(
                platform: .web, originalURL: "https://e/\(i)",
                authorHandle: nil, authorName: nil,
                title: "ref\(i) swatch", capturedAt: Date())
            let draft = AssetDraft(
                kind: .image, blobHash: String(format: "%040x", i), mimeType: "image/png",
                width: 640, height: 480, duration: nil, fileSize: 2048,
                downloadState: .downloaded)
            _ = try await services.ingest(draft, from: source, into: c.id)
        }
        let seedElapsed = ContinuousClock.now - seedStart

        // Time: the full collection listing (P16 returns the whole array).
        let listStart = ContinuousClock.now
        let items = try await services.collectionItems(in: c.id, includeArchived: false)
        let listElapsed = ContinuousClock.now - listStart
        #expect(items.count == n)

        // Time: a single-token FTS search (paged; the shared token matches all).
        let searchStart = ContinuousClock.now
        let hits = try await services.searchAssets(text: "swatch", limit: 50)
        let searchElapsed = ContinuousClock.now - searchStart
        #expect(!hits.isEmpty)

        // A specific token resolves to exactly one asset even at scale.
        let one = try await services.searchAssets(text: "ref\(n - 1)")
        #expect(one.count == 1)

        // The manual grid order (14A). Reversing the whole collection is the
        // worst case the drag path can produce in one go — every row's
        // `manual_order` changes — and it is what the chunked `CASE` statement
        // replaced a per-row SELECT + UPDATE loop for. Measured BEFORE the
        // archive block so the row count is the full N.
        let reversed = Array(items.map(\.asset.id).reversed())
        let orderStart = ContinuousClock.now
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: reversed)
        let orderElapsed = ContinuousClock.now - orderStart
        let reordered = try await services.collectionItems(in: c.id, includeArchived: false)
        #expect(reordered.map(\.asset.id) == reversed)

        // Semantic search (15A). The measurement gate: `semanticSearchAssets`
        // decodes EVERY in-scope 512-float vector, scores it, fully sorts, then
        // takes `prefix(limit)`. Nothing here is indexed, so the cost is linear in
        // the corpus and the sort is `n log n` over the whole of it — which is why
        // the number below, not an argument, decides whether a resident corpus
        // cache is worth building (099 · P0b: the threshold is ~100 ms at 20k).
        //
        // Seeded before the archive block for the same reason the reorder is: an
        // archived asset is excluded at the candidate stage, so scoring after it
        // would measure three quarters of the library and flatter the number.
        let dims = 512
        let embedSeedStart = ContinuousClock.now
        for i in 0..<n {
            try await services.upsertEmbedding(
                assetID: items[i].asset.id, modelVersion: 1,
                contentHash: "h\(i)", vector: Self.vector(seed: i, dims: dims))
        }
        let embedSeedElapsed = ContinuousClock.now - embedSeedStart

        // Query with a vector that is nothing's exact neighbour, so the ranking
        // does real work rather than short-circuiting on an identical row.
        let query = Self.vector(seed: n * 7 + 3, dims: dims)
        let semanticStart = ContinuousClock.now
        let semantic = try await services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 50)
        let semanticElapsed = ContinuousClock.now - semanticStart
        #expect(semantic.count == min(50, n))

        // A second, warm run: the first pays SQLite's page-cache misses for a
        // table it has never read. Both numbers go in the changelog, because the
        // one a user feels is the warm one and the one a cold launch pays is the
        // other.
        let semanticWarmStart = ContinuousClock.now
        let semanticWarm = try await services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 50)
        let semanticWarmElapsed = ContinuousClock.now - semanticWarmStart
        #expect(semanticWarm.map(\.asset.id) == semantic.map(\.asset.id))

        // Scoped, so the number covers the shape the UI actually issues when a
        // collection is selected rather than only the library-wide one.
        let semanticScopedStart = ContinuousClock.now
        let semanticScoped = try await services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, collectionIDs: [c.id], limit: 50)
        let semanticScopedElapsed = ContinuousClock.now - semanticScopedStart
        #expect(semanticScoped.count == min(50, n))

        // The shelf (023 · A). Archive a QUARTER of the library, then time the
        // three reads the shelf changes:
        //
        //   • `shelfAssets` — the one genuinely new cost. Library-wide
        //     `archived_at IS NOT NULL` with a sort and NO collection scope, and
        //     the read whose row count only ever grows. It deliberately returns
        //     the full array with no cursor in v1; this number is what decides
        //     whether that stays true, which is the whole reason it is measured
        //     here rather than argued about.
        //   • `collectionItems` again — the browse read now carries the
        //     predicate, so the delta against the un-archived timing above is
        //     what the hot path actually pays.
        //   • `searchAssets` again — same question for the FTS path, where the
        //     conjunct sits alongside the MATCH.
        let toArchive = try await services.collectionItems(in: c.id, includeArchived: false)
            .prefix(n / 4)
            .map(\.asset.id)
        let archiveStart = ContinuousClock.now
        let archivedCount = try await services.archive(Array(toArchive))
        let archiveElapsed = ContinuousClock.now - archiveStart
        #expect(archivedCount == toArchive.count)

        let shelfStart = ContinuousClock.now
        let shelf = try await services.shelfAssets()
        let shelfElapsed = ContinuousClock.now - shelfStart
        #expect(shelf.count == toArchive.count)

        let listAfterStart = ContinuousClock.now
        let remaining = try await services.collectionItems(in: c.id, includeArchived: false)
        let listAfterElapsed = ContinuousClock.now - listAfterStart
        #expect(remaining.count == n - toArchive.count)

        let searchAfterStart = ContinuousClock.now
        let hitsAfter = try await services.searchAssets(text: "swatch", limit: 50)
        let searchAfterElapsed = ContinuousClock.now - searchAfterStart
        #expect(hitsAfter.allSatisfy { $0.asset.archivedAt == nil })

        print("""
        [scale] N=\(n)
          seed:            \(ms(seedElapsed)) ms  (\(ms(seedElapsed) / Double(n)) ms/asset)
          collectionItems: \(ms(listElapsed)) ms  (\(items.count) rows)
          search 'swatch': \(ms(searchElapsed)) ms  (page of \(hits.count))
          setGridOrder:    \(ms(orderElapsed)) ms  (\(reversed.count) rows reversed, chunks of 500)
        [scale] semantic (15A) dims=512, corpus=\(n)
          seed embeddings: \(ms(embedSeedElapsed)) ms  (\(ms(embedSeedElapsed) / Double(n)) ms/asset)
          semanticSearch:  \(ms(semanticElapsed)) ms  (cold, library-wide, top \(semantic.count))
          semanticSearch:  \(ms(semanticWarmElapsed)) ms  (warm, library-wide)
          semanticSearch:  \(ms(semanticScopedElapsed)) ms  (warm, scoped to one collection)
        [scale] archived=\(shelf.count) of \(n)
          archive:         \(ms(archiveElapsed)) ms  (one UPDATE)
          shelfAssets:     \(ms(shelfElapsed)) ms  (\(shelf.count) rows, no cursor)
          collectionItems: \(ms(listAfterElapsed)) ms  (\(remaining.count) rows, predicate on)
          search 'swatch': \(ms(searchAfterElapsed)) ms  (page of \(hitsAfter.count))
        """)
    }

    /// A deterministic, L2-normalized `dims`-wide vector for `seed` — the same
    /// shape a real embedder emits (unit length, so cosine reduces to a dot
    /// product), without pulling an embedder into Core's test target. Deterministic
    /// so two runs of the harness score identical corpora and the timings compare.
    private static func vector(seed: Int, dims: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        for d in 0..<dims {
            v[d] = Float(sin(Double(seed &* 31 &+ d &* 7) * 0.017))
        }
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1_000_000_000_000_000
    }
}
