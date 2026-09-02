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
import GRDB
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

        // 071 · Phase 0a (099 · P3) — SPLIT that number.
        //
        // 071 measured the TOTAL at every N (2k → 64.75 ms, 5k → 149.29, 10k →
        // 305.98, 20k → 750.05) and never the parts, so §6.1's narrow row rested
        // on a hypothesis — "decode dominates the SQL scan" — with a number
        // attached to the whole read rather than to the half it blames. These
        // probes run over the SAME rows, in ONE snapshot, in the order a row
        // actually travels. See ``splitCollectionRead(services:collectionID:)``.
        let split = try await Self.splitCollectionRead(services: services, collectionID: c.id)
        #expect(split.rowCount == n)
        #expect(split.narrowCount == n)
        #expect(split.jsonCount == n)

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

        // Semantic search (15A, then 099 · P0b). P0 measured this decoding EVERY
        // in-scope 512-float BLOB per query, scoring it, fully sorting, then
        // taking `prefix(limit)` — 1,547 ms at 20,000, fifteen times the ~100 ms
        // threshold, which is what scheduled P0b.
        //
        // The three timings below now mean three different things, and the
        // difference IS the measurement:
        //
        //   • COLD — the first query of the process. Pays the corpus load: one
        //     pass over `asset_embedding` building a 2 KB × N resident matrix.
        //     For a user who searches once per launch this is the real number.
        //   • WARM — every query after it. Intersects the live candidate ids with
        //     the resident matrix, dot-products, and tops-k by partial selection.
        //   • SCOPED — the same, with a collection conjunct in the pre-filter.
        //
        // Seeded before the archive block for the same reason the reorder is: an
        // archived asset is excluded at the candidate stage, so scoring after it
        // would measure three quarters of the library and flatter the number.
        //
        // Every `upsertEmbedding` invalidates, so the loop below leaves the cache
        // cold — which is exactly what the cold timing wants.
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

        // A second, warm run: the first pays the corpus load (and, before P0b,
        // SQLite's page-cache misses for a table it had never read). Both numbers
        // go in the changelog, because the one a user feels repeatedly is the warm
        // one and the one a cold launch pays is the other.
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

        // What the speed cost in memory, reported rather than asserted — 099 · P0b
        // states the number and this is where it comes from.
        let resident = services.corpusCache.resident
        #expect(resident?.count == n)
        let residentRows = resident?.count ?? 0
        let residentMB = Double(resident?.approximateBytes ?? 0) / 1_048_576

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
          collectionItems: \(ms(listElapsed)) ms  (\(items.count) rows, COLD — first read of the join)
          search 'swatch': \(ms(searchElapsed)) ms  (page of \(hits.count))
          setGridOrder:    \(ms(orderElapsed)) ms  (\(reversed.count) rows reversed, chunks of 500)
        [scale] collectionItems split (071 · Phase 0a) N=\(n), warm, one snapshot
          total (warm):    \(split.warmTotalMs) ms  (`collectionItems`, the number 071 measured)
          1 scan:          \(split.scanMs) ms  (SELECT COUNT(*) over the identical join — no decode)
          2 row fetch:     \(split.rowsMs) ms  (Row.fetchAll over the identical request)
          3 struct decode: \(split.decodeMs) ms  (CollectionItemRow.fetchAll — UUIDs + raw_metadata)
          4 publish/map:   \(split.publishMs) ms  (decoded rows → [CollectionItemDetail])
          ── deltas ──
          query:           \(split.queryDeltaMs) ms  (= scan)
          row decode:      \(split.rowDeltaMs) ms  (= row fetch − scan)
          struct decode:   \(split.structDeltaMs) ms  (= struct decode − row fetch)
          publish:         \(split.publishMs) ms  (the map alone)
          ── the hypothesis, isolated ──
          raw_metadata:    \(split.jsonMs) ms  (JSONValue.fromDatabaseValue over \(split.jsonCount) blobs, \(split.jsonBytes) B)
          narrow row §6.1: \(split.narrowMs) ms  (\(split.narrowCount) rows, 10 columns, hand-decoded)
        [scale] semantic (15A / P0b) dims=512, corpus=\(n)
          seed embeddings: \(ms(embedSeedElapsed)) ms  (\(ms(embedSeedElapsed) / Double(n)) ms/asset)
          semanticSearch:  \(ms(semanticElapsed)) ms  (COLD — includes the corpus load, library-wide, top \(semantic.count))
          semanticSearch:  \(ms(semanticWarmElapsed)) ms  (warm, library-wide)
          semanticSearch:  \(ms(semanticScopedElapsed)) ms  (warm, scoped to one collection)
          resident corpus: \(residentRows) rows, \(residentMB) MB  (2 KB per vector)
        [scale] archived=\(shelf.count) of \(n)
          archive:         \(ms(archiveElapsed)) ms  (one UPDATE)
          shelfAssets:     \(ms(shelfElapsed)) ms  (\(shelf.count) rows, no cursor)
          collectionItems: \(ms(listAfterElapsed)) ms  (\(remaining.count) rows, predicate on)
          search 'swatch': \(ms(searchAfterElapsed)) ms  (page of \(hitsAfter.count))
        """)
    }

    // MARK: - 071 · Phase 0a — the collection-read split

    /// Where the milliseconds of one `collectionItems` call actually go.
    ///
    /// Every field is milliseconds over the SAME row set; the `*Delta` values are
    /// the stage-by-stage differences the plan asks for (query / row decode /
    /// publish). `narrowMs` prices §6.1's projection and `jsonMs` prices the one
    /// thing §3's hypothesis names — `raw_metadata` through `JSONDecoder`, once
    /// per row — so the gate is decided on a measurement rather than on a guess.
    struct ReadSplit: Sendable {
        var warmTotalMs = 0.0
        var scanMs = 0.0
        var rowsMs = 0.0
        var decodeMs = 0.0
        var publishMs = 0.0
        var narrowMs = 0.0
        var jsonMs = 0.0
        var rowCount = 0
        var narrowCount = 0
        var jsonCount = 0
        var jsonBytes = 0

        /// The scan: SQLite finding every row and decoding nothing.
        var queryDeltaMs: Double { scanMs }
        /// Materializing each found row's columns into a GRDB `Row`.
        var rowDeltaMs: Double { max(0, rowsMs - scanMs) }
        /// Turning those `Row`s into `CollectionItem` / `Asset` / `Source`:
        /// ~6 UUID parses per row (C5 stores ids as lowercase TEXT) plus one
        /// `JSONDecoder` pass over `raw_metadata`.
        var structDeltaMs: Double { max(0, decodeMs - rowsMs) }
    }

    /// §6.1's proposed narrow row, hand-decoded — the ten columns 071 §4 says the
    /// all-N consumers (masonry frames, selection arithmetic, the diffable
    /// snapshot, `PostGroups`) genuinely read.
    ///
    /// `rawMetadata` stays a `String` here deliberately: §6.3 flags the carousel
    /// index as living inside that JSON, and leaving it undecoded is the *cheapest*
    /// shape the narrow row could take. If the narrow row is not decisively faster
    /// even at its cheapest, no shape of it is.
    private struct NarrowRow {
        let itemID: String
        let assetID: String
        let kind: String
        let width: Int?
        let height: Int?
        let isFavorite: Bool
        let viewCount: Int
        let blobHash: String?
        let originalURL: String?
        let rawMetadata: String
    }

    /// Run every stage of the collection read over one snapshot of `collectionID`,
    /// warm, and report where the time went.
    ///
    /// **One `read` block, not six.** Each probe would otherwise pay its own actor
    /// hop and its own pool checkout, and at the 2 k end those are a visible share
    /// of a 65 ms total — the split would then measure the harness. Inside the
    /// block the connection, the page cache and the statement cache are shared,
    /// which is exactly the state the app's second reload of a collection is in.
    ///
    /// The COLD number stays where it was (the caller's first `collectionItems`);
    /// this reports a warm total beside the stages so the parts sum against a
    /// total measured under the same conditions rather than against a colder one.
    static func splitCollectionRead(
        services: AppServices, collectionID: UUID
    ) async throws -> ReadSplit {
        let key = collectionID.uuidString.lowercased()
        return try await services.read { db -> ReadSplit in
            var out = ReadSplit()

            // The request `collectionItems(in:sort:includeArchived:)` builds, to
            // the letter (AppServices+Collections.swift): required joins, the
            // un-archived filter on the join, `.manual` ordering.
            func request() -> QueryInterfaceRequest<CollectionItemRow> {
                let assetJoin = CollectionItem.asset
                    .including(required: Asset.source)
                    .filter(Column("archived_at") == nil)
                return CollectionItem
                    .filter(Column("collection_id") == key)
                    .including(required: assetJoin)
                    .order(Column("manual_order"), Column("id"))
                    .asRequest(of: CollectionItemRow.self)
            }

            // Warm every page and every cached statement first, so stage 1 is not
            // the one that pays for all of them.
            _ = try CollectionItemRow.fetchAll(db, request())

            // 0 — the warm total, through the public shape: fetch + map.
            let totalStart = ContinuousClock.now
            let warmRows = try CollectionItemRow.fetchAll(db, request())
            let warmDetails = warmRows.map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
            out.warmTotalMs = scaleMillis(ContinuousClock.now - totalStart)
            out.rowCount = warmDetails.count

            // 1 — scan only. COUNT(*) over the identical join: SQLite visits every
            // row and hands back one integer, so nothing is decoded.
            let scanSQL = """
                SELECT COUNT(*)
                FROM collection_item ci
                JOIN asset a ON a.id = ci.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE ci.collection_id = ? AND a.archived_at IS NULL
                """
            _ = try Int.fetchOne(db, sql: scanSQL, arguments: [key])
            let scanStart = ContinuousClock.now
            let scanned = try Int.fetchOne(db, sql: scanSQL, arguments: [key])
            out.scanMs = scaleMillis(ContinuousClock.now - scanStart)
            #expect(scanned == out.rowCount)

            // 2 — the same request, stopping at GRDB `Row`s: every column of every
            // row materialized, no struct decode, no UUID parse, no JSON.
            let rowsStart = ContinuousClock.now
            let rawRows = try Row.fetchAll(db, request())
            out.rowsMs = scaleMillis(ContinuousClock.now - rowsStart)
            #expect(rawRows.count == out.rowCount)

            // 3 — the struct decode: `CollectionItemRow` (item + asset + source).
            let decodeStart = ContinuousClock.now
            let decoded = try CollectionItemRow.fetchAll(db, request())
            out.decodeMs = scaleMillis(ContinuousClock.now - decodeStart)
            #expect(decoded.count == out.rowCount)

            // 4 — publish: the map to the public, GRDB-free array that crosses the
            // boundary. Timed on already-decoded rows, so it is the map alone.
            let publishStart = ContinuousClock.now
            let published = decoded.map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
            out.publishMs = scaleMillis(ContinuousClock.now - publishStart)
            #expect(published.count == out.rowCount)

            // 5 — §6.1's narrow row, hand-decoded from raw SQL over the same join.
            let narrowSQL = """
                SELECT ci.id, ci.asset_id, a.kind, a.width, a.height, a.is_favorite,
                       a.view_count, a.blob_hash, s.original_url, s.raw_metadata
                FROM collection_item ci
                JOIN asset a ON a.id = ci.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE ci.collection_id = ? AND a.archived_at IS NULL
                ORDER BY ci.manual_order, ci.id
                """
            _ = try Row.fetchAll(db, sql: narrowSQL, arguments: [key])
            let narrowStart = ContinuousClock.now
            let narrow = try Row.fetchAll(db, sql: narrowSQL, arguments: [key]).map {
                NarrowRow(
                    itemID: $0["id"], assetID: $0["asset_id"], kind: $0["kind"],
                    width: $0["width"], height: $0["height"],
                    isFavorite: $0["is_favorite"], viewCount: $0["view_count"],
                    blobHash: $0["blob_hash"], originalURL: $0["original_url"],
                    rawMetadata: $0["raw_metadata"])
            }
            out.narrowMs = scaleMillis(ContinuousClock.now - narrowStart)
            out.narrowCount = narrow.count

            // 6 — the hypothesis, alone. Every source's `raw_metadata` TEXT put
            // through the EXACT production path (`JSONValue.fromDatabaseValue`,
            // i.e. a fresh `JSONDecoder` per row), with the fetch excluded.
            let blobs = try DatabaseValue.fetchAll(
                db, sql: """
                    SELECT s.raw_metadata
                    FROM collection_item ci
                    JOIN asset a ON a.id = ci.asset_id
                    JOIN source s ON s.id = a.source_id
                    WHERE ci.collection_id = ? AND a.archived_at IS NULL
                    """, arguments: [key])
            out.jsonBytes = blobs.reduce(0) { $0 + (String.fromDatabaseValue($1)?.utf8.count ?? 0) }
            let jsonStart = ContinuousClock.now
            var jsonDecoded = 0
            for blob in blobs where JSONValue.fromDatabaseValue(blob) != nil { jsonDecoded += 1 }
            out.jsonMs = scaleMillis(ContinuousClock.now - jsonStart)
            out.jsonCount = jsonDecoded

            return out
        }
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

    private func ms(_ d: Duration) -> Double { scaleMillis(d) }
}

/// `Duration` → milliseconds. File-scope (rather than a method on the suite) so
/// the `@Sendable` read block of ``ScaleHarnessTests/splitCollectionRead(services:collectionID:)``
/// can time its stages without capturing the suite value.
func scaleMillis(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000
        + Double(d.components.attoseconds) / 1_000_000_000_000_000
}
