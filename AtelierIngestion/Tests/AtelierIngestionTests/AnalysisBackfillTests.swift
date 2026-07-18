// AtelierIngestion — analysis backfill tests (feature 012, I1)
//
// End-to-end over a real temp library: ingest images (real blobs on disk), then
// run the backfill and assert the analysis rows land, that it's resumable
// (batch-by-batch) and idempotent (a second pass does no work), and that OCR /
// colors / phash flow through to the store. A per-item failure is counted, not
// fatal.

import CoreGraphics
import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("AnalysisBackfill")
struct AnalysisBackfillTests {
    private struct FakeRecognizer: TextRecognizing {
        let text: String?
        func recognizeText(in image: CGImage) throws -> String? { text }
    }

    private func backfill(_ env: TempPipeline, ocr: String? = nil) -> AnalysisBackfill {
        AnalysisBackfill(
            services: env.services, store: env.store,
            analyzer: AssetAnalyzer(textRecognizer: FakeRecognizer(text: ocr)))
    }

    /// Ingest `count` distinct solid-color images; return their asset ids.
    @discardableResult
    private func ingestImages(_ env: TempPipeline, count: Int) async throws -> [UUID] {
        var inputs: [IngestInput] = []
        for i in 0 ..< count {
            let bytes = try FixtureImages.solidColorImage(
                width: 64, height: 64,
                red: UInt8(20 + i * 30), green: UInt8(60 + i * 10), blue: UInt8(200 - i * 20))
            inputs.append(IngestInput(
                source: .data(bytes),
                provenance: SourceDraft(platform: .localPaste, capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))),
                collectionID: env.collectionID))
        }
        _ = await env.coordinator.ingest(inputs)
        return try await env.services.searchAssets(text: nil).map(\.asset.id)
    }

    // MARK: - Batch analyzes pending assets

    @Test("a batch analyzes all pending images and persists their analysis")
    func batchAnalyzesAll() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestImages(env, count: 3)
        #expect(ids.count == 3)

        // All three are pending before the run.
        let pendingBefore = try await env.services.assetsNeedingAnalysis(
            analyzerVersion: AssetAnalyzer.analyzerVersion, limit: 50)
        #expect(Set(pendingBefore) == Set(ids))

        let outcome = try await backfill(env, ocr: "specimen").analyzeNextBatch(limit: 50)
        #expect(outcome.analyzed == 3)
        #expect(outcome.failed == 0)

        // Every asset now has an analysis row with the expected fields.
        for id in ids {
            let analysis = try #require(try await env.services.analysis(for: id))
            #expect(analysis.analyzerVersion == AssetAnalyzer.analyzerVersion)
            #expect(analysis.phash == 0)                 // solid ⇒ dHash 0
            #expect(analysis.ocrText == "specimen")      // OCR flowed through
            let colors = try #require(analysis.colors.flatMap(ColorSwatch.decodeList(fromJSON:)))
            #expect(colors.count == 1)                   // one dominant color
        }

        // Nothing left pending.
        let pendingAfter = try await env.services.assetsNeedingAnalysis(
            analyzerVersion: AssetAnalyzer.analyzerVersion, limit: 50)
        #expect(pendingAfter.isEmpty)
    }

    // MARK: - Resumable + idempotent

    @Test("the backfill is resumable batch-by-batch")
    func resumableInBatches() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestImages(env, count: 3)
        let runner = backfill(env)

        let first = try await runner.analyzeNextBatch(limit: 2)
        #expect(first.analyzed == 2)
        // One still pending after the first partial batch.
        #expect(try await env.services.assetsNeedingAnalysis(
            analyzerVersion: AssetAnalyzer.analyzerVersion, limit: 50).count == 1)

        let second = try await runner.analyzeNextBatch(limit: 2)
        #expect(second.analyzed == 1)
        // All accounted for.
        for id in ids { #expect(try await env.services.analysis(for: id) != nil) }
    }

    @Test("a second pass after completion does no work (idempotent)")
    func idempotentSecondPass() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        _ = try await ingestImages(env, count: 2)
        let runner = backfill(env)

        #expect(try await runner.analyzeNextBatch(limit: 50).analyzed == 2)
        let again = try await runner.analyzeNextBatch(limit: 50)
        #expect(again.analyzed == 0)
        #expect(again.attempted == 0)
    }

    @Test("analyzeAll drains the whole backlog in chunks")
    func analyzeAllDrains() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let ids = try await ingestImages(env, count: 5)

        let total = try await backfill(env).analyzeAll(batchSize: 2)
        #expect(total.analyzed == 5)
        #expect(total.failed == 0)
        for id in ids { #expect(try await env.services.analysis(for: id) != nil) }
        #expect(try await env.services.assetsNeedingAnalysis(
            analyzerVersion: AssetAnalyzer.analyzerVersion, limit: 50).isEmpty)
    }

    // MARK: - No candidates

    @Test("an empty backlog analyzes nothing")
    func emptyBacklog() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let outcome = try await backfill(env).analyzeNextBatch(limit: 50)
        #expect(outcome.attempted == 0)
    }
}
