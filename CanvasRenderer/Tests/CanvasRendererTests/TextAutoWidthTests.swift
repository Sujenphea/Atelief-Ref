//
//  TextAutoWidthTests.swift
//  CanvasRendererTests
//
//  063 §5 — the measurement contract behind an auto-width text box.
//
//  A hugging box is sized by measuring UNCONSTRAINED and storing that width. It is
//  then drawn — and edited — CONSTRAINED to exactly that width. So the whole feature
//  rests on one property that nothing else in the codebase needed before:
//
//      shaping at the width you just measured must not wrap.
//
//  If it does, the last word drops to a second line the instant you commit, or worse,
//  mid-typing. `noWrapAtTheHuggedWidth` is that property stated directly, and
//  `editorAgreesAtTheHuggedWidth` is the same question asked of the TextKit side,
//  because the editor lays the glyphs out and the shaper only measures them.
//
//  067 measured 0/384 line-break disagreements between CoreText and TextKit, so the
//  cross-engine half of this is expected to hold comfortably. These are kept anyway:
//  they pin the specific arithmetic 063 introduced (measure → +2·padding → re-shape),
//  which no amount of engine agreement guarantees on its own.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Text auto-width measurement (063)")
struct TextAutoWidthTests {

    private static let strings = [
        "Text",
        "A short label",
        "The quick brown fox jumps over the lazy dog",
        "Supercalifragilisticexpialidocious",          // one unbreakable token
        "日本語のテキストです",                            // no spaces to break at
        "Trailing space matters ",
        "hyphen-joined-words-run-long",
        "A sentence\nwith a hard break",
    ]
    private static let sizes: [Double] = [11, 16, 32]
    private static let weights: [FontWeight] = [.regular, .bold]

    private static let cases: [(String, Double, FontWeight)] =
        strings.flatMap { s in sizes.flatMap { z in weights.map { (s, z, $0) } } }

    private func style(_ text: String, _ size: Double, _ weight: FontWeight) -> TextStyle {
        TextStyle(
            string: text, fontSize: size,
            color: RGBAColor(red: 0, green: 0, blue: 0),
            weight: weight, hugsWidth: true)
    }

    // MARK: - The property the whole feature rests on

    @Test("re-shaping at the width just measured does not wrap")
    func noWrapAtTheHuggedWidth() {
        var checked = 0, wrapped: [String] = []
        for (text, size, weight) in Self.cases {
            let s = style(text, size, weight)
            let free = TextShaper.shape(s, maxWidth: nil)
            // Exactly what the model stores, and what the box is then shaped against.
            let inner = free.size.width
            let again = TextShaper.shape(s, maxWidth: inner)
            checked += 1
            if again.lines.count != free.lines.count {
                wrapped.append("\(text) @\(size)/\(weight): \(free.lines.count) → \(again.lines.count)")
            }
        }
        #expect(checked == Self.cases.count)   // the loop actually ran
        #expect(wrapped.isEmpty, "re-wrapped at its own measured width: \(wrapped)")
    }

    @Test("a hard newline still breaks — hugging is not 'one line', it is 'no wrapping'")
    func explicitNewlinesSurvive() {
        let s = style("A sentence\nwith a hard break", 16, .regular)
        #expect(TextShaper.shape(s, maxWidth: nil).lines.count == 2)
    }

    // MARK: - The TextKit half

