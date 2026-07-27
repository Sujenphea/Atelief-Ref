//
//  TextShaperTests.swift
//  CanvasRendererTests
//
//  060 §7 · 061 Step 1 — the CRUX suite. Shaping is the one place line breaking
//  happens, it runs in WORLD space, and it has no scale input at all: these tests
//  pin that property (a layout is a pure function of its world inputs), that
//  measurement reads the very layout that gets drawn, and that end-truncation is
//  decided here rather than per-frame.
//
//  Posture matches the 2C suite (055 §4): BOUNDED + STRUCTURAL assertions, not
//  brittle exact-pixel pins — glyph advances differ across macOS versions and
//  installed faces, so an exact break index would be a false failure waiting to
//  happen. What IS pinned exactly is *stability*: identical inputs must give
//  byte-identical breaks and origins.
//

import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("TextShaper world-space layout (060 · zoom-invariance)")
struct TextShaperTests {

    private func style(_ string: String, fontSize: Double = 20,
                       family: String? = nil, weight: FontWeight = .regular,
                       alignment: TextAlignment = .left) -> TextStyle {
        TextStyle(string: string, fontSize: fontSize,
                  color: RGBAColor(red: 0, green: 0, blue: 0),
                  fontFamily: family, weight: weight, alignment: alignment)
    }

    /// A string long enough to wrap several times at the widths used below.
    private let overflowing = "The quick brown fox jumps over the lazy dog again and again and again"

    private func ranges(_ shaped: ShapedText) -> [CFRange] {
        shaped.lines.map { CTLineGetStringRange($0.line) }
    }

    // MARK: - The invariant: layout is a pure function of WORLD inputs

    @Test("shaping takes no scale: identical world inputs give identical breaks + origins")
    func shapingIsPureInItsWorldInputs() {
        let s = style(overflowing)
        let first = TextShaper.shape(s, maxWidth: 240)
        // Clear the memo so the second call genuinely re-shapes rather than
        // returning the same cached object — a cache hit would prove nothing.
        TextShaper.resetCache()
        let second = TextShaper.shape(s, maxWidth: 240)

        #expect(first.lines.count == second.lines.count)
        #expect(first.lines.count > 1)          // it really did wrap
        #expect(first.size == second.size)
        for (a, b) in zip(ranges(first), ranges(second)) {
            #expect(a.location == b.location)
            #expect(a.length == b.length)
        }
        for (a, b) in zip(first.lines, second.lines) {
            #expect(a.origin == b.origin)       // exact, not approximate
        }
    }

    @Test("the memo key carries no scale — only world inputs")
    func keyHasNoScaleComponent() {
        let s = style(overflowing)
        let a = TextShaper.shape(s, maxWidth: 240).key
        let b = TextShaper.shape(s, maxWidth: 240).key
        #expect(a == b)
        // A different WORLD width is a different layout…
        #expect(TextShaper.shape(s, maxWidth: 300).key != a)
        // …but nothing about the viewport can reach the key: the only way to get
        // a different layout is to change the style or the world box.
        #expect(TextShaper.shape(style(overflowing, fontSize: 21), maxWidth: 240).key != a)
    }

    @Test("wrapped lines cover the whole string, in order, each within the box width")
    func breaksAreWellFormed() {
        let width: CGFloat = 200
        let shaped = TextShaper.shape(style(overflowing), maxWidth: width)
        let lines = shaped.lines
        #expect(lines.count > 2)

        // Coverage: line ranges tile the string front-to-back with no gap/overlap.
        var cursor = 0
        for line in lines {
            let r = CTLineGetStringRange(line.line)
            #expect(Int(r.location) == cursor)
            cursor += Int(r.length)
        }
        #expect(cursor == (overflowing as NSString).length)

        // Every line fits the box it was broken against.
        for line in lines {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CTLineGetTypographicBounds(line.line, &a, &d, &l)
                - CTLineGetTrailingWhitespaceWidth(line.line)
            #expect(CGFloat(w) <= width + 0.5)
        }
    }

