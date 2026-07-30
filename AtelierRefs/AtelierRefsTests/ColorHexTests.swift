//
//  ColorHexTests.swift
//  AtelierRefsTests
//
//  The app-layer color conversions for the C1 color kind (003 · multi-kind):
//  `Color(hexString:)` (storage hex → SwiftUI Color) and `toHexString()` (a
//  ColorPicker selection → storable canonical hex). The pair must round-trip so
//  a picked color and the swatch that renders it agree.
//

import SwiftUI
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Color hex conversions (003 · C1)")
struct ColorHexTests {

    @Test("a canonical hex round-trips through Color and back", arguments: [
        "#ff0000", "#00ff00", "#0000ff", "#123abc", "#ffffff", "#000000",
    ])
    func roundTrips(hex: String) {
        let color = Color(hexString: hex)
        #expect(color != nil)
        #expect(color?.toHexString() == hex)
    }

    @Test("Color(hexString:) accepts an optional leading '#' and rejects junk")
    func parsing() {
        #expect(Color(hexString: "ff0000") != nil)   // no '#'
        #expect(Color(hexString: "#ff0000") != nil)
        #expect(Color(hexString: "nope") == nil)
        #expect(Color(hexString: "") == nil)
        // Shorthand now PARSES. It used to be rejected here on the grounds that it is
        // "canonicalized upstream" — true of a `ColorPayload`, which `AppServices`
        // rewrites to `#rrggbb` on write, but NOT of an `ElementStyle` colour, which
        // is stored as given. The three parsers that read these strings disagreed
        // about shorthand until `HexGrammarTests` pinned them to one grammar.
        #expect(Color(hexString: "#fff") != nil)
    }

    @Test("toHexString emits lowercase #rrggbb")
    func emitsCanonical() {
        let hex = Color(.sRGB, red: 1, green: 0, blue: 0).toHexString()
        #expect(hex == "#ff0000")
    }
}
