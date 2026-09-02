//
//  HexGrammarTests.swift
//  AtelierRefsTests
//
//  The app reads one kind of stored string — a CSS hex colour — through THREE
//  parsers, in three modules that cannot share an implementation:
//
//    • `AtelierExport.RGBA.init(hex:)`      — the export renderer
//    • `ElementRendering.rgba(fromHex:)`    — the canvas
//    • `AtelierTokens`' `Color.init?(hexString:)` — SwiftUI chrome, BOTH platforms
//    • `AtelierIngestion.ColorPalette.rgb(fromHex:)` — the colour-bucket filer (099 · 2A)
//
//  `AtelierExport` has zero product dependencies by design, so that duplication is
//  structural and staying. What is NOT acceptable is the three disagreeing, which
//  they did: 3/4/6/8 vs 6/8 vs 6-only, so a `#f3a` drew in an export, vanished on
//  the board, and fell back to a placeholder in the inspector.
//
//  **There were four for a while.** The SwiftUI parser was written a second time for
//  iOS (`GridTile.swift`), taking 3/6 — so a stored colour with an alpha rendered on
//  the Mac and fell back to grey on the phone, the same divergence by a different
//  road. It moved into `AtelierTokens` with the design tokens, which both platforms
//  link, so the row below now covers the phone as well as this app.
//
//  **The fourth was found later, and is a different shape** (099 · 2A).
//  `ColorPalette.rgb(fromHex:)` files a stored swatch into a colour bucket, and it
//  takes SIX DIGITS ONLY — on purpose: it reads only what `ColorSwatch.encodeList`
//  writes, never a colour a person typed. So it joins the agreement tests on the
//  six-digit forms and the rejection matrix, and `theFourthParserIsSixDigitsOnly`
//  pins the narrowness itself, so "it stopped taking `#f80`" cannot become an
//  unexplained failure and "it started taking `#f80`" cannot go unnoticed.
//
//  It was ALREADY divergent when it was measured against the other three, in the
//  one way nothing was looking: it trimmed `.whitespaces` where the others trim
//  `.whitespacesAndNewlines`, so a stored value with a trailing newline was a
//  colour on three surfaces and "not a colour" here. That is fixed, and the
//  `whitespace` case below is what would have caught it.
//
//  These tests are the seam that keeps them honest. A parser that gains or loses a
//  length here fails until all four move together.
//

import AtelierIngestion
import AtelierTokens
import SwiftUI
import Testing

@testable import AtelierRefs

import AtelierExport
import CanvasRenderer

@Suite("Hex grammar — four parsers, one grammar")
struct HexGrammarTests {

    /// Channel-wise comparison; the parsers return different colour types.
    ///
    /// `ColorPalette` is checked only via ``paletteAgrees(_:r:g:b:)`` from the
    /// six-digit cases — it does not take the short forms or the alpha forms, and
    /// ``theFourthParserIsSixDigitsOnly`` says why.
    private func agree(
        _ input: String, r: Double, g: Double, b: Double, a: Double = 1,
        _ comment: Comment? = nil
    ) {
        let tolerance = 0.001

        guard let export = RGBA(hex: input) else {
            Issue.record("RGBA rejected \(input)"); return
        }
        #expect(abs(export.red - r) < tolerance, comment)
        #expect(abs(export.green - g) < tolerance, comment)
        #expect(abs(export.blue - b) < tolerance, comment)
        #expect(abs(export.alpha - a) < tolerance, comment)

        guard let canvas = ElementRendering.rgba(fromHex: input) else {
            Issue.record("ElementRendering rejected \(input)"); return
        }
        #expect(abs(canvas.red - r) < tolerance, comment)
        #expect(abs(canvas.green - g) < tolerance, comment)
        #expect(abs(canvas.blue - b) < tolerance, comment)
        #expect(abs(canvas.alpha - a) < tolerance, comment)

        guard let swiftUI = Color(hexString: input),
              let resolved = NSColor(swiftUI).usingColorSpace(.sRGB) else {
            Issue.record("Color rejected \(input)"); return
        }
        #expect(abs(resolved.redComponent - r) < tolerance, comment)
        #expect(abs(resolved.greenComponent - g) < tolerance, comment)
        #expect(abs(resolved.blueComponent - b) < tolerance, comment)
        #expect(abs(resolved.alphaComponent - a) < tolerance, comment)
    }

    /// The fourth parser, on the one form it shares with the other three. Returns
    /// 0…255 channels rather than 0…1, so the comparison is in its own units — a
    /// conversion here would be a fifth opinion about the grammar.
    private func paletteAgrees(_ input: String, r: Double, g: Double, b: Double) {
        guard let palette = ColorPalette.rgb(fromHex: input) else {
            Issue.record("ColorPalette rejected \(input)"); return
        }
        #expect(palette.r == UInt8((r * 255).rounded()))
        #expect(palette.g == UInt8((g * 255).rounded()))
        #expect(palette.b == UInt8((b * 255).rounded()))
    }

