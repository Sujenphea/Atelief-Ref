// AtelierIngestion — text-embedding seam (044 · 047 · search Phase 3a)
//
// The testable boundary for on-device semantic embedding, mirroring
// ``TextRecognizing`` (the OCR seam): all the backfill logic runs against this
// protocol, so tests inject a deterministic fake and the real NaturalLanguage
// model needs only a smoke test.

import Foundation

/// Turns text into a dense semantic vector for cosine search (047 · 3a).
///
/// Implementations MUST return an **L2-normalized** vector, so cosine similarity
/// reduces to a plain dot product at query time (the kNN hot path). `modelVersion`
/// identifies the model that produced the vector, so an upgrade re-embeds via the
/// `WHERE model_version < …` backfill scan.
public protocol TextEmbedding: Sendable {
    /// The version of the model this embedder produces (drives re-embedding).
    var modelVersion: Int { get }

    /// Embed `text` into an L2-normalized vector, or `nil` when the model is
    /// unavailable or the text yields no usable vector (e.g. empty / all
    /// out-of-vocabulary). A `nil` here is a per-asset skip, never fatal.
    func embed(_ text: String) -> [Float]?
}
