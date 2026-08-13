// AtelierIngestion — suggested-tag backfill tests (feature 012, I3)
//
// End-to-end over a real temp library with real blobs on disk, mirroring
// `AnalysisBackfillTests`: the chips land, the pass is resumable and idempotent,
// a per-item failure is counted rather than fatal, and — the property the whole
// feature rests on — a dismissed suggestion is not re-applied by a later run.

import CoreGraphics
import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("SuggestionBackfill")
struct SuggestionBackfillTests {
    /// Returns fixed labels for any image. Confidence order is the ranking the
    /// policy applies; the adapter's precision gate is not this suite's subject.
    private struct FakeClassifier: ImageClassifying {
        let labels: [ClassificationLabel]
        func classify(_ image: CGImage) throws -> [ClassificationLabel] { labels }
    }

    private struct ExplodingClassifier: ImageClassifying {
        struct Boom: Error {}
        func classify(_ image: CGImage) throws -> [ClassificationLabel] { throw Boom() }
    }

    private func backfill(
        _ env: TempPipeline, labels: [(String, Double)]
    ) -> SuggestionBackfill {
        SuggestionBackfill(
            services: env.services, store: env.store,
            classifier: FakeClassifier(labels: labels.map {
                ClassificationLabel(identifier: $0.0, confidence: $0.1)
            }))
    }

