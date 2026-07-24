// AtelierIngestion — embedding corpus + content-hash unit tests (047 · 3a · 2A/4A)

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("EmbeddingCorpus")
struct EmbeddingCorpusTests {

    @Test("fields concatenate in the fixed order title → name → note → OCR")
    func fixedOrder() {
        let text = EmbeddingCorpus.text(title: "T", name: "N", note: "O", ocr: "R")
        #expect(text == "T\nN\nO\nR")
    }

    @Test("blank / nil fields are dropped, order preserved")
    func dropsBlanks() {
        #expect(EmbeddingCorpus.text(title: "T", name: nil, note: "  ", ocr: "R") == "T\nR")
        #expect(EmbeddingCorpus.text(title: nil, name: nil, note: nil, ocr: nil).isEmpty)
    }

    @Test("trims each field")
    func trims() {
        #expect(EmbeddingCorpus.text(title: "  T ", name: "\nN\n", note: nil, ocr: nil) == "T\nN")
    }

    @Test("truncates to maxLength (OCR tail trimmed, salient fields kept)")
    func truncates() {
        let longOCR = String(repeating: "x", count: EmbeddingCorpus.maxLength + 500)
        let text = EmbeddingCorpus.text(title: "keep", name: nil, note: nil, ocr: longOCR)
        #expect(text.count == EmbeddingCorpus.maxLength)
        #expect(text.hasPrefix("keep\n"))   // leading salient field survives
    }

    @Test("hash is stable and changes iff the text changes")
    func hashStability() {
        let a = EmbeddingCorpus.hash("brutalist tower")
        #expect(a == EmbeddingCorpus.hash("brutalist tower"))   // deterministic
        #expect(a != EmbeddingCorpus.hash("brutalist towers"))  // sensitive
        #expect(EmbeddingCorpus.hash("").count == 64)           // SHA-256 hex
    }
}
