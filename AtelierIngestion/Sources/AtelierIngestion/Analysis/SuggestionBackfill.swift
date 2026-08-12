// AtelierIngestion — suggested-tag backfill orchestration (feature 012, I3)
//
// Walks the assets no suggester has looked at yet, classifies each, and records
// the surviving labels as `.agent` tags through `AppServices.recordSuggestions`.
// The same three-collaborator seam as ``AnalysisBackfill`` — a resumable query
// (AtelierCore), the blob bytes (``MediaStore``), and a model (this package) —
// and the same discipline: one bad asset is counted and skipped, never fatal.
//
// **Why this is its own pass and not another line in ``AssetAnalyzer``.** Folding
// classification into the analyzer would share its single decode, which is the
// obvious efficiency and the wrong trade. `analyzer_version` gates OCR, colors
// and the perceptual hash TOGETHER, so a change to the tag model — a new Vision
// generation, a different cap, a re-tuned threshold — would re-OCR every image in
// the library to deliver it. Those two things change on completely different
// schedules. The cost of separating them is one extra decode per asset, paid once
// per suggester version on an idle queue; the cost of joining them is a full
// re-analysis every time the tag policy moves.
//
// Ordering matters, and the coordinator owns it: this runs AFTER
// ``AnalysisBackfill``, because `assetsNeedingSuggestions` only returns assets
// that already have an analysis row to mark.

import AtelierCore
import Foundation

/// The tally of one suggestion run — honest partial-outcome reporting, matching
/// ``AnalysisBackfillOutcome``.
public struct SuggestionBackfillOutcome: Sendable, Equatable {
    /// Assets classified and marked this run — including those that produced no
    /// suggestion at all, which is a completed asset, not a failure.
    public let suggested: Int
    /// Assets that errored (missing/unreadable blob, decode failure, classifier
    /// error) and were skipped.
    public let failed: Int
    /// How many `.agent` tags were actually written across the run. Reported
    /// separately from `suggested` because the two answer different questions:
    /// how much work was done, and how much of it had anything to say.
    public let tagsWritten: Int

    public init(suggested: Int, failed: Int, tagsWritten: Int) {
        self.suggested = suggested
        self.failed = failed
        self.tagsWritten = tagsWritten
    }

    /// Total assets attempted this run.
    public var attempted: Int { suggested + failed }

    func adding(_ other: SuggestionBackfillOutcome) -> SuggestionBackfillOutcome {
        SuggestionBackfillOutcome(
            suggested: suggested + other.suggested,
            failed: failed + other.failed,
            tagsWritten: tagsWritten + other.tagsWritten)
    }
}

/// Runs the suggested-tag backfill over a library (feature 012 · I3). A
/// `Sendable` value type composing its three collaborators.
public struct SuggestionBackfill: Sendable {
    /// Longest-edge size of this pass's decode. Smaller than
    /// ``AssetAnalyzer/decodeSize`` because the consumers are different: OCR needs
    /// legible glyphs, classification needs a scene. Vision rescales to its own
    /// model input anyway, so decoding larger would cost memory and time to throw
    /// the pixels away.
    public static let decodeSize = 512

    private let services: AppServices
    private let store: MediaStore
    private let classifier: any ImageClassifying

    public init(services: AppServices, store: MediaStore, classifier: any ImageClassifying) {
        self.services = services
        self.store = store
        self.classifier = classifier
    }

    /// Classify up to `limit` assets that no suggester has reached at
    /// ``TagSuggestion/version``. Idempotent + resumable: a marked asset drops out
    /// of the next batch, so re-running continues rather than repeats.
    @discardableResult
    public func suggestNextBatch(limit: Int) async throws -> SuggestionBackfillOutcome {
        let ids = try await services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: limit)

        var suggested = 0
        var failed = 0
        var tagsWritten = 0
        for id in ids {
            do {
                tagsWritten += try await suggest(assetID: id)
                suggested += 1
            } catch {
                // One bad asset (deleted mid-run, unreadable blob, decode failure)
                // never aborts the batch — count it and move on. It stays unmarked
                // and will be retried on a later pass, which is correct: the
                // failure is usually about the bytes, not about the asset.
                failed += 1
            }
        }
        return SuggestionBackfillOutcome(
            suggested: suggested, failed: failed, tagsWritten: tagsWritten)
    }

    /// Drain the backlog in `batchSize` chunks until no progress can be made,
    /// returning the cumulative outcome. Terminates on an empty batch OR on a
    /// batch that suggested nothing (only persistently-failing items remain), the
    /// same no-progress guard ``AnalysisBackfill/analyzeAll(batchSize:)`` uses.
    @discardableResult
    public func suggestAll(batchSize: Int = 20) async throws -> SuggestionBackfillOutcome {
        var total = SuggestionBackfillOutcome(suggested: 0, failed: 0, tagsWritten: 0)
        while true {
            let outcome = try await suggestNextBatch(limit: batchSize)
            total = total.adding(outcome)
            if outcome.attempted == 0 || outcome.suggested == 0 { break }
        }
        return total
    }

    /// Classify one asset and record the result. Returns how many `.agent` tags
    /// were written (0 is a normal outcome). Throws on any step; the batch loop
    /// catches and counts.
    private func suggest(assetID: UUID) async throws -> Int {
        let asset = try await services.getAsset(id: assetID).asset
        // A video is classified from its POSTER, not its movie — see
        // ``AnalysisSource``, which both passes share so they can never disagree
        // about what a video looks like.
        let data = try AnalysisSource.imageData(for: asset, in: store)
        let image = try ImageDecoding.thumbnailCGImage(from: data, maxPixelSize: Self.decodeSize)
        let names = TagSuggestion.select(from: try classifier.classify(image))

        let written = try await services.recordSuggestions(
            names, for: assetID, suggestVersion: TagSuggestion.version)
        return written.count
    }
}

