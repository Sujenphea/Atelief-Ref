// AtelierIngestion — semantic embedding backfill orchestration (047 · 3a)
//
// Walks the assets whose text embedding is stale and embeds each through a
// ``TextEmbedding``, persisting via `AppServices.upsertEmbedding`. Mirrors
// ``AnalysisBackfill`` but needs NO blob store — the corpus is DB text (title /
// name / note / OCR), so it composes just `AppServices` + the embedder.
//
// Two drains, both resumable (staleness is a query, not a ledger):
//   • `embedNextBatch` — MISSING / model-stale / OCR-newer rows (the primary path).
//   • `reverifyNextBatch` — oldest-embedded rows, re-hashed to catch name/note
//     drift the timestamp-less `asset` table can't signal (4A). Unchanged rows are
//     just touched (`markEmbeddingVerified`) so they rotate out of the window.
//
// The 4A content-hash guard means an OCR re-run that didn't change the text is a
// touch, not a wasted embed. One bad asset never aborts a batch (004 discipline).
// Scheduling (idle QoS, pause-on-activity) is the app's concern, as with analysis.

import AtelierCore
import Foundation

/// The tally of one embedding-backfill run — honest partial-outcome reporting.
public struct EmbeddingBackfillOutcome: Sendable, Equatable {
    /// Assets embedded (or re-embedded) and persisted this run.
    public let embedded: Int
    /// Assets whose text was unchanged (content-hash match) — touched, not embedded.
    public let skipped: Int
    /// Assets that errored (no vector from the model, persistence race) and were
    /// skipped — the batch continued past them.
    public let failed: Int

    public init(embedded: Int, skipped: Int, failed: Int) {
        self.embedded = embedded
        self.skipped = skipped
        self.failed = failed
    }

    /// Total assets attempted this run.
    public var attempted: Int { embedded + skipped + failed }

    func adding(_ other: EmbeddingBackfillOutcome) -> EmbeddingBackfillOutcome {
        EmbeddingBackfillOutcome(
            embedded: embedded + other.embedded,
            skipped: skipped + other.skipped,
            failed: failed + other.failed)
    }
}

/// Runs the on-device semantic embedding backfill over a library (047 · 3a). A
/// `Sendable` value type composing `AppServices` + a ``TextEmbedding``.
public struct EmbeddingBackfill: Sendable {
    private let services: AppServices
    private let embedder: any TextEmbedding

    public init(services: AppServices, embedder: any TextEmbedding) {
        self.services = services
        self.embedder = embedder
    }

    /// Embed up to `limit` assets whose embedding is missing / model-stale /
    /// OCR-newer, at the embedder's model version. Idempotent + resumable.
    @discardableResult
    public func embedNextBatch(limit: Int) async throws -> EmbeddingBackfillOutcome {
        let candidates = try await services.assetsNeedingEmbedding(
            modelVersion: embedder.modelVersion, limit: limit)
        return try await process(candidates)
    }

    /// Re-verify up to `limit` already-embedded assets (oldest first) for text
    /// drift the timestamp-less `asset` can't signal (4A). Unchanged rows are
    /// touched so the window advances; changed ones (a rename) are re-embedded.
    @discardableResult
    public func reverifyNextBatch(limit: Int) async throws -> EmbeddingBackfillOutcome {
        let candidates = try await services.embeddingsToReverify(
            modelVersion: embedder.modelVersion, limit: limit)
        return try await process(candidates)
    }

    /// Drain the whole embedding backlog in `batchSize` chunks until no progress,
    /// returning the cumulative outcome (one-shot / test drain). Terminates when a
    /// batch attempts nothing (backlog empty) OR embeds nothing new (only touches /
    /// persistent failures remain — looping would spin).
    @discardableResult
    public func embedAll(batchSize: Int = 20) async throws -> EmbeddingBackfillOutcome {
        var total = EmbeddingBackfillOutcome(embedded: 0, skipped: 0, failed: 0)
        while true {
            let outcome = try await embedNextBatch(limit: batchSize)
            total = total.adding(outcome)
            if outcome.attempted == 0 || outcome.embedded == 0 { break }
        }
        return total
    }

    /// Embed / touch each candidate. Shared by both drains: the content-hash guard
    /// (4A) makes "text unchanged" a touch and "text changed" a re-embed, so the
    /// same body correctly handles first-embed, model bump, OCR arrival, and rename.
    private func process(_ candidates: [EmbeddingCandidate]) async throws -> EmbeddingBackfillOutcome {
        var embedded = 0, skipped = 0, failed = 0
        for candidate in candidates {
            do {
                let text = EmbeddingCorpus.text(candidate)
                // The candidate query excludes empty-corpus assets, but guard.
                guard !text.isEmpty else { skipped += 1; continue }
                let hash = EmbeddingCorpus.hash(text)

                // Unchanged AND already at this model version → touch, don't embed.
                // Touching bumps `embedded_at` so an OCR-re-run-with-same-text row
                // (analyzed_at > embedded_at) stops re-qualifying, and a re-verify
                // row rotates out of the oldest-first window.
                if candidate.existingContentHash == hash,
                   candidate.existingModelVersion == embedder.modelVersion {
                    try await services.markEmbeddingVerified(assetID: candidate.assetID)
                    skipped += 1
                    continue
                }

                guard let vector = embedder.embed(text) else { failed += 1; continue }
                try await services.upsertEmbedding(
                    assetID: candidate.assetID,
                    modelVersion: embedder.modelVersion,
                    contentHash: hash,
                    vector: vector)
                embedded += 1
            } catch {
                // A per-asset failure (deleted mid-run, persistence race) is counted
                // and skipped — never fatal.
                failed += 1
            }
        }
        return EmbeddingBackfillOutcome(embedded: embedded, skipped: skipped, failed: failed)
    }
}
