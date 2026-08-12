// AtelierIngestion — analysis backfill orchestration (feature 012, I1)
//
// Walks the assets that still need analysis and runs the ``AssetAnalyzer`` over
// each, persisting the result through `AppServices.upsertAnalysis`. This is the
// seam that joins the three layers: the resumable query
// (`assetsNeedingAnalysis`, AtelierCore), the blob bytes (``MediaStore``), and the
// analyzer (this package).
//
// Resumability is free: "still needs analysis" is a query, not a ledger, so a
// killed backfill resumes simply by asking for the next batch again — every
// successfully-analyzed asset drops out of the candidate set, and a version bump
// puts stale rows back in. One bad asset never aborts a batch (the 004
// batch-outcome discipline): its failure is counted and the run moves on.
//
// This type deliberately does NOT own scheduling. QoS / idle-priority /
// pause-on-user-activity is the app's concern (012: "genuinely idle-priority …
// never compete with ingest or the canvas"); here we expose a batch primitive and
// a drain-to-completion convenience the scheduler drives.

import AtelierCore
import Foundation

/// The tally of one backfill run — honest partial-outcome reporting (N analyzed /
/// N failed), never a silent count.
public struct AnalysisBackfillOutcome: Sendable, Equatable {
    /// Assets analyzed and persisted this run.
    public let analyzed: Int
    /// Assets that errored (missing/unreadable blob, decode failure, recognizer
    /// error) and were skipped — the batch continued past them.
    public let failed: Int

    public init(analyzed: Int, failed: Int) {
        self.analyzed = analyzed
        self.failed = failed
    }

    /// Total assets attempted this run.
    public var attempted: Int { analyzed + failed }

    func adding(_ other: AnalysisBackfillOutcome) -> AnalysisBackfillOutcome {
        AnalysisBackfillOutcome(analyzed: analyzed + other.analyzed, failed: failed + other.failed)
    }
}

/// Runs the on-device analysis backfill over a library (feature 012 · I1). A
/// `Sendable` value type composing the three collaborators.
public struct AnalysisBackfill: Sendable {
    private let services: AppServices
    private let store: MediaStore
    private let analyzer: AssetAnalyzer

    public init(services: AppServices, store: MediaStore, analyzer: AssetAnalyzer) {
        self.services = services
        self.store = store
        self.analyzer = analyzer
    }

    /// Analyze up to `limit` assets that currently need analysis, at the
    /// analyzer's version. Returns the run's outcome. Idempotent + resumable:
    /// analyzed assets drop out of the next batch, so re-running continues the
    /// backfill. A per-asset failure is counted and skipped, never fatal.
    @discardableResult
    public func analyzeNextBatch(limit: Int) async throws -> AnalysisBackfillOutcome {
        let ids = try await services.assetsNeedingAnalysis(
            analyzerVersion: AssetAnalyzer.analyzerVersion, limit: limit)

        var analyzed = 0
        var failed = 0
        for id in ids {
            do {
                try await analyze(assetID: id)
                analyzed += 1
            } catch {
                // One bad asset (deleted mid-run, unreadable blob, decode failure)
                // never aborts the batch — count it and move on.
                failed += 1
            }
        }
        return AnalysisBackfillOutcome(analyzed: analyzed, failed: failed)
    }

    /// Drain the whole backlog in `batchSize` chunks until no progress can be
    /// made, returning the cumulative outcome. Intended for a one-shot / test
    /// drain; a real scheduler prefers ``analyzeNextBatch(limit:)`` on an idle
    /// cadence.
    ///
    /// Terminates when a batch attempts nothing (backlog empty) OR analyzes
    /// nothing (only persistently-failing items remain — they stay pending, so
    /// looping would spin). Persistently-failing assets are retried across runs by
    /// design; the no-progress guard bounds the waste to one batch.
    @discardableResult
    public func analyzeAll(batchSize: Int = 20) async throws -> AnalysisBackfillOutcome {
        var total = AnalysisBackfillOutcome(analyzed: 0, failed: 0)
        while true {
            let outcome = try await analyzeNextBatch(limit: batchSize)
            total = total.adding(outcome)
            if outcome.attempted == 0 || outcome.analyzed == 0 { break }
        }
        return total
    }

    /// Analyze one asset: load its blob, run the analyzer, persist the serialized
    /// result. Throws on any step (caught + counted by the batch loop).
    private func analyze(assetID: UUID) async throws {
        let asset = try await services.getAsset(id: assetID).asset
        let data = try AnalysisSource.imageData(for: asset, in: store)
        let result = try analyzer.analyze(imageData: data)

        try await services.upsertAnalysis(
            assetID: assetID,
            ocrText: result.ocrText,
            colors: result.colorsJSON,
            phash: result.signedPHash,
            analyzerVersion: AssetAnalyzer.analyzerVersion)
    }
}

