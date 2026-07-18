// AtelierIngestion — asset analyzer tests (feature 012, I1)
//
// Composition + serialization, all with a FAKE recognizer (no Vision): the
// analyzer decodes once and runs hash + color + OCR, normalizes empty OCR to nil,
// propagates recognizer errors, and serializes to the `asset_analysis` forms
// (signed phash bit-cast, colors JSON). The pure algorithms are already covered
// by their own suites; here we assert the wiring.

import CoreGraphics
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("AssetAnalyzer")
struct AssetAnalyzerTests {
    /// A fake OCR seam returning a fixed string — the whole point of the protocol.
    private struct FakeRecognizer: TextRecognizing {
        let text: String?
        func recognizeText(in image: CGImage) throws -> String? { text }
    }

    private struct FailingRecognizer: TextRecognizing {
        struct Boom: Error {}
        func recognizeText(in image: CGImage) throws -> String? { throw Boom() }
    }

    private func analyzer(ocr: String?) -> AssetAnalyzer {
        AssetAnalyzer(textRecognizer: FakeRecognizer(text: ocr))
    }

    // MARK: - Composition

    @Test("analyze wires hash + colors + OCR from a solid image")
    func analyzeSolid() throws {
        let data = try FixtureImages.solidColorImage(width: 80, height: 80, red: 40, green: 120, blue: 200)
        let result = try analyzer(ocr: "poster text").analyze(imageData: data)

        #expect(result.phash == 0)                     // solid ⇒ flat ⇒ dHash 0
        #expect(result.colors.count == 1)              // one dominant color
        #expect(result.ocrText == "poster text")
    }

    @Test("empty or nil OCR normalizes to nil ocrText")
    func emptyOCRIsNil() throws {
        let data = try FixtureImages.solidColorImage(width: 40, height: 40, red: 10, green: 10, blue: 10)
        #expect(try analyzer(ocr: nil).analyze(imageData: data).ocrText == nil)
        #expect(try analyzer(ocr: "").analyze(imageData: data).ocrText == nil)
    }

    @Test("analyze(cgImage:) is the decode-once seam and produces the same wiring")
    func analyzeCGImageSeam() throws {
        let image = try FixtureImages.makeFilledCGImage(width: 50, height: 50) { context in
            context.setFillColor(red: 0.8, green: 0.2, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        let result = try analyzer(ocr: "x").analyze(cgImage: image)
        #expect(result.phash == 0)
        #expect(result.colors.count == 1)
        #expect(result.ocrText == "x")
    }

    @Test("a transparent image yields no colors → colorsJSON nil")
    func transparentNoColors() throws {
        let data = try FixtureImages.transparentImage(width: 40, height: 40)
        let result = try analyzer(ocr: nil).analyze(imageData: data)
        #expect(result.colors.isEmpty)
        #expect(result.colorsJSON == nil)
    }

    @Test("a recognizer error propagates out of analyze")
    func recognizerErrorPropagates() throws {
        let data = try FixtureImages.solidColorImage(width: 32, height: 32, red: 1, green: 2, blue: 3)
        let analyzer = AssetAnalyzer(textRecognizer: FailingRecognizer())
        #expect(throws: FailingRecognizer.Boom.self) {
            try analyzer.analyze(imageData: data)
        }
    }

    @Test("non-image bytes throw an ImageError before OCR runs")
    func nonImageThrows() {
        #expect {
            try analyzer(ocr: "unused").analyze(imageData: FixtureImages.nonImageBytes())
        } throws: { error in
            error is ImageError
        }
    }

    // MARK: - Serialization (the 2A boundary)

    @Test("signedPHash is a lossless UInt64↔Int64 bit-cast")
    func signedPHashBitcast() {
        // UInt64.max ↔ Int64(-1); a mid value ↔ its two's-complement image.
        let cases: [UInt64] = [0, 1, UInt64.max, 0x8000_0000_0000_0000, 0xDEAD_BEEF_CAFE_F00D]
        for value in cases {
            let result = AnalysisResult(phash: value, colors: [], ocrText: nil)
            #expect(UInt64(bitPattern: result.signedPHash) == value)
        }
        #expect(AnalysisResult(phash: UInt64.max, colors: [], ocrText: nil).signedPHash == -1)
    }

    @Test("colorsJSON is [{hex, coverage}] and round-trips back to the swatches")
    func colorsJSONRoundTrip() throws {
        let colors = [
            ColorSwatch(hex: "#0a141e", coverage: 0.6),
            ColorSwatch(hex: "#ffffff", coverage: 0.4),
        ]
        let result = AnalysisResult(phash: 0, colors: colors, ocrText: nil)
        let json = try #require(result.colorsJSON)
        #expect(json.contains("\"hex\""))
        #expect(json.contains("\"coverage\""))
        #expect(json.contains("#0a141e"))
        #expect(ColorSwatch.decodeList(fromJSON: json) == colors)
    }

    @Test("empty colors serialize to nil, not \"[]\"")
    func emptyColorsJSONNil() {
        #expect(AnalysisResult(phash: 0, colors: [], ocrText: nil).colorsJSON == nil)
    }

    @Test("the analyzer version is a stable constant")
    func analyzerVersion() {
        #expect(AssetAnalyzer.analyzerVersion == 1)
    }
}