    @Test("the editor lays out the same line count at the hugged width")
    func editorAgreesAtTheHuggedWidth() {
        var compared = 0, disagreed: [String] = []
        for (text, size, weight) in Self.cases where !text.isEmpty {
            let s = style(text, size, weight)
            let inner = TextShaper.shape(s, maxWidth: nil).size.width
            let expected = TextShaper.shape(s, maxWidth: inner).lines.count

            // Configured as `CanvasTextEditController` configures its own, given the
            // width a hugging box would hand it.
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: inner, height: 4000))
            view.isRichText = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.size = CGSize(width: inner, height: .greatestFiniteMagnitude)
            view.font = CanvasFont.nsFont(family: nil, weight: weight, size: CGFloat(size))
            view.string = text
            guard let tlm = view.textLayoutManager else { continue }
            tlm.ensureLayout(for: tlm.documentRange)
            var lines = 0
            tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { f in
                lines += f.textLineFragments.count
                return true
            }
            compared += 1
            if lines != expected {
                disagreed.append("\(text) @\(size)/\(weight): shaper \(expected), editor \(lines)")
            }
        }
        // Without this the guard above could skip everything and the suite would pass
        // having compared nothing — the failure mode 067 nearly shipped.
        #expect(compared == Self.cases.count)
        #expect(disagreed.isEmpty, "editor and shaper disagree at the hugged width: \(disagreed)")
    }

    // MARK: - TextMetrics.size(for:hugging:outerWidth:)

    @Test("hugging ignores the outer width it is passed")
    func huggingIgnoresOuterWidth() {
        let s = style("A short label", 16, .regular)
        let a = TextMetrics.size(for: s, hugging: true, outerWidth: 10)
        let b = TextMetrics.size(for: s, hugging: true, outerWidth: 5_000)
        #expect(a == b)
    }

    @Test("fixed measures against the outer width, minus both paddings")
    func fixedUsesOuterWidth() {
        var s = style("The quick brown fox jumps over the lazy dog", 16, .regular)
        s.hugsWidth = false
        let viaHelper = TextMetrics.size(for: s, hugging: false, outerWidth: 200)
        let direct = TextMetrics.size(for: s, maxWidth: 200 - 2 * TextMetrics.padding)
        #expect(viaHelper == direct)
    }

    @Test("past the cap it wraps instead of running on")
    func capWraps() {
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40)
        let s = style(long, 16, .regular)
        let free = TextMetrics.size(for: s, maxWidth: nil)
        let capped = TextMetrics.size(for: s, hugging: true, outerWidth: 0)

        #expect(free.width > TextMetrics.maxAutoWidth)      // the premise
        #expect(capped.width <= TextMetrics.maxAutoWidth)   // …and it is honoured
        #expect(capped.height > free.height)                // it grew downward instead
    }

    @Test("under the cap nothing is clamped")
    func underCapIsUntouched() {
        let s = style("A short label", 16, .regular)
        #expect(TextMetrics.size(for: s, hugging: true, outerWidth: 0)
                == TextMetrics.size(for: s, maxWidth: nil))
    }

    // MARK: - The world box

    @Test("a hugging editor box takes the measured width; a fixed one takes the tile's")
    func worldBoxBranchesOnTheFlag() {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 200)   // 300 world at 2×
        let measured = CGSize(width: 180, height: 96)

        let hug = canvasInlineEditorWorldBox(
            tileScreenFrame: screen, scale: 2, measuredWorldSize: measured, hugsWidth: true)
        let fixed = canvasInlineEditorWorldBox(
            tileScreenFrame: screen, scale: 2, measuredWorldSize: measured, hugsWidth: false)

        #expect(hug.width == 180 + 2 * TextMetrics.padding)
        #expect(fixed.width == 300)                 // 062's behaviour, unchanged
        #expect(hug.height == fixed.height)         // the height rule is shared
    }

    @Test("a hugging box's layout width is still identical at every zoom")
    func hugIsZoomInvariant() {
        // 060's invariant is not weakened by 063: the width now comes from the
        // measurement rather than the tile, and the measurement has no zoom in it.
        let measured = CGSize(width: 180, height: 96)
        let widths = [0.25, 0.5, 1, 2, 4, 8].map { (scale: CGFloat) in
            canvasInlineEditorWorldBox(
                tileScreenFrame: CGRect(x: 0, y: 0, width: 300 * scale, height: 200 * scale),
                scale: scale, measuredWorldSize: measured, hugsWidth: true).width
        }
        #expect(Set(widths).count == 1)
    }
}
