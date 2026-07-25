// AtelierExport — RGBA hex-parsing tests (052 · 10A layer 1)

import Testing
@testable import AtelierExport

@Suite("RGBA hex parsing")
struct RGBATests {

    @Test("Six-digit hex parses each channel")
    func sixDigit() throws {
        let c = try #require(RGBA(hex: "#3366cc"))
        #expect(abs(c.red - 0x33 / 255.0) < 1e-9)
        #expect(abs(c.green - 0x66 / 255.0) < 1e-9)
        #expect(abs(c.blue - 0xcc / 255.0) < 1e-9)
        #expect(c.alpha == 1)
    }

    @Test("Leading hash is optional")
    func noHash() throws {
        let a = try #require(RGBA(hex: "ff0000"))
        let b = try #require(RGBA(hex: "#ff0000"))
        #expect(a == b)
    }

    @Test("Eight-digit hex carries alpha")
    func eightDigit() throws {
        let c = try #require(RGBA(hex: "#00000080"))
        #expect(c.red == 0)
        #expect(abs(c.alpha - 0x80 / 255.0) < 1e-9)
    }

    @Test("Three-digit shorthand expands each nibble")
    func threeDigit() throws {
        let short = try #require(RGBA(hex: "#f3a"))
        let long = try #require(RGBA(hex: "#ff33aa"))
        #expect(short == long)
    }

    @Test("Four-digit shorthand expands with alpha")
    func fourDigit() throws {
        let short = try #require(RGBA(hex: "#f3a8"))
        let long = try #require(RGBA(hex: "#ff33aa88"))
        #expect(short == long)
    }

    @Test("Case-insensitive")
    func caseInsensitive() throws {
        #expect(RGBA(hex: "#ABCDEF") == RGBA(hex: "#abcdef"))
    }

    @Test("White and black constants")
    func constants() throws {
        #expect(RGBA(hex: "#ffffff") == .white)
        #expect(RGBA(hex: "#000000") == .black)
    }

    @Test("Malformed strings return nil", arguments: [
        "", "#", "xyz", "#12", "#12345", "#1234567", "#123456789", "nothex", "#gggggg",
    ])
    func malformed(_ input: String) {
        #expect(RGBA(hex: input) == nil)
    }

    @Test("Channels clamp to 0...1")
    func clamp() {
        let over = RGBA(red: 2, green: -1, blue: 0.5, alpha: 9)
        #expect(over.red == 1)
        #expect(over.green == 0)
        #expect(over.blue == 0.5)
        #expect(over.alpha == 1)
    }
}
