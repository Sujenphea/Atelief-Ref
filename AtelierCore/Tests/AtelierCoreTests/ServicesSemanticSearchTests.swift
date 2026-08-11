// AtelierCore — semantic (kNN) search tests (047 · 3a).
//
// Drives `semanticSearchAssets` with CONTROLLED vectors (no real embedder), so the
// assertions are about the ranking + scope machinery, not model quality:
//   • cosine order (nearest first) with a deterministic tiebreak;
//   • structured filters run FIRST (8A) — a nearer match out of scope is excluded;
//   • only the requested model version is comparable; empty query → empty; limit.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: semantic kNN search (047 · 3a)")
struct ServicesSemanticSearchTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    @discardableResult
    private func seed(_ services: AppServices, into c: UUID) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10, downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", title: "t", capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    /// Embed `id` with a controlled vector at model version 1.
    private func embed(_ services: AppServices, _ id: UUID, _ vector: [Float]) async throws {
        try await services.upsertEmbedding(
            assetID: id, modelVersion: 1, contentHash: "h", vector: vector)
    }

    private func ids(_ hits: [AssetDetail]) -> [UUID] { hits.map(\.asset.id) }

    @Test("ranks candidates by cosine similarity, nearest first")
    func ranksByCosine() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let near = try await seed(services, into: c.id)     // identical → cos 1
        let mid = try await seed(services, into: c.id)      // 45° → cos ~0.707
        let far = try await seed(services, into: c.id)      // orthogonal → cos 0
        try await embed(services, near, [1, 0, 0])
        try await embed(services, mid, [0.7071, 0.7071, 0])
        try await embed(services, far, [0, 1, 0])

        let hits = try await services.semanticSearchAssets(queryVector: [1, 0, 0], modelVersion: 1)
        #expect(ids(hits) == [near, mid, far])
    }

    @Test("structured scope is applied FIRST — a nearer out-of-scope match is excluded (8A)")
    func scopeFilteredBeforeRanking() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let scoped = try await services.createCollection(name: "Scoped")
        let other = try await services.createCollection(name: "Other")
        // The out-of-scope asset is a PERFECT match; the in-scope one is orthogonal.
        let inScopeFar = try await seed(services, into: scoped.id)
        let outOfScopeNear = try await seed(services, into: other.id)
        try await embed(services, inScopeFar, [0, 1, 0])
        try await embed(services, outOfScopeNear, [1, 0, 0])

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1, collectionIDs: [scoped.id])
        // Only the in-scope asset returns, though the excluded one was far nearer.
        #expect(ids(hits) == [inScopeFar])
    }

    @Test("only embeddings at the requested model version are comparable")
    func modelVersionGate() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        try await embed(services, a, [1, 0, 0])   // stored at version 1
        // A query at a newer model version finds nothing comparable.
        #expect(try await services.semanticSearchAssets(queryVector: [1, 0, 0], modelVersion: 2).isEmpty)
        #expect(try await ids(services.semanticSearchAssets(queryVector: [1, 0, 0], modelVersion: 1)) == [a])
    }

    @Test("an empty query vector returns nothing (no match-everything)")
    func emptyQuery() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        try await embed(services, a, [1, 0, 0])
        #expect(try await services.semanticSearchAssets(queryVector: [], modelVersion: 1).isEmpty)
    }

    @Test("limit caps the number of ranked results")
    func respectsLimit() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        for _ in 0..<5 {
            let id = try await seed(services, into: c.id)
            try await embed(services, id, [1, 0, 0])
        }
        let hits = try await services.semanticSearchAssets(queryVector: [1, 0, 0], modelVersion: 1, limit: 2)
        #expect(hits.count == 2)
    }

    @Test("tag scope composes with semantic ranking")
    func tagScope() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let tagged = try await seed(services, into: c.id)
        let untagged = try await seed(services, into: c.id)
        try await embed(services, tagged, [0, 1, 0])       // far from query
        try await embed(services, untagged, [1, 0, 0])     // near, but untagged
        let tag = try await services.applyTag("keep", to: tagged, source: .user)

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1, tagIDs: [tag.id])
        #expect(ids(hits) == [tagged])   // only the tagged one, despite being farther
    }

    // MARK: - Color scope (085 · C2)

    /// A color token stays selected in the search field when the user flips
    /// keyword → meaning. If this arm were missing, the filter they can still SEE
    /// would silently stop applying — the same trap `favoritesOnly` was added to
    /// this query to avoid.
    @Test("a color filter narrows semantic results too")
    func colorScope() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let red = try await seed(services, into: c.id)
        let blue = try await seed(services, into: c.id)
        try await embed(services, red, [0, 1, 0])    // far from the query
        try await embed(services, blue, [1, 0, 0])   // near, but the wrong color
        try await services.replaceColors(assetID: red, buckets: [3: 0.6], paletteVersion: 1)
        try await services.replaceColors(assetID: blue, buckets: [9: 0.6], paletteVersion: 1)

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1, colorBuckets: [3])
        #expect(ids(hits) == [red])
    }

    /// The coverage floor is the same query-time judgement here as in keyword
    /// search — a 5% smear of red is not a red picture in either mode.
    @Test("the coverage floor applies to the semantic arm")
    func colorCoverageFloor() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let faint = try await seed(services, into: c.id)
        try await embed(services, faint, [1, 0, 0])
        try await services.replaceColors(assetID: faint, buckets: [3: 0.05], paletteVersion: 1)

        #expect(try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1, colorBuckets: [3]).isEmpty)
        // Below the DEFAULT floor, not below every floor — the row is really there.
        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1,
            colorBuckets: [3], minimumColorCoverage: 0.01)
        #expect(ids(hits) == [faint])
    }

    /// An asset holding BOTH requested colors must rank once. A JOIN here would
    /// score it twice and hand the grid a duplicate card.
    @Test("two requested colors return the asset once")
    func colorAnyDoesNotDuplicate() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let both = try await seed(services, into: c.id)
        try await embed(services, both, [1, 0, 0])
        try await services.replaceColors(
            assetID: both, buckets: [3: 0.4, 9: 0.4], paletteVersion: 1)

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1, colorBuckets: [3, 9])
        #expect(ids(hits) == [both])
    }

    /// `.all` demands every requested color, exactly as it does for tags.
    @Test("colorMatch .all requires every requested bucket")
    func colorAllRequiresEvery() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let both = try await seed(services, into: c.id)
        let onlyRed = try await seed(services, into: c.id)
        try await embed(services, both, [1, 0, 0])
        try await embed(services, onlyRed, [1, 0, 0])
        try await services.replaceColors(
            assetID: both, buckets: [3: 0.4, 9: 0.4], paletteVersion: 1)
        try await services.replaceColors(assetID: onlyRed, buckets: [3: 0.9], paletteVersion: 1)

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1,
            colorBuckets: [3, 9], colorMatch: .all)
        #expect(ids(hits) == [both])
    }

    /// No color filter must not become "only assets that have derived colors" —
    /// the pass is bounded per launch, so mid-backfill assets have no rows at all.
    @Test("no color filter leaves un-derived assets rankable")
    func noColorFilterIsInert() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let bare = try await seed(services, into: c.id)
        try await embed(services, bare, [1, 0, 0])

        let hits = try await services.semanticSearchAssets(queryVector: [1, 0, 0], modelVersion: 1)
        #expect(ids(hits) == [bare])
    }
}