    @Test("baselines march monotonically down, about one line height apart")
    func baselinesAreOrderedAndEvenlySpaced() {
        let shaped = TextShaper.shape(style(overflowing), maxWidth: 200)
        let ys = shaped.lines.map(\.origin.y)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })   // strictly downward
        for (a, b) in zip(ys, ys.dropFirst()) {
            #expect(abs((b - a) - shaped.lineHeight) <= 1)        // uniform spacing
        }
        // First baseline sits one ascent below the box top (the top-left anchor
        // `CATextLayer` uses, which 060 §2 preserves).
        #expect(ys.first ?? 0 > 0)
        #expect((ys.first ?? 0) < shaped.lineHeight + 1)
    }

    // MARK: - measure ≡ draw

    @Test("TextMetrics.size is exactly the shaped layout's size, across a matrix")
    func measureEqualsShape() {
        let strings = ["Hi", "", overflowing, "one two three four five", "M"]
        let widths: [CGFloat?] = [nil, 90, 160, 400]
        let weights: [FontWeight] = [.regular, .bold]
        for string in strings {
            for width in widths {
                for weight in weights {
                    let s = style(string, weight: weight)
                    #expect(TextMetrics.size(for: s, maxWidth: width) == TextShaper.shape(s, maxWidth: width).size)
                }
            }
        }
    }

    @Test("the measured height tracks the shaped line count")
    func heightFollowsLineCount() {
        let s = style(overflowing)
        let wide = TextShaper.shape(s, maxWidth: 1_000)
        let narrow = TextShaper.shape(s, maxWidth: 120)
        #expect(narrow.lines.count > wide.lines.count)
        #expect(narrow.size.height > wide.size.height)
        // Height ≈ lines × lineHeight (within the ceil + leading slack).
        let expected = CGFloat(narrow.lines.count) * narrow.lineHeight
        #expect(abs(narrow.size.height - expected) <= narrow.lineHeight)
    }

    @Test("an empty string shapes to one line height")
    func emptyIsOneLine() {
        let shaped = TextShaper.shape(style(""), maxWidth: nil)
        #expect(shaped.lines.count == 1)
        #expect(abs(shaped.size.height - ceil(shaped.lineHeight)) <= 1)
    }

    // MARK: - Alignment (a per-line pen offset within the content width)

    @Test("alignment offsets the line origin: left 0 < center < right")
    func alignmentOffsetsOrigins() {
        let width: CGFloat = 400
        let text = "short line"
        let left = TextShaper.shape(style(text, alignment: .left), maxWidth: width)
        let center = TextShaper.shape(style(text, alignment: .center), maxWidth: width)
        let right = TextShaper.shape(style(text, alignment: .right), maxWidth: width)

        #expect(left.lines[0].origin.x == 0)
        #expect(center.lines[0].origin.x > left.lines[0].origin.x)
        #expect(right.lines[0].origin.x > center.lines[0].origin.x)
        #expect(right.lines[0].origin.x <= width)
        // Alignment must not change line BREAKING — only placement.
        #expect(left.lines.count == center.lines.count)
        #expect(left.size.width == right.size.width)
    }

    // MARK: - End truncation (decided HERE, at shape time — 060 §1)

    @Test("a maxHeight clips lines to the box and truncates the last visible one")
    func truncationClipsAndEllipsizes() {
        let s = style(overflowing)
        let full = TextShaper.shape(s, maxWidth: 160)
        #expect(full.lines.count >= 4)

        // A box tall enough for exactly two lines.
        let twoLines = full.lineHeight * 2
        let clipped = TextShaper.shape(s, maxWidth: 160, maxHeight: twoLines)
        #expect(clipped.lines.count == 2)
        #expect(clipped.lines.count < full.lines.count)

        // The last visible line is NOT the untruncated line — it carries the
        // ellipsis (its glyph run differs from the shaped-in-full counterpart).
        let cut = clipped.lines[1].line
        let uncut = full.lines[1].line
        #expect(CTLineGetGlyphCount(cut) != CTLineGetGlyphCount(uncut)
                || CTLineGetStringRange(cut).length != CTLineGetStringRange(uncut).length)
        // …and it still fits the box.
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CTLineGetTypographicBounds(cut, &a, &d, &l)
        #expect(CGFloat(w) <= 160 + 1)
    }

    @Test("truncation is world geometry: the same box always cuts at the same place")
    func truncationIsStable() {
        let s = style(overflowing)
        let height = TextShaper.shape(s, maxWidth: 160).lineHeight * 2
        let first = TextShaper.shape(s, maxWidth: 160, maxHeight: height)
        TextShaper.resetCache()
        let second = TextShaper.shape(s, maxWidth: 160, maxHeight: height)
        #expect(first.lines.count == second.lines.count)
        #expect(CTLineGetStringRange(first.lines.last!.line).length
                == CTLineGetStringRange(second.lines.last!.line).length)
    }

    @Test("no maxHeight never truncates — measurement callers see the full layout")
    func measurementNeverTruncates() {
        let s = style(overflowing)
        let shaped = TextShaper.shape(s, maxWidth: 160)
        let covered = shaped.lines.reduce(0) { $0 + Int(CTLineGetStringRange($1.line).length) }
        #expect(covered == (overflowing as NSString).length)
    }

    @Test("a box shorter than one line still shows a line (never blank)")
    func alwaysKeepsOneLine() {
        let shaped = TextShaper.shape(style(overflowing), maxWidth: 160, maxHeight: 1)
        #expect(shaped.lines.count == 1)
    }

    @Test("a token wider than the box falls back to the untruncated line")
    func degenerateTokenFallsBack() {
        // A box far narrower than the ellipsis at this size: truncation returns
        // nil and we must keep the shaped line rather than dropping it.
        let shaped = TextShaper.shape(style(overflowing, fontSize: 64), maxWidth: 4, maxHeight: 8)
        #expect(shaped.lines.count == 1)
        #expect(CTLineGetGlyphCount(shaped.lines[0].line) > 0)
    }

    // MARK: - Cache behaviour

    @Test("the memo returns an equal layout and survives overflow clearing")
    func cacheIsBoundedAndCorrect() {
        let s = style(overflowing)
        let before = TextShaper.shape(s, maxWidth: 240)
        // Blow past the cap with distinct widths, then re-request the original.
        for i in 0..<300 { _ = TextShaper.shape(s, maxWidth: CGFloat(100 + i)) }
        let after = TextShaper.shape(s, maxWidth: 240)
        #expect(before.lines.count == after.lines.count)
        #expect(before.size == after.size)
        for (a, b) in zip(ranges(before), ranges(after)) {
            #expect(a.location == b.location && a.length == b.length)
        }
    }
}
