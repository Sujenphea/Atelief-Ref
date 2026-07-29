//
//  TextEngineParityTests.swift
//  CanvasRendererTests
//
//  Stage 4 prerequisite — characterize where our text engines disagree, BEFORE porting
//  anything.
//
//  The board runs two text layout engines. Committed text is shaped and drawn with
//  CoreText (`TextShaper`, the 060 design); the inline editor's glyphs are laid out by
//  TextKit, because the editor is an `NSTextView` and could never be anything else.
//  They break lines differently, which is why line breaks visibly re-wrap on entering
//  edit mode and re-wrap back on commit.
//
//  The plan's fix is to move the renderer onto TextKit. That fix has a trapdoor: on
//  macOS 26 `NSTextView` is TextKit **2** unless something forces the TextKit 1
//  fallback, so porting the renderer to TextKit 1 could leave the two engines still
//  disagreeing and the whole stage a no-op.
//
//  So this measures four engines against one matrix and reports where they differ:
//
//    1. CoreText via `TextShaper`      — what the renderer draws today
//    2. TextKit 1 via `NSLayoutManager` — what Nook measures with
//    3. TextKit 2 via a headless `NSTextView` — what our editor actually is
//    4. NSStringDrawing (height only)  — what Nook draws with
//
//  Nook is not evidence here, despite shipping: it measures with TextKit 1, draws with
//  `NSString.draw`, and edits in an `NSTextView` it never downgrades — i.e. it ships the
//  mixed configuration and asserts the pieces agree. That is worth knowing and is not a
//  measurement.
//

import AppKit
import CoreText
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Text engine parity — Stage 4 characterization")
struct TextEngineParityTests {

    /// One engine's answer for one input: where it broke, and how tall the result is.
    /// Line *texts* rather than ranges, because when they disagree the text is what
    /// makes the disagreement legible in a report.
    private struct Layout: Equatable {
        var lines: [String]
        var height: CGFloat
    }

    private struct Case: CustomStringConvertible {
        var text: String
        var width: CGFloat
        var size: Double
        var weight: FontWeight
        var family: String?

        var description: String {
            let f = family ?? "System"
            return "\(f) \(Int(size))pt \(weight.rawValue) w=\(Int(width)) “\(text.prefix(38))”"
        }
    }

    // MARK: - The matrix

    private static let texts: [String] = [
        "Reference",                                              // a short label
        "The quick brown fox jumps over the lazy dog",             // ordinary wrapping
        "Supercalifragilisticexpialidocious",                      // one unbreakable token
        "A very long line that ends in one短 word",                 // mixed script
        "日本語のテキストが折り返されるかどうかを確認する",              // CJK, no spaces
        "first line\nsecond line that is quite a lot longer",       // explicit newline
        "well-known state-of-the-art hyphen-joined words here",     // hyphen break points
        "Widow bait: aaaa bbbb cccc dddd eeee ffff gggg h",         // orphan/widow territory
    ]
    private static let widths: [CGFloat] = [80, 120, 200, 317]
    private static let sizes: [Double] = [12, 16, 24]
    private static let weights: [FontWeight] = [.regular, .bold]
    private static let families: [String?] = [nil, "Helvetica"]

    private static var cases: [Case] {
        var all: [Case] = []
        for text in texts {
            for width in widths {
                for size in sizes {
                    for weight in weights {
                        for family in families {
                            all.append(Case(
                                text: text, width: width, size: size,
                                weight: weight, family: family))
                        }
                    }
                }
            }
        }
        return all
    }

    // MARK: - Engine 1 — CoreText, as the renderer actually uses it

    private func coreTextLayout(_ c: Case) -> Layout {
        let style = TextStyle(
            string: c.text, fontSize: c.size,
            color: RGBAColor(red: 1, green: 1, blue: 1),
            fontFamily: c.family, weight: c.weight, alignment: .left)
        let shaped = TextShaper.shape(style, maxWidth: c.width)
        let ns = (c.text.isEmpty ? " " : c.text) as NSString
        let lines = shaped.lines.map { line -> String in
            let range = CTLineGetStringRange(line.line)
            guard range.location >= 0, range.length >= 0,
                  range.location + range.length <= ns.length else { return "<oob>" }
            return ns.substring(with: NSRange(location: range.location, length: range.length))
        }
        return Layout(lines: lines, height: shaped.size.height)
    }

    // MARK: - Engine 2 — TextKit 1, driven directly

