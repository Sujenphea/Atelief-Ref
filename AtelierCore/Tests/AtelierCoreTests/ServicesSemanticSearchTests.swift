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
}
