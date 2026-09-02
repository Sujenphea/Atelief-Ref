// AtelierCore — the resident corpus, at the service level (099 · P0b).
//
// `EmbeddingCorpusTests` covers the pure pieces. This file covers the thing that
// actually has to be true: **the cached query returns what the un-cached one
// returned**, and the two writers that can change a vector clear the cache.
//
// The reference implementation below is not a paraphrase. It is P0's
// `semanticSearchAssets` body transcribed — the same SQL scope, the same
// per-row BLOB decode, the same `vDSP_dotpr`, the same FULL sort by (score
// descending, uuidString ascending), the same `prefix(limit)`. Every equivalence
// assertion compares against it, so "same top-k" means same against the code
// that was replaced rather than against the test author's memory of it.
//
// The corpus is deliberately built with heavy TIES: seven distinct vectors
// shared across forty assets, so the tiebreak is exercised at every k rather
// than being a path the data never reaches.

import Accelerate
import Foundation
import GRDB
import Testing
@testable import AtelierCore

@Suite("Services: the resident semantic corpus (099 · P0b)")
struct ServicesSemanticCorpusTests {

    // MARK: - Fixture

    private static let dims = 8

    /// Seven distinct 8-float vectors. Assets share them modulo 7, so exact
    /// score ties are the common case, not the exception.
    private static func vector(_ slot: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        for d in 0..<dims {
            v[d] = Float(sin(Double(slot * 13 + d * 5) * 0.31))
        }
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private struct Library {
        let services: AppServices
        let temp: TempDatabase
        /// Every seeded asset, in seed order.
        let assets: [UUID]
        let collectionA: UUID
        let collectionB: UUID
        /// The assets embedded at model version 2 (the tail).
        let atVersionTwo: [UUID]
        /// The assets put on the shelf.
        let archived: [UUID]
    }

    private func seed(count: Int = 40) async throws -> Library {
        let temp = try makeTempDatabase()
        let services = AppServices(database: temp.database)
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")

        var assets: [UUID] = []
        for i in 0..<count {
            let unique = String(format: "%040x", i)
            let draft = AssetDraft(
                kind: .image, blobHash: unique, mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 10,
                downloadState: .downloaded)
            let source = SourceDraft(
                platform: .web, originalURL: "https://e/\(i)", title: "t\(i)",
                capturedAt: Date())
            let id = try await services.ingest(
                draft, from: source, into: i < count / 2 ? a.id : b.id).asset.id
            assets.append(id)
        }

        // Model version 1 for all but the last five, which get version 2 — a
        // library mid-model-upgrade, and the fixture for "one version cannot read
        // the other's corpus".
        let split = count - 5
        for (i, id) in assets.enumerated() {
            try await services.upsertEmbedding(
                assetID: id, modelVersion: i < split ? 1 : 2,
                contentHash: "h\(i)", vector: Self.vector(i % 7))
        }
        // Favourites and the shelf, so the structured scope has something to do.
        for (i, id) in assets.enumerated() where i % 3 == 0 {
            _ = try await services.setFavorite(true, for: id)
        }
        let archived = assets.enumerated().filter { $0.offset % 5 == 4 }.map(\.element)
        _ = try await services.archive(archived)

        return Library(
            services: services, temp: temp, assets: assets,
            collectionA: a.id, collectionB: b.id,
            atVersionTwo: Array(assets.suffix(5)), archived: archived)
    }

    // MARK: - The reference: P0's implementation, transcribed

    /// Rank exactly as `semanticSearchAssets` did BEFORE the corpus cache: select
    /// every in-scope `(asset_id, vector)` pair, decode each BLOB, dot-product it
    /// against the query, sort the whole thing, take a prefix.
    private func reference(
        _ services: AppServices,
        query: [Float],
        modelVersion: Int,
        collectionIDs: [UUID] = [],
        favoritesOnly: Bool = false,
        limit: Int = 50
    ) async throws -> [UUID] {
        guard !query.isEmpty else { return [] }
        let clampedLimit = min(max(limit, 1), 500)
        let distinctCollectionIDs = Array(Set(collectionIDs))
        return try await services.read { db in
            var sql = """
                SELECT e.asset_id AS asset_id, e.vector AS vector
                FROM asset_embedding e
                JOIN asset a ON a.id = e.asset_id
                """
            var conditions = ["e.model_version = ?"]
            var args: [DatabaseValueConvertible] = [modelVersion]
            if !distinctCollectionIDs.isEmpty {
                let marks = Array(repeating: "?", count: distinctCollectionIDs.count)
                    .joined(separator: ", ")
                conditions.append("""
                    a.id IN (SELECT asset_id FROM collection_item WHERE collection_id IN (\(marks)))
                    """)
                args.append(contentsOf: distinctCollectionIDs.map { $0.uuidString.lowercased() })
            }
            if favoritesOnly { conditions.append("a.is_favorite = 1") }
            conditions.append("a.archived_at IS NULL")
            sql += "\nWHERE " + conditions.joined(separator: " AND ")

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let dims = query.count
            var scored: [(id: UUID, score: Float)] = []
            for row in rows {
                guard let idString: String = row["asset_id"],
                      let id = UUID(uuidString: idString),
                      let data: Data = row["vector"] else { continue }
                let vector = AssetEmbedding.vectorFloats(data)
                guard vector.count == dims else { continue }
                var score: Float = 0
                vDSP_dotpr(query, 1, vector, 1, &score, vDSP_Length(dims))
                scored.append((id, score))
            }
            scored.sort {
                $0.score != $1.score ? $0.score > $1.score
                    : $0.id.uuidString < $1.id.uuidString
            }
            return scored.prefix(clampedLimit).map(\.id)
        }
    }

    private func ids(_ hits: [AssetDetail]) -> [UUID] { hits.map(\.asset.id) }

    // MARK: - The load-bearing test

    /// **The one that matters.** Same members, same order, same ties, at six
    /// values of k across four scopes — sixty-odd comparisons against the code
    /// this phase deleted.
    @Test("the cached path returns exactly what the un-cached path returned")
    func matchesTheUncachedPath() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        // A query that is nothing's exact neighbour, so the ranking does real
        // work rather than short-circuiting on an identical row.
        let query = Self.vector(11)

        // Non-vacuity: every comparison below is `[] == []` unless the fixture
        // really produces a full ranking, and a scope that quietly returned
        // nothing would make this whole test pass while asserting nothing.
        let wide = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        #expect(wide.count == 28)     // 35 at version 1, less the 7 archived among them
        #expect(try await !ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1,
            collectionIDs: [lib.collectionB], favoritesOnly: true, limit: 500)).isEmpty)

        for k in [0, 1, 3, 7, 50, 500] {
            // 1. Library-wide.
            #expect(
                try await ids(lib.services.semanticSearchAssets(
                    queryVector: query, modelVersion: 1, limit: k))
                    == (try await reference(
                        lib.services, query: query, modelVersion: 1, limit: k)),
                "library-wide, k=\(k)")

            // 2. Scoped to one collection.
            #expect(
                try await ids(lib.services.semanticSearchAssets(
                    queryVector: query, modelVersion: 1,
                    collectionIDs: [lib.collectionA], limit: k))
                    == (try await reference(
                        lib.services, query: query, modelVersion: 1,
                        collectionIDs: [lib.collectionA], limit: k)),
                "collection A, k=\(k)")

            // 3. Favourites only.
            #expect(
                try await ids(lib.services.semanticSearchAssets(
                    queryVector: query, modelVersion: 1,
                    favoritesOnly: true, limit: k))
                    == (try await reference(
                        lib.services, query: query, modelVersion: 1,
                        favoritesOnly: true, limit: k)),
                "favorites, k=\(k)")

            // 4. Both at once, over the other collection.
            #expect(
                try await ids(lib.services.semanticSearchAssets(
                    queryVector: query, modelVersion: 1,
                    collectionIDs: [lib.collectionB], favoritesOnly: true, limit: k))
                    == (try await reference(
                        lib.services, query: query, modelVersion: 1,
                        collectionIDs: [lib.collectionB], favoritesOnly: true, limit: k)),
                "collection B + favorites, k=\(k)")
        }
    }

    /// The ties are real, not a claim in a comment: forty assets over seven
    /// vectors means the top of the ranking is a block of equal scores, and the
    /// order inside it is decided entirely by the id tiebreak.
    @Test("the fixture really does tie, and the tied block is ordered by id")
    func fixtureActuallyTies() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        // Query WITH one of the stored vectors, so its whole equivalence class
        // scores 1.0 exactly.
        let query = Self.vector(3)
        let hits = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        let expected = try await reference(
            lib.services, query: query, modelVersion: 1, limit: 500)
        #expect(hits == expected)

        // The head of the list is the class of assets whose slot is 3, in id
        // order — more than one of them, or this test asserts nothing.
        let tied = lib.assets.enumerated()
            .filter { $0.offset % 7 == 3 && $0.offset < lib.assets.count - 5 }
            .map(\.element)
            .filter { !lib.archived.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        #expect(tied.count > 1)
        #expect(Array(hits.prefix(tied.count)) == tied)
    }

    // MARK: - Invalidation, writer by writer

    @Test("an embedding upsert invalidates: the next query sees the new vector")
    func upsertInvalidates() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)
        // Warm the corpus.
        let before = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 5))
        #expect(lib.services.corpusCache.isLoaded)
        let loadsAfterWarm = lib.services.corpusCache.statistics.loads

        // Pick a live asset that is NOT already at the top, and make it a perfect
        // match. Its position must change on the very next query.
        let promoted = try #require(lib.assets.enumerated().first {
            $0.offset % 7 != 0 && $0.offset < lib.assets.count - 5
                && !lib.archived.contains($0.element)
        }?.element)
        #expect(!before.prefix(1).contains(promoted))

        try await lib.services.upsertEmbedding(
            assetID: promoted, modelVersion: 1, contentHash: "promoted", vector: query)
        #expect(!lib.services.corpusCache.isLoaded)

        let after = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 5))
        #expect(lib.services.corpusCache.statistics.loads == loadsAfterWarm + 1)
        #expect(after.contains(promoted))
        // And it agrees with the un-cached path over the NEW data.
        #expect(after == (try await reference(
            lib.services, query: query, modelVersion: 1, limit: 5)))
    }

    @Test("an asset delete invalidates: the deleted id never comes back")
    func deleteInvalidates() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)
        let before = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        let doomed = try #require(before.first)

        _ = try await lib.services.deleteAssets([doomed])
        #expect(!lib.services.corpusCache.isLoaded)

        let after = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        #expect(!after.contains(doomed))
        #expect(after.count == before.count - 1)
        #expect(after == (try await reference(
            lib.services, query: query, modelVersion: 1, limit: 500)))
    }

    @Test("the recoverable delete invalidates too")
    func recoverableDeleteInvalidates() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)
        let before = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        let doomed = try #require(before.first)

        _ = try await lib.services.deleteAssetsRecoverable([doomed])
        #expect(!lib.services.corpusCache.isLoaded)
        #expect(try await !ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500)).contains(doomed))
    }

    /// The property the whole design rests on: the cache is never asked what
    /// EXISTS. Here the corpus is warm and NOTHING invalidates it — archiving is
    /// not one of the two writers — and the archived asset still disappears,
    /// because membership is decided by the live SQL pre-filter on every call.
    ///
    /// If this ever fails, the cache has started answering a question that is not
    /// its own, and the two-writer invalidation is no longer sufficient.
    @Test("a warm corpus cannot show an asset the live scope excludes")
    func warmCorpusCannotResurrect() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)
        let before = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        let shelved = try #require(before.first)
        let loadsAfterWarm = lib.services.corpusCache.statistics.loads

        _ = try await lib.services.archive([shelved])
        // Deliberately NOT invalidated — archive is not an embedding writer.
        #expect(lib.services.corpusCache.isLoaded)

        let after = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        #expect(!after.contains(shelved))
        #expect(lib.services.corpusCache.statistics.loads == loadsAfterWarm)
    }

    /// Same argument for membership: moving an asset out of the scoped collection
    /// changes the answer with the corpus untouched.
    @Test("a warm corpus does not freeze collection membership")
    func warmCorpusDoesNotFreezeMembership() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)
        let inA = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1,
            collectionIDs: [lib.collectionA], limit: 500))
        let moved = try #require(inA.first)

        try await lib.services.moveAssets([moved], from: lib.collectionA, to: lib.collectionB)
        #expect(lib.services.corpusCache.isLoaded)

        #expect(try await !ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1,
            collectionIDs: [lib.collectionA], limit: 500)).contains(moved))
        #expect(try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1,
            collectionIDs: [lib.collectionB], limit: 500)).contains(moved))
    }

    // MARK: - Model versions

    @Test("a different model version does not read the other version's corpus")
    func versionsDoNotMix() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(0)

        let atOne = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        #expect(!atOne.isEmpty)
        #expect(atOne.allSatisfy { !lib.atVersionTwo.contains($0) })

        let atTwo = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 2, limit: 500))
        #expect(!atTwo.isEmpty)
        #expect(atTwo.allSatisfy { lib.atVersionTwo.contains($0) })
        #expect(atTwo == (try await reference(
            lib.services, query: query, modelVersion: 2, limit: 500)))

        // Flipping back reloads rather than serving version 2's matrix.
        #expect(try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500)) == atOne)
        #expect(lib.services.corpusCache.resident?.modelVersion == 1)
    }

    @Test("a model version nothing was embedded at returns nothing")
    func unknownVersionIsEmpty() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        #expect(try await lib.services.semanticSearchAssets(
            queryVector: Self.vector(0), modelVersion: 99).isEmpty)
    }

    // MARK: - Degenerate corpora

    @Test("an empty corpus, a corpus smaller than k, and k = 0")
    func degenerateCorpora() async throws {
        // Empty: assets exist, nothing is embedded.
        let temp = try makeTempDatabase(); defer { temp.cleanup() }
        let services = AppServices(database: temp.database)
        let c = try await services.createCollection(name: "Refs")
        let draft = AssetDraft(
            kind: .image, blobHash: String(repeating: "a", count: 40), mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 10, downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/1", title: "t", capturedAt: Date())
        let only = try await services.ingest(draft, from: source, into: c.id).asset.id

        let query = Self.vector(0)
        #expect(try await services.semanticSearchAssets(
            queryVector: query, modelVersion: 1).isEmpty)

        // Smaller than k: one vector, k = 50.
        try await services.upsertEmbedding(
            assetID: only, modelVersion: 1, contentHash: "h", vector: query)
        #expect(try await ids(services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 50)) == [only])

        // k = 0. The clamp is `1...500` and was BEFORE this phase too, so zero
        // still means one — asserted so the cached path cannot quietly change it.
        #expect(try await ids(services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 0)) == [only])
        #expect(try await services.semanticSearchAssets(
            queryVector: [], modelVersion: 1).isEmpty)
    }

    // MARK: - A malformed vector on disk

    /// A stored vector of the wrong width is **skipped, not rejected**: it is
    /// derived data a re-embed rewrites, so refusing the whole query over one bad
    /// row would take meaning search down for the library until someone noticed.
    /// It is also what the un-cached path did per row.
    ///
    /// The corpus is keyed by width as well as model version, so the same bad row
    /// is simply a member of a DIFFERENT corpus — which the second half asserts,
    /// because "skipped" must not mean "unreachable forever".
    @Test("a wrong-width vector on disk is skipped, and the rest still ranks")
    func malformedVectorIsSkipped() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let corrupt = lib.assets[0]

        // Overwrite one row's BLOB with a 4-float vector, behind the funnel — the
        // shape a half-finished re-embed at a new width would leave, which no
        // public API can produce.
        try await lib.services.write { db in
            try db.execute(
                sql: "UPDATE asset_embedding SET vector = ? WHERE asset_id = ?",
                arguments: [
                    AssetEmbedding.encode([1, 0, 0, 0]), corrupt.uuidString.lowercased(),
                ])
        }
        lib.services.corpusCache.invalidate()

        let query = Self.vector(0)
        let hits = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 500))
        #expect(!hits.contains(corrupt))
        #expect(!hits.isEmpty)
        #expect(hits == (try await reference(
            lib.services, query: query, modelVersion: 1, limit: 500)))

        // A query of THAT width finds it, and only it: the widths are separate
        // corpora, not a corpus and a graveyard.
        let narrow = try await ids(lib.services.semanticSearchAssets(
            queryVector: [1, 0, 0, 0], modelVersion: 1, limit: 500))
        #expect(narrow == [corrupt])
    }

    // MARK: - Warmth

    @Test("the corpus is loaded once and reused by every query after it")
    func warmQueriesDoNotReload() async throws {
        let lib = try await seed(); defer { lib.temp.cleanup() }
        let query = Self.vector(2)
        let first = try await ids(lib.services.semanticSearchAssets(
            queryVector: query, modelVersion: 1, limit: 10))
        for _ in 0..<5 {
            #expect(try await ids(lib.services.semanticSearchAssets(
                queryVector: query, modelVersion: 1, limit: 10)) == first)
        }
        #expect(lib.services.corpusCache.statistics.loads == 1)
        #expect(lib.services.corpusCache.statistics.hits == 5)
        #expect(lib.services.corpusCache.resident?.dimensions == Self.dims)
    }
}