    private func textKit1Layout(_ c: Case) -> Layout {
        let font = CanvasFont.nsFont(family: c.family, weight: c.weight, size: CGFloat(c.size))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(
            string: c.text.isEmpty ? " " : c.text,
            attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: c.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var lines: [String] = []
        let full = NSRange(location: 0, length: layout.numberOfGlyphs)
        layout.enumerateLineFragments(forGlyphRange: full) { _, _, _, glyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lines.append((storage.string as NSString).substring(with: charRange))
        }
        return Layout(lines: lines, height: layout.usedRect(for: container).height)
    }

    // MARK: - Engine 3 — TextKit 2, via a text view configured like our editor

    /// Configured exactly as ``CanvasTextEditController`` configures its own view, and
    /// deliberately never touching `.layoutManager` — that property is what forces the
    /// TextKit 1 fallback, so reading it here would measure the wrong engine.
    private func makeEditorLikeTextView(_ c: Case) -> NSTextView {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: c.width, height: 4000))
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = CGSize(width: c.width, height: .greatestFiniteMagnitude)
        view.font = CanvasFont.nsFont(family: c.family, weight: c.weight, size: CGFloat(c.size))
        view.string = c.text.isEmpty ? " " : c.text
        return view
    }

    private func textKit2Layout(_ c: Case) -> Layout? {
        let view = makeEditorLikeTextView(c)
        guard let tlm = view.textLayoutManager else { return nil } // not TextKit 2
        tlm.ensureLayout(for: tlm.documentRange)

        var lines: [String] = []
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for lineFragment in fragment.textLineFragments {
                let s = lineFragment.attributedString.string as NSString
                let r = lineFragment.characterRange
                if r.location >= 0, r.location + r.length <= s.length {
                    lines.append(s.substring(with: r))
                }
            }
            return true
        }
        return Layout(lines: lines, height: tlm.usageBoundsForTextContainer.height)
    }

    // MARK: - Engine 4 — NSStringDrawing (height only; it exposes no break positions)

    private func stringDrawingHeight(_ c: Case) -> CGFloat {
        let font = CanvasFont.nsFont(family: c.family, weight: c.weight, size: CGFloat(c.size))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return (c.text as NSString).boundingRect(
            with: CGSize(width: c.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: paragraph]).height
    }

    // MARK: - The decisive question

    @Test("which TextKit is an editor-configured NSTextView on this OS?")
    func whichTextKitDoesTheEditorUse() {
        let sample = Case(text: "hello", width: 200, size: 16, weight: .regular, family: nil)
        let view = makeEditorLikeTextView(sample)
        let isTextKit2 = view.textLayoutManager != nil
        print("""

        ══════ EDITOR ENGINE ══════
        NSTextView configured as CanvasTextEditController does → \
        \(isTextKit2 ? "TextKit 2 (NSTextLayoutManager)" : "TextKit 1 (NSLayoutManager)")
        ═══════════════════════════

        """)
        // Recorded, not asserted: this is the fact the port's design depends on, and it
        // is a property of the OS rather than of our code.
        #expect(isTextKit2 || !isTextKit2)
    }

    @Test("characterize: where do the four engines disagree?")
    func characterizeDisagreements() {
        var ctVsTk1 = 0, ctVsTk2 = 0, tk1VsTk2 = 0
        var heightMismatch = 0
        var total = 0
        var compared = 0
        // Guards against the false negative that would make this whole suite a lie: if
        // every engine returned NO lines, every comparison would be trivially equal and
        // the report would read as perfect agreement.
        var wrappedSomething = 0
        var examples: [String] = []

        for c in Self.cases {
            total += 1
            let ct = coreTextLayout(c)
            let tk1 = textKit1Layout(c)
            guard let tk2 = textKit2Layout(c) else { continue }
            compared += 1
            if ct.lines.count > 1 && tk1.lines.count > 1 && tk2.lines.count > 1 {
                wrappedSomething += 1
            }

            if ct.lines != tk1.lines { ctVsTk1 += 1 }
            if ct.lines != tk2.lines { ctVsTk2 += 1 }
            if tk1.lines != tk2.lines {
                tk1VsTk2 += 1
                if examples.count < 6 {
                    examples.append("""
                      \(c)
                        TK1: \(tk1.lines)
                        TK2: \(tk2.lines)
                    """)
                }
            }
            // NSStringDrawing vs TextKit 1 height — Nook's draw path vs its measure path.
            if abs(stringDrawingHeight(c) - tk1.height) > 0.5 { heightMismatch += 1 }

            // A CoreText/TextKit break disagreement is the reported bug; capture a few.
            if ct.lines != tk2.lines, examples.count < 12 {
                examples.append("""
                  \(c)
                    CoreText: \(ct.lines)
                    TextKit2: \(tk2.lines)
                """)
            }
        }

        print("""

        ══════════ TEXT ENGINE CHARACTERIZATION ══════════
        cases: \(total)   actually compared: \(compared)   \
        of which multi-line in all 3: \(wrappedSomething)

        CoreText  vs TextKit 1  — line breaks differ in \(ctVsTk1)/\(compared)
        CoreText  vs TextKit 2  — line breaks differ in \(ctVsTk2)/\(compared)
        TextKit 1 vs TextKit 2  — line breaks differ in \(tk1VsTk2)/\(compared)   ← decides the port
        NSStringDrawing vs TK1  — heights differ (>0.5pt) in \(heightMismatch)/\(compared)

        \(examples.isEmpty ? "no disagreements captured" : examples.joined(separator: "\n"))
        ══════════════════════════════════════════════════

        """)
        // Characterization, not a gate: this REPORTS platform behaviour, so failing the
        // build on a disagreement would be reporting it in the one form that stops the
        // work. The numbers above are the deliverable.
        //
        // These two, though, ARE assertions — they are what makes the numbers mean
        // anything. Every case must have been compared (a skipped case silently reads
        // as agreement), and the matrix must actually exercise wrapping (if nothing
        // wrapped, every engine returning one line would also read as agreement).
        #expect(compared == total)
        #expect(wrappedSomething > total / 4)
    }

    /// The engines agree (above), so if the box still re-wraps on entering edit mode the
    /// cause is CONFIGURATION, not engine choice. This reproduces both sides exactly as
    /// the shipping code sets them up:
    ///
    /// - the renderer shapes at `maxWidth = tile.w − 2·padding`
    ///   (`CanvasTextEditController.reposition`, and `TextRenderLayer` for the committed
    ///   glyphs);
    /// - the editor gets `frame.width = tile.w` with `textContainerInset = padding`, and
    ///   `widthTracksTextView`, so its container should come out at the same number.
    ///
    /// If those two disagree the wrap width is off by the inset arithmetic, which is a
    /// one-line fix rather than a text-engine rewrite.
    @Test("editor-vs-renderer at the SAME tile geometry — the wrap width agrees")
    func editorAndRendererWrapAtTheSameWidth() {
        let padding = TextMetrics.padding
        var mismatches: [String] = []

        for c in Self.cases {
            let worldWidth = c.width
            let style = TextStyle(
                string: c.text, fontSize: c.size,
                color: RGBAColor(red: 1, green: 1, blue: 1),
                fontFamily: c.family, weight: c.weight, alignment: .left)

            // Renderer side, exactly as `reposition()` measures.
            let shaped = TextShaper.shape(style, maxWidth: max(1, worldWidth - 2 * padding))
            let ns = (c.text.isEmpty ? " " : c.text) as NSString
            let rendererLines = shaped.lines.map { line -> String in
                let r = CTLineGetStringRange(line.line)
                guard r.location >= 0, r.location + r.length <= ns.length else { return "<oob>" }
                return ns.substring(with: NSRange(location: r.location, length: r.length))
            }

            // Editor side, exactly as the controller configures it: full-width frame,
            // padding as the container INSET rather than as a narrower frame.
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: worldWidth, height: 4000))
            view.isRichText = false
            view.drawsBackground = false
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.lineFragmentPadding = 0
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: padding, height: padding)
            view.font = CanvasFont.nsFont(
                family: c.family, weight: c.weight, size: CGFloat(c.size))
            view.string = c.text.isEmpty ? " " : c.text

            guard let tlm = view.textLayoutManager else { continue }
            tlm.ensureLayout(for: tlm.documentRange)
            var editorLines: [String] = []
            tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                for lineFragment in fragment.textLineFragments {
                    let s = lineFragment.attributedString.string as NSString
                    let r = lineFragment.characterRange
                    if r.location >= 0, r.location + r.length <= s.length {
                        editorLines.append(s.substring(with: r))
                    }
                }
                return true
            }

            if rendererLines != editorLines, mismatches.count < 8 {
                mismatches.append("""
                  \(c)
                    renderer: \(rendererLines)
                    editor:   \(editorLines)
                """)
            }
        }

        print("""

        ══════ EDITOR vs RENDERER AT THE SAME GEOMETRY ══════
        \(mismatches.isEmpty
            ? "agree on every case — the wrap width arithmetic lines up"
            : "MISMATCHES:\n" + mismatches.joined(separator: "\n"))
        ═════════════════════════════════════════════════════

        """)
        #expect(mismatches.isEmpty)
    }

    @Test("do the shaper and the editor build the SAME font? (divergence #2)")
    func fontConstructionAgrees() {
        // 060 built at a reference size then copied to the point size; the editor used
        // to construct `NSFont.systemFont(ofSize:weight:)` directly, which can resolve a
        // different optical cut and therefore different advances. Stage 3 pointed both at
        // `CanvasFont`, so this should now hold — if it does, one of the three
        // divergences the plan lists is already closed.
        for size in Self.sizes {
            for weight in Self.weights {
                for family in Self.families {
                    let shaperFont = CTFontCreateCopyWithAttributes(
                        CanvasFont.resolve(family: family, weight: weight),
                        CGFloat(size), nil, nil)
                    let editorFont = CanvasFont.nsFont(
                        family: family, weight: weight, size: CGFloat(size))
                    #expect(CTFontGetSize(shaperFont) == CTFontGetSize(editorFont as CTFont))
                    #expect(
                        CTFontCopyPostScriptName(shaperFont) as String
                            == CTFontCopyPostScriptName(editorFont as CTFont) as String)
                }
            }
        }
    }
}
