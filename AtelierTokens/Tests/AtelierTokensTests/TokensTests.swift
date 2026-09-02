//
//  TokensTests.swift
//  AtelierTokensTests
//
//  What a token package can honestly test, and what it cannot.
//
//  It cannot test that `#212121` is the right grey — that is a design decision, and a test
//  restating it would be a fourth copy of the palette, which is the thing this package
//  exists to stop. The drift these tests used to be needed for is gone STRUCTURALLY: there
//  is one hex per colour and every representation is derived from it, so a mirror cannot
//  fall out of step with its original the way three of `Theme.NS`'s had.
//
//  What is left is real: the hex arithmetic that turns those numbers into colours, and
//  the stored-string grammar — which the app reads through parsers in three modules that
//  cannot share an implementation, and which have disagreed before.
//

import SwiftUI
import Testing

@testable import AtelierTokens

@Suite("Tokens: what the chrome modifiers rest on")
struct ChromeTokenTests {

    @Test("chip and field round the same, which is what lets one modifier serve both")
    func chipAndFieldAgree() {
        // `fieldChrome()` defaults to `Radius.field` and the collection switcher's chips
        // pass `Radius.chip`. The enum says the two names record what a call site IS
        // rather than two measurements — so if they ever stop being the same number, the
        // shared modifier stops being the right shape for one of them and the default
        // above has to be reconsidered rather than silently inherited.
        #expect(Tokens.Radius.chip == Tokens.Radius.field)
    }

    @Test("the floating elevation is one value, not three the phone can copy apart")
    func floatingIsWhole() {
        // `MobileTheme.Elevation` used to restate `floating.color`, `.radius` and `.y` as
        // three constants, because its call sites applied a shadow beside a background
        // rather than to one. `cardChrome()` is the composition that removed the reason.
        #expect(Tokens.Elevation.floating.radius == 14)
        #expect(Tokens.Elevation.floating.y == 5)
        #expect(Tokens.Elevation.floating.opacity == 0.35)
        #expect(Tokens.Elevation.floating != Tokens.Elevation.hover)
    }
}

@Suite("Tokens: the arithmetic under the palette")
struct TokensTests {

