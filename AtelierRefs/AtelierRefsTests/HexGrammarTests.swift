//
//  HexGrammarTests.swift
//  AtelierRefsTests
//
//  The app reads one kind of stored string — a CSS hex colour — through THREE
//  parsers, in three modules that cannot share an implementation:
//
//    • `AtelierExport.RGBA.init(hex:)`      — the export renderer
//    • `ElementRendering.rgba(fromHex:)`    — the canvas
//    • `Color.init?(hexString:)`            — SwiftUI chrome
//
//  `AtelierExport` has zero product dependencies by design, so the duplication is
//  structural and staying. What is NOT acceptable is the three disagreeing, which
//  they did: 3/4/6/8 vs 6/8 vs 6-only, so a `#f3a` drew in an export, vanished on
//  the board, and fell back to a placeholder in the inspector.
//
//  These tests are the seam that keeps them honest. A parser that gains or loses a
//  length here fails until all three move together.
//

import SwiftUI
import Testing

@testable import AtelierRefs

import AtelierExport
import CanvasRenderer

@Suite("Hex grammar — three parsers, one grammar")
struct HexGrammarTests {

    /// Channel-wise comparison; the three return three different colour types.
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

    /// Every parser must REJECT these, or a malformed stored value renders as a
    /// wrong colour on one surface and a fallback on another.
    private func allReject(_ input: String) {
        #expect(RGBA(hex: input) == nil, "RGBA accepted \(input)")
        #expect(ElementRendering.rgba(fromHex: input) == nil,
                "ElementRendering accepted \(input)")
        #expect(Color(hexString: input) == nil, "Color accepted \(input)")
    }

    @Test("Six digits — the canonical form")
    func sixDigits() {
        agree("#ff8800", r: 1, g: 0x88 / 255, b: 0)
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
    }

    @Test("Digits are case-insensitive")
    func caseInsensitive() {
        agree("#FF8800", r: 1, g: 0x88 / 255, b: 0)
    }

    @Test("Surrounding whitespace is tolerated")
    func whitespace() {
        agree("  #ff8800\n", r: 1, g: 0x88 / 255, b: 0)
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
    }
}