    /// Ingest `count` distinct solid-color images and ANALYZE them — the
    /// suggestion queue only returns assets that already have an analysis row.
    @discardableResult
    private func ingestAnalyzedImages(_ env: TempPipeline, count: Int) async throws -> [UUID] {
        var inputs: [IngestInput] = []
        for i in 0 ..< count {
            let bytes = try FixtureImages.solidColorImage(
                width: 64, height: 64,
                red: UInt8(20 + i * 30), green: UInt8(60 + i * 10), blue: UInt8(200 - i * 20))
            inputs.append(IngestInput(
                source: .data(bytes),
                provenance: SourceDraft(
                    platform: .localPaste,
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))),
                collectionID: env.collectionID))
        }
        _ = await env.coordinator.ingest(inputs)
        let ids = try await env.services.searchAssets(text: nil).map(\.asset.id)
        for id in ids {
            _ = try await env.services.upsertAnalysis(
                assetID: id, analyzerVersion: AssetAnalyzer.analyzerVersion)
        }
        return ids
    }

    private func agentNames(_ env: TempPipeline, on asset: UUID) async throws -> [String] {
        try await env.services.tags(for: asset).filter { $0.source == .agent }.map(\.name)
    }

    // MARK: - The happy path

    @Test("a batch classifies every pending asset and writes its chips")
    func batchSuggestsAll() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestAnalyzedImages(env, count: 3)
        #expect(ids.count == 3)

        let outcome = try await backfill(env, labels: [("poster", 0.9), ("type", 0.8)])
            .suggestNextBatch(limit: 50)
        #expect(outcome.suggested == 3)
        #expect(outcome.failed == 0)
        #expect(outcome.tagsWritten == 6)

        for id in ids {
            #expect(try await agentNames(env, on: id).sorted() == ["poster", "type"])
            #expect(try await env.services.analysis(for: id)?.suggestVersion == TagSuggestion.version)
        }
        #expect(try await env.services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: 50).isEmpty)
    }

    @Test("the policy's cap is applied by the pass, not just in isolation")
    func capsAtThree() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestAnalyzedImages(env, count: 1)
        _ = try await backfill(env, labels: [
            ("a", 0.9), ("b", 0.8), ("c", 0.7), ("d", 0.6),
        ]).suggestNextBatch(limit: 10)

        #expect(try await agentNames(env, on: ids[0]) == ["a", "b", "c"])
    }

    /// The other half of the video fix: a video reaches the ✦ chips too, classified
    /// from the same poster the analysis pass reads. It was excluded when I3
    /// shipped because its candidate query was written by mirroring the analysis
    /// one, inheriting a deferral the poster tier had already made unnecessary.
    @Test("a video is classified from its poster frame")
    func suggestsForVideo() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let mp4 = try await FixtureVideos.solidVideo(width: 320, height: 240)
        let outcome = await env.pipeline.ingest(IngestInput(
            source: .data(mp4),
            provenance: SourceDraft(platform: .localPaste, capturedAt: Date()),
            collectionID: env.collectionID))
        guard case .ingested(let video, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        // The suggestion queue needs the analysis row the earlier pass writes.
        _ = try await env.services.upsertAnalysis(
            assetID: video.id, analyzerVersion: AssetAnalyzer.analyzerVersion)

        let pending = try await env.services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: 50)
        #expect(pending.contains(video.id))

        let run = try await backfill(env, labels: [("title sequence", 0.9)])
            .suggestNextBatch(limit: 50)
        #expect(run.suggested == 1)
        #expect(run.failed == 0)
        #expect(try await agentNames(env, on: video.id) == ["title sequence"])
    }

    // MARK: - Resumable + idempotent

    @Test("the pass is resumable batch-by-batch")
    func resumableInBatches() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        try await ingestAnalyzedImages(env, count: 3)
        let runner = backfill(env, labels: [("poster", 0.9)])

        let first = try await runner.suggestNextBatch(limit: 2)
        #expect(first.suggested == 2)
        #expect(try await env.services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: 50).count == 1)

        let second = try await runner.suggestNextBatch(limit: 2)
        #expect(second.suggested == 1)
    }

    @Test("a second drain does no work")
    func idempotentDrain() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        try await ingestAnalyzedImages(env, count: 2)
        let runner = backfill(env, labels: [("poster", 0.9)])

        #expect(try await runner.suggestAll().suggested == 2)
        let again = try await runner.suggestAll()
        #expect(again.attempted == 0)
        #expect(again.tagsWritten == 0)
    }

    /// An asset that produced nothing is still DONE. If the marker were only
    /// written when a tag survived, every unclassifiable image in the library
    /// would be re-decoded on every idle pass, forever.
    @Test("an asset the classifier says nothing about is still marked done")
    func emptyResultStillMarks() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestAnalyzedImages(env, count: 1)

        let outcome = try await backfill(env, labels: []).suggestNextBatch(limit: 10)
        #expect(outcome.suggested == 1)
        #expect(outcome.tagsWritten == 0)
        #expect(try await agentNames(env, on: ids[0]).isEmpty)
        #expect(try await env.services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: 10).isEmpty)
    }

    // MARK: - Failure is counted, not fatal

    @Test("a classifier failure is counted and leaves the asset pending")
    func classifierFailureIsCounted() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestAnalyzedImages(env, count: 2)

        let runner = SuggestionBackfill(
            services: env.services, store: env.store, classifier: ExplodingClassifier())
        let outcome = try await runner.suggestNextBatch(limit: 10)
        #expect(outcome.suggested == 0)
        #expect(outcome.failed == 2)

        // Unmarked, so a later pass retries them — the failure was about the run,
        // not about the asset.
        #expect(Set(try await env.services.assetsNeedingSuggestions(
            suggestVersion: TagSuggestion.version, limit: 10)) == Set(ids))
    }

    @Test("suggestAll stops rather than spinning on persistently-failing assets")
    func drainDoesNotSpin() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        try await ingestAnalyzedImages(env, count: 2)

        let runner = SuggestionBackfill(
            services: env.services, store: env.store, classifier: ExplodingClassifier())
        let outcome = try await runner.suggestAll(batchSize: 1)
        // One batch attempted, no progress, stop — not an infinite loop.
        #expect(outcome.suggested == 0)
        #expect(outcome.failed == 1)
    }

    // MARK: - The memory

    /// The end-to-end version of the property `ServicesSuggestionsTests` pins at
    /// the funnel: a refusal outlives the pass that produced the suggestion.
    @Test("a dismissed suggestion is not re-applied by a later run")
    func dismissalSurvivesTheNextRun() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestAnalyzedImages(env, count: 1)
        let asset = ids[0]

        _ = try await backfill(env, labels: [("poster", 0.9), ("type", 0.8)])
            .suggestNextBatch(limit: 10)
        try await env.services.dismissSuggestion("poster", on: asset)
        #expect(try await agentNames(env, on: asset) == ["type"])

        // Re-open the queue the way a new suggester version would, and re-run the
        // identical classifier over the identical bytes.
        _ = try await env.services.upsertAnalysis(
            assetID: asset, analyzerVersion: AssetAnalyzer.analyzerVersion)
        try await env.services.recordSuggestions(
            TagSuggestion.select(from: [
                ClassificationLabel(identifier: "poster", confidence: 0.9),
                ClassificationLabel(identifier: "type", confidence: 0.8),
            ]),
            for: asset, suggestVersion: TagSuggestion.version + 1)

        #expect(try await agentNames(env, on: asset) == ["type"])
        #expect(try await env.services.suppressedTagNames(for: asset) == ["poster"])
    }
}
