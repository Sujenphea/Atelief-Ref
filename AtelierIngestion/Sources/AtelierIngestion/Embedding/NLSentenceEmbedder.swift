// AtelierIngestion — NaturalLanguage sentence embedder (047 · 3a · 1A)
//
// The production ``TextEmbedding`` seam: Apple's built-in
// `NLEmbedding.sentenceEmbedding` (512-dim, on every Apple platform — no model to
// bundle). Deliberately thin; all the backfill logic lives behind the protocol,
// so this adapter needs only a smoke test and everything else runs against a fake.
//
// This is the repo's first use of NaturalLanguage. It's a system framework (like
// Vision in the OCR adapter), imported directly with no SPM dependency.

import Foundation
import NaturalLanguage

/// Embeds text with `NLEmbedding.sentenceEmbedding` and L2-normalizes the result
/// (so query-time cosine is a dot product). The loaded `NLEmbedding` is immutable
/// after creation and its `vector(for:)` is a pure read, so wrapping it in an
/// `@unchecked Sendable` final class is safe — the same rationale that lets the
/// OCR adapter be `Sendable`.
public final class NLSentenceEmbedder: TextEmbedding, @unchecked Sendable {
    public let modelVersion: Int
    private let embedding: NLEmbedding?

    /// - Parameter modelVersion: the version stamped on produced embeddings.
    ///   Bump when the embedding pipeline changes (re-embeds the whole library).
    public init(modelVersion: Int = NLSentenceEmbedder.currentModelVersion) {
        self.modelVersion = modelVersion
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// The current production model version (single source of truth, mirroring
    /// `AssetAnalyzer.analyzerVersion`).
    public static let currentModelVersion = 1

    /// Whether the sentence-embedding model is available on this device — the
    /// backfill / smoke test guard.
    public var isAvailable: Bool { embedding != nil }

    public func embed(_ text: String) -> [Float]? {
        guard let embedding, let raw = embedding.vector(for: text), !raw.isEmpty else {
            return nil
        }
        var vector = raw.map { Float($0) }
        // L2-normalize; a zero-norm vector (degenerate) is treated as no vector.
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        for i in vector.indices { vector[i] /= norm }
        return vector
    }
}
