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
// OPT-IN, and this is the interesting part. Run it with:
//
//     ATELIER_VISION_CLASSIFY_TESTS=1 swift test --filter VisionImageClassifier
//
// **A synchronous `VNClassifyImageRequest.perform` DEADLOCKS this package's
// parallel test bundle.** Measured, not guessed:
//
//   • the bundle without this suite: 418 tests, 2.1 s, green
//   • the bundle with it: the whole PROCESS wedges after ~1.3 s — every suite
//     frozen mid-flight, CPU time flat, no progress, no timeout
//   • this suite alone: 2 tests, 0.15 s, green
//   • marking the suite `.serialized`: still wedges (so it is not these two
//     tests racing each other — it is this call against the rest of the run)
//
// `VisionTextRecognizer` performs synchronously in the same bundle and has never
// done this, so it is specific to the classification request, not to Vision or to
// the sync seam in general. The production path is unaffected and is what the
// seam was shaped for: `SuggestionBackfill` calls this from an app process, one
// asset at a time, on the coordinator's `.background` task — never from a bundle
// running forty suites concurrently on the cooperative pool. The app target's own
// test run is green.
//
// So the choice is between a green suite that cannot be run with its siblings and
// a bundle that hangs. Opt-in keeps the coverage runnable and honest about which
// it is; the fake-seam suites cover everything that is our logic rather than
// Apple's. If this is ever revisited, the thing to try is hosting the call off the
// cooperative pool entirely (a dedicated thread), not another `.serialized`.
// ─────────────────────────────────────────────────────────────────────────────

import CoreGraphics
import Foundation
import Testing
@testable import AtelierIngestion

/// Whether the live-Vision classification tests are enabled — see the file header.
private let liveVisionEnabled =
    ProcessInfo.processInfo.environment["ATELIER_VISION_CLASSIFY_TESTS"] == "1"

@Suite("VisionImageClassifier", .serialized, .enabled(if: liveVisionEnabled))
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
