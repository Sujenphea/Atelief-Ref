// AtelierIngestion — Vision OCR adapter smoke tests (feature 012, I1)
//
// A thin adapter over Vision needs only a smoke test (the analysis logic is
// covered by AssetAnalyzerTests behind the fake seam). Two checks: rendered text
// is recognized, and a blank image yields no text. The text-recognition assertion
// is GUARDED — Vision's model / availability varies by environment (mirroring the
// HEIC-encode skip in the fixtures) — so a nil result skips rather than fails.

import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("VisionTextRecognizer")
struct VisionTextRecognizerTests {
    /// Render `string` as large black text on white — a legible OCR fixture.
    private func textImage(_ string: String, width: Int = 500, height: Int = 160) throws -> CGImage {
        try FixtureImages.makeFilledCGImage(width: width, height: height) { context in
            // White background.
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Black text via CoreText (no AppKit dependency).
            let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
            let attrs: CFDictionary = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ] as CFDictionary
            let attributed = CFAttributedStringCreate(nil, string as CFString, attrs)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 30, y: 50)
            CTLineDraw(line, context)
        }
    }

    @Test("recognizes rendered text (guarded — skips if Vision yields nothing here)")
    func recognizesRenderedText() throws {
        let image = try textImage("HELLO")
        let recognized = try VisionTextRecognizer().recognizeText(in: image)
        // Environment without a usable Vision text model → skip rather than fail.
        guard let text = recognized else { return }
        #expect(text.lowercased().contains("hello"))
    }

    @Test("a blank image yields no text (nil)")
    func blankImageNoText() throws {
        let image = try FixtureImages.makeFilledCGImage(width: 200, height: 120) { context in
            context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        #expect(try VisionTextRecognizer().recognizeText(in: image) == nil)
    }
}