    /// Every parser must REJECT these, or a malformed stored value renders as a
    /// wrong colour on one surface and a fallback on another.
    private func allReject(_ input: String) {
        #expect(RGBA(hex: input) == nil, "RGBA accepted \(input)")
        #expect(ElementRendering.rgba(fromHex: input) == nil,
                "ElementRendering accepted \(input)")
        #expect(Color(hexString: input) == nil, "Color accepted \(input)")
        #expect(ColorPalette.rgb(fromHex: input) == nil, "ColorPalette accepted \(input)")
    }

    @Test("Six digits — the canonical form")
    func sixDigits() {
        agree("#ff8800", r: 1, g: 0x88 / 255, b: 0)
        paletteAgrees("#ff8800", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Three-digit shorthand expands each nibble, like CSS")
    func threeDigits() {
        // The regression that motivated this suite: only the export package took it.
        agree("#f80", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Eight digits carry alpha")
    func eightDigits() {
        agree("#ff880080", r: 1, g: 0x88 / 255, b: 0, a: 0x80 / 255)
    }

    @Test("Four-digit shorthand expands with alpha")
    func fourDigits() {
        agree("#f808", r: 1, g: 0x88 / 255, b: 0, a: 0x88 / 255)
    }

    @Test("The leading hash is optional")
    func bareHash() {
        agree("ff8800", r: 1, g: 0x88 / 255, b: 0)
        paletteAgrees("ff8800", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Digits are case-insensitive")
    func caseInsensitive() {
        agree("#FF8800", r: 1, g: 0x88 / 255, b: 0)
        paletteAgrees("#FF8800", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Surrounding whitespace is tolerated")
    func whitespace() {
        agree("  #ff8800\n", r: 1, g: 0x88 / 255, b: 0)
        // The trailing NEWLINE is the point. `ColorPalette` trimmed `.whitespaces`
        // only, so this exact string was a colour on three surfaces and nothing on
        // the fourth — found by adding it to this suite (099 · 2A).
        paletteAgrees("  #ff8800\n", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Malformed strings are rejected by all three", arguments: [
        "", "#", "#ff", "#fffff", "#fffffff", "#fffffffff",
        "nothex", "#gggggg", "#ff88zz", "rgb(1,2,3)",
    ])
    func malformed(_ input: String) {
        allReject(input)
    }

    // MARK: - Round trip

    @Test("The canvas emits lowercase, and re-reads what it wrote")
    func roundTrip() {
        let encoded = ElementRendering.hex(from: RGBAColor(red: 1, green: 0x88 / 255, blue: 0))
        #expect(encoded == encoded.lowercased(),
                "the app's other emitters are lowercase; this was the odd one out")
        agree(encoded, r: 1, g: 0x88 / 255, b: 0)
        paletteAgrees(encoded, r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("A translucent colour round-trips through the 8-digit form")
    func roundTripAlpha() {
        let encoded = ElementRendering.hex(
            from: RGBAColor(red: 1, green: 0x88 / 255, blue: 0, alpha: 0x80 / 255))
        #expect(encoded.count == 9, "expected #rrggbbaa, got \(encoded)")
        agree(encoded, r: 1, g: 0x88 / 255, b: 0, a: 0x80 / 255)
    }

    @Test("The board's text default parses back to white on every surface")
    func textDefaultRoundTrips() {
        // `defaultTextColorHex` is what a new text box stores, and all three parsers
        // read it back — the canvas to draw, the export to render, the inspector to
        // seed its picker.
        agree(ElementRendering.defaultTextColorHex, r: 1, g: 1, b: 1)
        paletteAgrees(ElementRendering.defaultTextColorHex, r: 1, g: 1, b: 1)
    }

    // MARK: - The fourth parser's deliberate narrowness

    @Test("The colour-bucket parser takes SIX digits only, and says so", arguments: [
        "#f80", "#f808", "#ff880080",
    ])
    func theFourthParserIsSixDigitsOnly(_ input: String) {
        // These three are valid to the other parsers and this file asserts above
        // that they are. `ColorPalette.rgb(fromHex:)` refuses them because it reads
        // exactly one producer — `ColorSwatch.encodeList(_:)`, which always writes
        // `#rrggbb` — and a liberal parse there would mean a bucket assigned from a
        // string nothing in the library can store. The narrowness is the contract;
        // this test is where it is written down.
        #expect(RGBA(hex: input) != nil, "the premise: the others DO take \(input)")
        #expect(ColorPalette.rgb(fromHex: input) == nil)
    }
}