    /// `Color` has no public way back out to components, so the assertion goes through
    /// the platform's own resolution — which is also the thing that would break if the
    /// shift or the divisor were wrong.
    private func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let resolved = color.resolve(in: EnvironmentValues())
        return (
            Double(resolved.red), Double(resolved.green), Double(resolved.blue),
            Double(resolved.opacity))
    }

    private func expect(
        _ color: Color?, isNear expected: (Double, Double, Double, Double),
        _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let c = components(try #require(color, sourceLocation: sourceLocation))
        let tolerance = 0.005
        #expect(abs(c.r - expected.0) < tolerance, comment, sourceLocation: sourceLocation)
        #expect(abs(c.g - expected.1) < tolerance, comment, sourceLocation: sourceLocation)
        #expect(abs(c.b - expected.2) < tolerance, comment, sourceLocation: sourceLocation)
        #expect(abs(c.a - expected.3) < tolerance, comment, sourceLocation: sourceLocation)
    }

    @Test("a 0xRRGGBB literal decomposes into its channels")
    func hexLiteralDecomposes() throws {
        try expect(Color(hex: 0xFF0000), isNear: (1, 0, 0, 1))
        try expect(Color(hex: 0x00FF00), isNear: (0, 1, 0, 1))
        try expect(Color(hex: 0x0000FF), isNear: (0, 0, 1, 1))
        // A real token, so a transposed shift shows up as the wrong grey rather than
        // passing on symmetric fixtures.
        try expect(Color(hex: Tokens.Hex.panel), isNear: (33 / 255, 33 / 255, 33 / 255, 1))
        try expect(
            Color(hex: Tokens.Hex.inkSecondary),
            isNear: (0x9A / 255, 0x9A / 255, 0x9E / 255, 1))
    }

    /// The palette is derived from ``Tokens/Hex``, not restated beside it — this is the
    /// property that replaced the hand-copied mirrors.
    @Test("every colour token resolves to its declared number")
    func tokensResolveToTheirHex() throws {
        let pairs: [(Color, UInt32)] = [
            (Tokens.Colors.canvasOuter, Tokens.Hex.canvasOuter),
            (Tokens.Colors.panel, Tokens.Hex.panel),
            (Tokens.Colors.surface, Tokens.Hex.surface),
            (Tokens.Colors.field, Tokens.Hex.field),
            (Tokens.Colors.selection, Tokens.Hex.selection),
            (Tokens.Colors.mediaBackdrop, Tokens.Hex.mediaBackdrop),
            (Tokens.Colors.inkPrimary, Tokens.Hex.inkPrimary),
            (Tokens.Colors.inkSecondary, Tokens.Hex.inkSecondary),
        ]
        for (color, hex) in pairs {
            try expect(
                color,
                isNear: (
                    Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
                    Double(hex & 0xFF) / 255, 1
                ),
                "token does not match 0x\(String(hex, radix: 16))")
        }
    }

    /// The palette is monochrome apart from one alarm colour, and the greys are meant to
    /// be distinguishable layers. Two tokens sharing a value would be a copy-paste, not a
    /// decision — the `chip`/`field` radius pair is the app's one deliberate twinning and
    /// it is a number, not a colour.
    @Test("no two colour tokens are the same grey")
    func tokensAreDistinct() {
        let hexes = [
            Tokens.Hex.canvasOuter, Tokens.Hex.panel, Tokens.Hex.surface, Tokens.Hex.field,
            Tokens.Hex.selection, Tokens.Hex.mediaBackdrop, Tokens.Hex.inkPrimary,
            Tokens.Hex.inkSecondary,
        ]
        #expect(Set(hexes).count == hexes.count)
    }

    @Test("the 4-pt scale is a rhythm, in order")
    func spacingIsOrdered() {
        let scale = [
            Tokens.Spacing.xs, Tokens.Spacing.sm, Tokens.Spacing.md, Tokens.Spacing.lg,
            Tokens.Spacing.xl, Tokens.Spacing.xxl,
        ]
        #expect(scale == scale.sorted())
        #expect(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }
}

// MARK: - The grammar

/// The stored-string parser, which is shared with nothing and read by everything.
///
/// `AtelierRefs`' own `HexGrammarTests` pins this against the canvas and export parsers —
/// it can see all three, this package can see one. What is asserted HERE is the grammar
/// itself, so a change to it fails at the package that owns it rather than only in an app
/// test two modules away.
@Suite("Tokens: the stored hex grammar (3/4/6/8)")
struct HexStringTests {

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let resolved = color.resolve(in: EnvironmentValues())
        return (
            Double(resolved.red), Double(resolved.green), Double(resolved.blue),
            Double(resolved.opacity))
    }

    @Test("all four lengths parse, and the short forms expand like CSS")
    func fourLengths() throws {
        let six = components(try #require(Color(hexString: "#ff33aa")))
        let three = components(try #require(Color(hexString: "#f3a")))
        #expect(abs(six.r - three.r) < 0.005)
        #expect(abs(six.g - three.g) < 0.005)
        #expect(abs(six.b - three.b) < 0.005)

        // The two lengths the iOS copy of this parser did NOT take, which is how a stored
        // colour with an alpha rendered on the Mac and fell back to grey on the phone.
        let eight = components(try #require(Color(hexString: "#ff33aa80")))
        #expect(abs(eight.a - 128.0 / 255) < 0.005)
        let four = components(try #require(Color(hexString: "#f3a8")))
        #expect(abs(four.a - 136.0 / 255) < 0.005)
    }

    @Test("the leading #, surrounding space and case are all optional")
    func tolerances() throws {
        for spelling in ["#FF33AA", "ff33aa", "  #Ff33Aa  ", "FF33AA"] {
            let c = components(try #require(Color(hexString: spelling), "\(spelling) did not parse"))
            #expect(abs(c.r - 1) < 0.005)
            #expect(abs(c.b - 170.0 / 255) < 0.005)
        }
    }

    @Test("anything that is not the grammar is nil, not black", arguments: [
        "", "#", "xyz", "#gg3311", "12345", "#1234567", "#123456789", "rebeccapurple",
    ])
    func refusals(_ input: String) {
        #expect(Color(hexString: input) == nil)
    }
}
