//
//  TextMetricsTests.swift
//  CanvasRendererTests
//
//  054 §4.1 (2C · R10) — the pure, mode-agnostic text measurement helper. It
//  measures with the SAME font as drawing (`CanvasFont.resolve`) at the world
//  `fontSize`, so a measured size can't drift from the drawn one. Assertions are
//  BOUNDED + MONOTONIC (longer → wider, larger size → taller, more lines →
//  taller, empty ≈ one line), never brittle exact-pixel pins. Padding is a
//  separate constant the CALLER adds — it is not baked into `size`.
//

import CoreGraphics
import CoreText
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("TextMetrics sizing (2C)")
struct TextMetricsTests {

    private func style(_ string: String, fontSize: Double = 22,
                       family: String? = nil, weight: FontWeight = .regular) -> TextStyle {
        TextStyle(string: string, fontSize: fontSize,
                  color: RGBAColor(red: 0, green: 0, blue: 0),
                  fontFamily: family, weight: weight)
    }

    // MARK: - Unconstrained (autoWidth: maxWidth == nil)

    @Test("unconstrained width grows monotonically with a longer single-line string")
    func longerStringIsWider() {
        let short = TextMetrics.size(for: style("Hi"), maxWidth: nil)
        let long = TextMetrics.size(for: style("Hello, this is a much longer line"), maxWidth: nil)
        #expect(long.width > short.width)
    }

    @Test("unconstrained height grows with a larger font size; width grows too")
    func largerFontIsTaller() {
        let small = TextMetrics.size(for: style("Sample", fontSize: 12), maxWidth: nil)
        let large = TextMetrics.size(for: style("Sample", fontSize: 48), maxWidth: nil)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
    }

    @Test("an empty string still occupies about one line height, tiny width")
    func emptyIsOneLine() {
        let empty = TextMetrics.size(for: style(""), maxWidth: nil)
        let oneLine = TextMetrics.size(for: style("X"), maxWidth: nil)
        #expect(empty.height > 0)
        // ~one line: within a pixel of a single glyph's line box.
        #expect(abs(empty.height - oneLine.height) <= 1)
        #expect(empty.width < oneLine.width + 1)
    }

    @Test("unconstrained never wraps: one line and two words stay a single line tall")
    func unconstrainedDoesNotWrap() {
        let oneWord = TextMetrics.size(for: style("Word"), maxWidth: nil)
        let manyWords = TextMetrics.size(for: style("Word word word word word word"), maxWidth: nil)
        #expect(manyWords.width > oneWord.width)         // grows sideways…
        #expect(abs(manyWords.height - oneWord.height) <= 1) // …not down (no wrap)
    }

    // MARK: - Constrained (autoHeight: maxWidth set)

    @Test("a narrow constraint wraps a long string into more lines → taller")
    func constrainedGrowsWithLineCount() {
        let text = "The quick brown fox jumps over the lazy dog again and again"
        let wide = TextMetrics.size(for: style(text), maxWidth: 1_000)
        let narrow = TextMetrics.size(for: style(text), maxWidth: 120)
        #expect(narrow.height > wide.height)      // more lines when wrapped tighter
        #expect(narrow.width <= 120 + 1)          // stays within the constraint
    }

    @Test("constrained height is monotonic as the width shrinks")
    func tighterWidthNeverShorter() {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        let widths: [CGFloat] = [400, 260, 160, 90]
        let heights = widths.map { TextMetrics.size(for: style(text), maxWidth: $0).height }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }) // non-decreasing
    }

    // MARK: - Font source is the drawing font

    @Test("weight/family affect the measured width (it uses the drawing font)")
    func measurementTracksTheFont() {
        let regular = TextMetrics.size(for: style("Weighty text", weight: .regular), maxWidth: nil)
        let bold = TextMetrics.size(for: style("Weighty text", weight: .bold), maxWidth: nil)
        // Bold glyphs are at least as wide as regular (never narrower) for the same run.
        #expect(bold.width >= regular.width)
    }

    // MARK: - Padding is the caller's job

    @Test("padding is a positive constant, separate from the measured size")
    func paddingIsSeparate() {
        #expect(TextMetrics.padding > 0)
        // `size` measures glyphs only; the caller adds `2 · padding` (054 §4.2).
        let s = TextMetrics.size(for: style("abc"), maxWidth: nil)
        #expect(s.width > 0 && s.height > 0)
    }
}
