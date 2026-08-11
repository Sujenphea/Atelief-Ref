//
//  AnalysisCoordinator.swift
//  AtelierRefs
//
//  047 · 3a · 6A — the app-scoped background coordinator that finally WIRES the
//  on-device analysis pipeline (previously built but dormant). It drains the two
//  resumable backfills on a low-priority idle loop, ordered so the semantic corpus
//  sees fresh OCR:
//
//    1. AnalysisBackfill  — OCR / colors / perceptual hash (needs the blob bytes).
//    2. ColorBucketBackfill — files those colors into searchable buckets (085 · C1).
//       Runs SECOND because it reads what step 1 just wrote; it decodes nothing,
//       so an asset analyzed this pass is filterable by color in the same pass.
//    3. EmbeddingBackfill — the semantic text vector (OCR is now part of its
//       corpus, so embedding an asset AFTER its analysis captures the OCR text).
//    4. a bounded embedding RE-VERIFY pass — catches name/note edits the
//       timestamp-less `asset` can't signal (4A), oldest-embedded first.
//
//  Scheduling is deliberately the app's concern (the backfills own no cadence).
//  This runs at `.background` priority so it never competes with ingest or the
//  canvas, and sleeps between passes rather than busy-waiting. Both backfills are
//  resumable (staleness is a query, not a ledger), so an interrupted or relaunched
//  run simply continues. Embedding is skipped when the NL model isn't installed.
//
//  NOTE: a true pause-on-user-activity gate is a later refinement; `.background`
//  priority + the idle interval is the current approximation.
//

import AtelierCore
import AtelierIngestion
import Foundation
import OSLog

/// Drains the analysis + embedding backfills on an idle background loop (047 · 3a).
/// A value type composing the collaborators; the owning model holds its `Task` and
/// cancels it on teardown.
struct AnalysisCoordinator: Sendable {
    private let analysis: AnalysisBackfill
    private let colors: ColorBucketBackfill
    private let embedding: EmbeddingBackfill
    /// Whether the on-device sentence-embedding model is installed. When false, the
    /// embedding + re-verify passes are skipped (analysis still runs).
    private let embeddingAvailable: Bool


    /// How many already-embedded assets to re-hash for text drift per pass — bounded
    /// so a pass stays cheap; the sweep covers the library over successive passes.
    private static let reverifyBatch = 50

    /// The color pass's per-pass ceiling: 25 batches of 200 = up to 5,000 assets.
    ///
    /// Bounded rather than a plain `drain()`, even though the work itself is cheap
    /// (no decode — it re-reads hexes already on disk). The cost that scales is the
    /// WRITE: `replaceColors` is one transaction per asset, so a first launch over a
    /// large library would be tens of thousands of commits competing with ingest.
    /// A library past the ceiling catches up over successive idle passes, which
    /// nobody sees — nothing shows a color until it is derived.
    private static let colorBatch = 200
    private static let colorBatchesPerPass = 25

    init(services: AppServices, store: MediaStore) {
        self.analysis = AnalysisBackfill(
            services: services, store: store,
            analyzer: AssetAnalyzer(textRecognizer: VisionTextRecognizer()))
        self.colors = ColorBucketBackfill(services: services)
        let embedder = NLSentenceEmbedder()
        self.embeddingAvailable = embedder.isAvailable
        self.embedding = EmbeddingBackfill(services: services, embedder: embedder)
    }

    /// One ordered drain pass. Returns whether it did any new work (so the loop can
    /// back off when the library is fully indexed). Never throws — a backfill error
    /// is logged and the pass ends; the next pass retries.
    @discardableResult
    func runPass() async -> Bool {
        var didWork = false
        do {
            let analyzed = try await analysis.analyzeAll()
            didWork = didWork || analyzed.analyzed > 0

            let filed = try await colors.drain(
                batchSize: Self.colorBatch, maxBatches: Self.colorBatchesPerPass)
            didWork = didWork || filed.filed > 0

            guard embeddingAvailable else { return didWork }
            let embedded = try await embedding.embedAll()
            didWork = didWork || embedded.embedded > 0

            let reverified = try await embedding.reverifyNextBatch(limit: Self.reverifyBatch)
            didWork = didWork || reverified.embedded > 0
        } catch is CancellationError {
            // Coordinator torn down mid-pass — silent.
        } catch {
            AppLog.analysis.error("backfill pass failed: \(String(describing: error))")
        }
        return didWork
    }

    /// The idle loop: drain, then sleep `idleInterval` before the next pass so new
    /// assets / renames are picked up without busy-waiting. Cancellation-aware — the
    /// owning model cancels the driving `Task` on teardown.
    func run(idleInterval: Duration = .seconds(90)) async {
        while !Task.isCancelled {
            _ = await runPass()
            do {
                try await Task.sleep(for: idleInterval)
            } catch {
                return  // cancelled during the idle wait
            }
        }
    }
}
