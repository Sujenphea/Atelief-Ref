// AtelierIngestion — Vision classification adapter (feature 012, I3)
//
// The production ``ImageClassifying`` seam: Apple's `VNClassifyImageRequest` over
// a decoded `CGImage`. Deliberately thin, and shaped exactly like its sibling
// ``VisionTextRecognizer`` — a stateless struct that builds a request, performs it
// synchronously, and hands back plain values. All the testable policy lives in
// ``TagSuggestion`` behind the protocol, so this adapter needs only a smoke test.
//
// **Synchronous, and on the legacy `VN*` API on purpose.** Vision's newer Swift
// API is async, which would mean passing the non-`Sendable` `CGImage` across an
// `await` — the exact thing `VisionTextRecognizer`'s header explains it chose a
// sync signature to avoid. Two adapters over the same framework, decoding the same
// image in the same pipeline, should not disagree about their own concurrency
// shape; when OCR moves, this moves with it.

import CoreGraphics
import Foundation
import Vision

/// Classifies an image into labels — the injectable classification seam
/// (feature 012 · I3).
///
/// Refines `Sendable` so a value holding one stays `Sendable`. Synchronous for
/// the reason in the file header. Production uses ``VisionImageClassifier``;
/// tests use a fake.
public protocol ImageClassifying: Sendable {
    /// The labels the classifier is confident enough about to be worth showing,
    /// in no particular order (the policy sorts). Empty is an ordinary answer —
    /// plenty of design references are not a thing the taxonomy has a word for.
    ///
    /// Throws only on a classification-engine failure, never on "nothing matched".
    func classify(_ image: CGImage) throws -> [ClassificationLabel]
}

/// Classifies images via Apple's Vision framework — the production
/// ``ImageClassifying`` implementation. Stateless (hence `Sendable`); each call
/// builds and performs its own request.
public struct VisionImageClassifier: ImageClassifying {
    /// The precision the filter demands of a label before it survives.
    ///
    /// Vision returns its ENTIRE taxonomy on every image — over a thousand
    /// observations, most with a confidence near zero — so a filter is not
    /// optional, and a bare `confidence > x` cut is not meaningful: the
    /// confidence scales differ per label, which is why Vision ships each
    /// observation's own precision-recall curve and the query methods that read
    /// it. 0.9 is the high end of that curve, matching 012's "tune threshold
    /// high".
    private let minimumPrecision: Float

    /// The recall the label must still have AT that precision. Small by
    /// construction: this asks "is there any operating point where this label is
    /// 90% precise", and a label that only clears 90% precision at vanishing
    /// recall is one the model is genuinely sure about when it fires at all.
    private let minimumRecall: Float

    public init(minimumPrecision: Float = 0.9, minimumRecall: Float = 0.01) {
        self.minimumPrecision = minimumPrecision
        self.minimumRecall = minimumRecall
    }

    /// Classify `image`, returning only the labels that clear the precision gate.
    ///
    /// - Throws: whatever Vision's `perform` raises. A model that recognizes
    ///   nothing returns `[]`.
    public func classify(_ image: CGImage) throws -> [ClassificationLabel] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations
            .filter { $0.hasMinimumRecall(minimumRecall, forPrecision: minimumPrecision) }
            .map {
                ClassificationLabel(
                    identifier: $0.identifier, confidence: Double($0.confidence))
            }
    }
}
