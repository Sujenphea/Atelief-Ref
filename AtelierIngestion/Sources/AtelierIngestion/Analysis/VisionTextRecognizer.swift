// AtelierIngestion — Vision OCR adapter (feature 012, I1)
//
// The production ``TextRecognizing`` seam: Apple's Vision `VNRecognizeTextRequest`
// over a decoded `CGImage`. Deliberately thin — a stateless struct that builds a
// request, performs it synchronously (Vision's own model), and joins the
// top-candidate strings. All the testable analysis logic lives in ``AssetAnalyzer``
// behind the protocol, so this adapter needs only a smoke test; everything else
// runs against a fake recognizer.
//
// This is the repo's first use of Vision. Vision is a system framework (like
// ImageIO / AVFoundation elsewhere in this package), imported directly with no SPM
// dependency.

import CoreGraphics
import Foundation
import Vision

/// Recognizes text in an image via Apple's Vision framework — the production
/// ``TextRecognizing`` implementation. Stateless (hence `Sendable`); each call
/// builds and performs its own request.
public struct VisionTextRecognizer: TextRecognizing {
    /// Recognition accuracy. `.accurate` favors correctness over latency — the
    /// right trade for an idle-priority background backfill (012), where quality
    /// of the search index matters more than per-item speed.
    private let recognitionLevel: VNRequestTextRecognitionLevel

    /// Whether Vision applies language correction to its candidates. On by default
    /// — design refs are natural-language-ish (type specimens, UI copy).
    private let usesLanguageCorrection: Bool

    public init(
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    /// Recognize text in `image`, returning the top candidate of each observation
    /// joined by newlines (reading order as Vision returns it), or `nil` when
    /// nothing legible was found.
    ///
    /// Throws only if Vision's `perform` itself fails; "no text in the image" is a
    /// `nil` return, not an error.
    public func recognizeText(in image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
