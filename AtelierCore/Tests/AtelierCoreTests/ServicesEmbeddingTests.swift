// AtelierCore — semantic embedding persistence + backfill-candidate tests (047 · 3a).
//
// Exercises the storage seam the embedding analyzer rides: upsert/read round-trip,
// and the two candidate queries that drive re-embedding — `assetsNeedingEmbedding`
// (missing / model-stale / OCR-newer, + empty-corpus exclusion) and
// `embeddingsToReverify` (oldest-first content re-check for name/note drift).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: semantic embeddings (047 · 3a)")
struct ServicesEmbeddingTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    @discardableResult
    private func seed(
        _ services: AppServices, into c: UUID, title: String? = nil
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", title: title, capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    private let vec: [Float] = [0.6, 0.8] + Array(repeating: 0, count: 510)

    // MARK: upsert / read

    @Test("upsert then read round-trips vector, model version, and content hash")
    func upsertRoundTrip() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")

        try await services.upsertEmbedding(assetID: a, modelVersion: 1, contentHash: "h1", vector: vec)
        let got = try await services.embedding(for: a)
        #expect(got?.modelVersion == 1)
        #expect(got?.contentHash == "h1")
        #expect(got?.vectorFloats == vec)
    }

    @Test("upsert overwrites in place (one row per asset)")
    func upsertOverwrites() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")
        try await services.upsertEmbedding(assetID: a, modelVersion: 1, contentHash: "h1", vector: vec)
        try await services.upsertEmbedding(assetID: a, modelVersion: 2, contentHash: "h2",
                                           vector: [1, 0] + Array(repeating: Float(0), count: 510))
        let got = try await services.embedding(for: a)
        #expect(got?.modelVersion == 2)
        #expect(got?.contentHash == "h2")
        #expect(got?.vectorFloats.first == 1)
    }

    @Test("upsert on an absent asset throws notFound")
    func upsertAbsentAsset() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            try await services.upsertEmbedding(
                assetID: UUID(), modelVersion: 1, contentHash: "h", vector: vec)
        }
    }

    // MARK: assetsNeedingEmbedding

    @Test("a never-embedded asset with text is a candidate; empty-text asset is not")
    func candidatesMissingAndEmpty() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let withText = try await seed(services, into: c.id, title: "brutalist tower")
        let noText = try await seed(services, into: c.id, title: nil)  // empty corpus
        _ = noText

        let candidates = try await services.assetsNeedingEmbedding(modelVersion: 1, limit: 50)
        let ids = Set(candidates.map(\.assetID))
        #expect(ids.contains(withText))
        #expect(!ids.contains(noText))          // excluded — no title/name/note/ocr
        // The candidate carries the text the analyzer needs.
        #expect(candidates.first { $0.assetID == withText }?.title == "brutalist tower")
    }

    @Test("an up-to-date embedding drops out; a model bump re-qualifies it")
    func candidatesVersion() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")
        try await services.upsertEmbedding(assetID: a, modelVersion: 1, contentHash: "h1", vector: vec)

        // At the same model version, it's satisfied — not a candidate.
        #expect(try await services.assetsNeedingEmbedding(modelVersion: 1, limit: 50)
                    .allSatisfy { $0.assetID != a })
        // A newer model re-qualifies it, carrying the existing meta for the hash guard.
        let bumped = try await services.assetsNeedingEmbedding(modelVersion: 2, limit: 50)
        let row = bumped.first { $0.assetID == a }
        #expect(row != nil)
        #expect(row?.existingModelVersion == 1)
        #expect(row?.existingContentHash == "h1")
    }

    @Test("OCR arriving after the embedding re-qualifies the asset")
    func candidatesOCRNewer() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")
        try await services.upsertEmbedding(assetID: a, modelVersion: 1, contentHash: "h1", vector: vec)
        // Not a candidate yet…
        #expect(try await services.assetsNeedingEmbedding(modelVersion: 1, limit: 50)
                    .allSatisfy { $0.assetID != a })
        // …until OCR lands (analyzed_at > embedded_at).
        try await services.upsertAnalysis(assetID: a, ocrText: "helvetica specimen", analyzerVersion: 1)
        let after = try await services.assetsNeedingEmbedding(modelVersion: 1, limit: 50)
        let row = after.first { $0.assetID == a }
        #expect(row != nil)
        #expect(row?.ocrText == "helvetica specimen")   // OCR now in the corpus
    }

    // MARK: embeddingsToReverify + markEmbeddingVerified

    @Test("re-verify returns current-version embeddings oldest-first; verify rotates")
    func reverifyOrderingAndRotation() async throws {
        let (services, temp) = try makeServices(); defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "a")
        let b = try await seed(services, into: c.id, title: "b")
        try await services.upsertEmbedding(assetID: a, modelVersion: 1, contentHash: "ha", vector: vec)
        try await services.upsertEmbedding(assetID: b, modelVersion: 1, contentHash: "hb", vector: vec)

        // `a` was embedded first → oldest → appears before `b`.
        let order1 = try await services.embeddingsToReverify(modelVersion: 1, limit: 50).map(\.assetID)
        #expect(order1 == [a, b])

        // Verifying `a` (unchanged) bumps its embedded_at → it rotates to the back.
        try await services.markEmbeddingVerified(assetID: a)
        let order2 = try await services.embeddingsToReverify(modelVersion: 1, limit: 50).map(\.assetID)
        #expect(order2 == [b, a])
    }
}
