// AtelierIngestion — Vision classification adapter smoke tests (feature 012, I3)
//
// A thin adapter over Vision needs only a smoke test (the policy is covered by
// TagSuggestionTests behind the fake seam). What is asserted here is the ADAPTER's
// own contract — it performs, it does not throw on a trivial image, and the
// precision gate is doing something — never which labels the model returns.
// Vision's taxonomy is Apple's and changes with the OS; pinning a label would be
// a test that fails on an OS update for no defect.
//
// ─────────────────────────────────────────────────────────────────────────────
// This suite used to be OPT-IN behind `ATELIER_VISION_CLASSIFY_TESTS=1`, because a
// synchronous `VNClassifyImageRequest.perform` appeared to DEADLOCK the parallel
// bundle: with the suite in, the whole process wedged after ~1.3 s; without it,
// 418 tests in 2.1 s; the suite alone, green; `.serialized`, still wedged.
//
// That diagnosis was right about the symptom and wrong about the culprit. The
// bundle was already one blocked thread away from a COOPERATIVE-POOL deadlock:
// `FixtureVideos.solidVideo` blocked a pool thread per call (`DispatchSemaphore`
// + `Thread.sleep`) and nine call sites raced for eight threads. This suite's
// `perform` blocks a pool thread too, so adding it tipped an already-marginal
// bundle over — which is exactly why `.serialized` did not help: the contention
// was never between these two tests.
//
// The gate came off once the fixture stopped blocking (see changelog 391). With
// that fixed, the bundle runs this suite in parallel with everything else:
// 427 tests, 45 suites, green — verified three consecutive runs. The suite stays
// `.serialized` since these two calls have no reason to overlap each other, but
// nothing about it is opt-in any more, so CI runs it like everything else.
//
// The lasting lesson is the general one: this seam performs SYNCHRONOUSLY, so it
// costs a cooperative thread for the duration. That is fine in production —
// `SuggestionBackfill` calls it one asset at a time on the coordinator's
// `.background` task — and it is fine here, but a future caller that fans this
// out across a task group would be re-arming the same trap.
// ─────────────────────────────────────────────────────────────────────────────

import CoreGraphics
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("VisionImageClassifier", .serialized)
struct VisionImageClassifierTests {

    private func flatImage(gray: Double = 0.5) throws -> CGImage {
        try FixtureImages.makeFilledCGImage(width: 200, height: 200) { context in
            context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
    }

    @Test("classifying a flat image performs without throwing")
    func classifiesWithoutThrowing() throws {
        let labels = try VisionImageClassifier().classify(try flatImage())
        // A featureless gray square legitimately matches nothing at high
        // precision, so the count is not asserted — only that the call completed
        // and every label it did return is well-formed.
        for label in labels {
            #expect(!label.identifier.isEmpty)
            #expect(label.confidence >= 0 && label.confidence <= 1)
        }
    }

    /// The gate is the whole reason this adapter exists: Vision hands back its
    /// entire taxonomy on every image, most of it near zero confidence, so an
    /// unfiltered adapter would propose noise. Demanding an impossible precision
    /// must therefore return strictly fewer labels than demanding none.
    @Test("the precision gate is load-bearing, not decorative")
    func precisionGateFilters() throws {
        let image = try flatImage(gray: 0.35)
        let ungated = try VisionImageClassifier(minimumPrecision: 0, minimumRecall: 0)
            .classify(image)
        let gated = try VisionImageClassifier(minimumPrecision: 1, minimumRecall: 1)
            .classify(image)

        // Guard rather than assert on the ungated count: an environment without a
        // usable classification model returns nothing, and that is a skip, not a
        // failure (mirroring VisionTextRecognizerTests).
        guard !ungated.isEmpty else { return }
        #expect(gated.count < ungated.count)
    }
}
