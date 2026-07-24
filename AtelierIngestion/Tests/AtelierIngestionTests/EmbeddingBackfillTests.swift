// AtelierIngestion — semantic embedding backfill tests (047 · 3a)
//
// End-to-end over a real temp library (fake embedder): embed pending assets,
// prove resumability + idempotence, model-bump re-embedding, the 4A content-hash
// guard (OCR re-run with same text → touch not embed; rename → re-embed), and
// that a per-asset embed failure is counted, not fatal.

import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("EmbeddingBackfill")
struct EmbeddingBackfillTests {

    /// A deterministic embedder: any non-empty text → a fixed vector, unless its
    /// text contains a `failMarker` (→ nil, a per-asset failure).
    private struct FakeEmbedder: TextEmbedding {
        let modelVersion: Int
        var failMarker: String? = nil
        func embed(_ text: String) -> [Float]? {
            if let failMarker, text.contains(failMarker) { return nil }
            return [1, 0, 0]
        }
    }

    @discardableResult
    private func seed(_ env: TempPipeline, title: String?) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10, downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", title: title, capturedAt: Date())
        return try await env.services.ingest(draft, from: source, into: env.collectionID).asset.id
    }

    @Test("a batch embeds all pending assets; a second pass does nothing (resumable)")
    func embedsAllThenIdle() async throws {
        let env = try await makeTempPipeline(); defer { env.cleanup() }
        let ids = [try await seed(env, title: "brutalist tower"),
                   try await seed(env, title: "helvetica specimen")]
        let backfill = EmbeddingBackfill(services: env.services, embedder: FakeEmbedder(modelVersion: 1))

        let first = try await backfill.embedNextBatch(limit: 50)
        #expect(first.embedded == 2)
        #expect(first.failed == 0)
        for id in ids {
            let e = try #require(try await env.services.embedding(for: id))
            #expect(e.modelVersion == 1)
            #expect(e.vectorFloats == [1, 0, 0])
        }
        // Nothing stale now → the next batch attempts nothing.
        #expect(try await backfill.embedNextBatch(limit: 50).attempted == 0)
    }

    @Test("a model-version bump re-embeds the whole library")
    func modelBumpReembeds() async throws {
        let env = try await makeTempPipeline(); defer { env.cleanup() }
        _ = try await seed(env, title: "one")
        _ = try await EmbeddingBackfill(services: env.services, embedder: FakeEmbedder(modelVersion: 1)).embedAll()

        let v2 = EmbeddingBackfill(services: env.services, embedder: FakeEmbedder(modelVersion: 2))
        let out = try await v2.embedNextBatch(limit: 50)
        #expect(out.embedded == 1)
    }

    @Test("OCR re-run with the SAME text is a touch, not a re-embed (4A guard)")
    func ocrUnchangedIsTouch() async throws {
        let env = try await makeTempPipeline(); defer { env.cleanup() }
        let id = try await seed(env, title: "poster")
        let backfill = EmbeddingBackfill(services: env.services, embedder: FakeEmbedder(modelVersion: 1))
        _ = try await backfill.embedAll()

        // OCR lands (new text) → re-embed.
        try await env.services.upsertAnalysis(assetID: id, ocrText: "grid system", analyzerVersion: 1)
        #expect(try await backfill.embedNextBatch(limit: 50).embedded == 1)

        // OCR re-runs with the SAME text (analyzed_at bumps, hash unchanged) → the
        // asset re-qualifies but is TOUCHED, not embedded, and then drops out.
        try await env.services.upsertAnalysis(assetID: id, ocrText: "grid system", analyzerVersion: 1)
        let touch = try await backfill.embedNextBatch(limit: 50)
        #expect(touch.embedded == 0)
        #expect(touch.skipped == 1)
        #expect(try await backfill.embedNextBatch(limit: 50).attempted == 0)  // no longer stale
    }

    @Test("re-verify re-embeds a renamed asset, touches an unchanged one (4A)")
    func reverifyCatchesRename() async throws {
        let env = try await makeTempPipeline(); defer { env.cleanup() }
        let id = try await seed(env, title: "chair")
        let backfill = EmbeddingBackfill(services: env.services, embedder: FakeEmbedder(modelVersion: 1))
        _ = try await backfill.embedAll()
        let hashBefore = try await env.services.embedding(for: id)?.contentHash

        // Unchanged → re-verify only touches.
        let quiet = try await backfill.reverifyNextBatch(limit: 50)
        #expect(quiet.embedded == 0)
        #expect(quiet.skipped == 1)

        // Rename changes the corpus → re-verify re-embeds with a new hash.
        try await env.services.setName("brutalist stairwell", for: id)
        let loud = try await backfill.reverifyNextBatch(limit: 50)
        #expect(loud.embedded == 1)
        #expect(try await env.services.embedding(for: id)?.contentHash != hashBefore)
    }

    @Test("a per-asset embed failure is counted, not fatal")
    func failureIsNotFatal() async throws {
        let env = try await makeTempPipeline(); defer { env.cleanup() }
        _ = try await seed(env, title: "good one")
        _ = try await seed(env, title: "BROKEN item")
        let backfill = EmbeddingBackfill(
            services: env.services, embedder: FakeEmbedder(modelVersion: 1, failMarker: "BROKEN"))

        let out = try await backfill.embedNextBatch(limit: 50)
        #expect(out.embedded == 1)   // the good one
        #expect(out.failed == 1)     // the broken one, counted + skipped
    }
}
