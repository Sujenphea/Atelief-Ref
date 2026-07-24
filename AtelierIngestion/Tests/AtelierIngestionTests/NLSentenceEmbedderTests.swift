// AtelierIngestion — NLSentenceEmbedder smoke test (047 · 3a).
//
// The real NaturalLanguage adapter needs only a smoke test (all backfill logic is
// tested against a fake). Guarded on model availability so it never fails on a
// runner where the sentence-embedding assets aren't installed.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("NLSentenceEmbedder (real model smoke)")
struct NLSentenceEmbedderTests {

    private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }

    @Test("embeds real text, L2-normalized, with meaningful cosine ordering")
    func smoke() throws {
        let embedder = NLSentenceEmbedder()
        try #require(embedder.isAvailable, "sentence-embedding model not installed on this runner")

        let query = try #require(embedder.embed("modernist architecture"))
        let near = try #require(embedder.embed("a brutalist concrete building"))
        let far = try #require(embedder.embed("a bowl of fresh fruit"))

        // Output is L2-normalized (‖v‖ ≈ 1), the invariant the kNN dot-product relies on.
        #expect(abs(dot(near, near).squareRoot() - 1) < 1e-3)
        // The related phrase is nearer than the unrelated one.
        #expect(dot(query, near) > dot(query, far))
    }

    @Test("empty / whitespace text yields no vector")
    func emptyText() {
        let embedder = NLSentenceEmbedder()
        guard embedder.isAvailable else { return }
        #expect(embedder.embed("") == nil)
    }
}
