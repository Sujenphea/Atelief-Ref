//
//  ElementStyleTextTests.swift
//  AtelierCoreTests
//
//  054 §1 / §1.1 (2A) — the rich-text `ElementStyle` fields + typed accessors.
//  The store column is a forgiving JSON blob (D1: all-optional, no migration), so
//  the contract is: new fields round-trip; legacy rows (no new keys) decode to
//  four nils and the accessors return today's defaults; an unknown/malformed token
//  degrades to the owned default rather than throwing.
//
//  062 retired the three-way text resize mode — a text box now has exactly one
//  behaviour, so nothing READS `resizeMode`. It is still asserted here because it
//  must keep DECODING and round-tripping: rows written by older builds carry the
//  key, and dropping it from the struct would silently discard it on the next save.
//

import Foundation
import Testing
@testable import AtelierCore

@Suite("ElementStyle rich-text fields + typed accessors")
struct ElementStyleTextTests {

    private let decoder = JSONDecoder()

    // MARK: - Round-trip

    @Test("all rich-text fields round-trip through JSON")
    func roundTripAllFields() throws {
        let style = ElementStyle(
            text: "Hello", fontSize: 24, textColor: "#112233",
            fillColor: "#445566", strokeColor: "#778899", strokeWidth: 3,
            fontFamily: "Helvetica Neue", fontWeight: TextWeight.semibold.rawValue,
            textAlign: TextAlign.center.rawValue, resizeMode: "autoHeight")
        let json = try #require(style.jsonString())
        let back = try #require(ElementStyle(jsonString: json))
        #expect(back == style)
        // Accessors read the tokens we set.
        #expect(back.weight == .semibold)
        #expect(back.align == .center)
        // Retired but preserved verbatim (062) — no reader, no data loss.
        #expect(back.resizeMode == "autoHeight")
    }

    @Test("jsonString / init?(jsonString:) is stable across a re-encode")
    func jsonStringStability() throws {
        let style = ElementStyle(
            text: "t", fontFamily: "Menlo", fontWeight: "bold",
            textAlign: "right", resizeMode: "autoWidth")
        let json1 = try #require(style.jsonString())
        let json2 = try #require(ElementStyle(jsonString: json1)?.jsonString())
        // Decoding then re-encoding yields an equal value (not necessarily equal bytes).
        #expect(ElementStyle(jsonString: json1) == ElementStyle(jsonString: json2))
    }

    // MARK: - Legacy decode (no new keys)

    @Test("legacy JSON (no new keys) decodes with four nils + default accessors")
    func legacyDecodeDefaults() throws {
        // A row written before Phase 2 — only the original six keys.
        let legacy = ##"{"text":"hi","fontSize":16,"textColor":"#000000"}"##
        let style = try #require(ElementStyle(jsonString: legacy))
        #expect(style.fontFamily == nil)
        #expect(style.fontWeight == nil)
        #expect(style.textAlign == nil)
        #expect(style.resizeMode == nil)
        // The accessors return today's exact defaults.
        #expect(style.weight == .regular)
        #expect(style.align == .left)
    }

    @Test("an entirely empty JSON object decodes to all-nil / defaults")
    func emptyObjectDefaults() throws {
        let style = try #require(ElementStyle(jsonString: "{}"))
        #expect(style.fontFamily == nil && style.fontWeight == nil)
        #expect(style.weight == .regular && style.align == .left)
    }

    // MARK: - Unknown / malformed tokens

    @Test("an unknown weight/align token degrades to the owned default")
    func unknownTokenDefaults() {
        let style = ElementStyle(
            fontWeight: "ultrablack", textAlign: "justify", resizeMode: "elastic")
        #expect(style.weight == .regular)
        #expect(style.align == .left)
        #expect(style.resizeMode == "elastic")   // unread, but never rewritten
    }

    @Test("an unknown token survives a JSON round-trip and still defaults")
    func unknownTokenRoundTrips() throws {
        let style = ElementStyle(fontWeight: "ultrablack")
        let json = try #require(style.jsonString())
        let back = try #require(ElementStyle(jsonString: json))
        #expect(back.fontWeight == "ultrablack") // storage is forgiving — preserved verbatim
        #expect(back.weight == .regular)          // but the accessor still defaults
    }

    // MARK: - Auto-width (063)

    @Test("textAutoWidth round-trips both ways", arguments: [true, false])
    func autoWidthRoundTrips(_ flag: Bool) throws {
        let style = ElementStyle(text: "x", textAutoWidth: flag)
        let back = try #require(ElementStyle(jsonString: #require(style.jsonString())))
        #expect(back.textAutoWidth == flag)
        #expect(back.hugsWidth == flag)
    }

    @Test("absent textAutoWidth reads as not hugging")
    func autoWidthAbsentDefaultsFalse() throws {
        #expect(ElementStyle(text: "x").hugsWidth == false)
        // A row written before 063 carries no key at all.
        let style = try #require(ElementStyle(jsonString: ##"{"text":"hi","fontSize":16}"##))
        #expect(style.textAutoWidth == nil)
        #expect(style.hugsWidth == false)
    }

    @Test("a legacy resizeMode of autoWidth does NOT make the box hug")
    func legacyResizeModeStaysInert() throws {
        // The one that matters: pre-062 `.autoWidth` rows are the runaway single-line
        // boxes 062 removed. Reviving them on load would re-flow existing boards, so
        // `hugsWidth` must read the new field and only the new field.
        let legacy = ##"{"text":"hi","resizeMode":"autoWidth"}"##
        let style = try #require(ElementStyle(jsonString: legacy))
        #expect(style.resizeMode == "autoWidth")   // still preserved verbatim…
        #expect(style.hugsWidth == false)          // …and still inert
    }

    @Test("the two fields are independent — a hugging box keeps its legacy token")
    func autoWidthAndResizeModeCoexist() throws {
        let style = ElementStyle(text: "x", textAutoWidth: true, resizeMode: "fixed")
        let back = try #require(ElementStyle(jsonString: #require(style.jsonString())))
        #expect(back.hugsWidth == true)
        #expect(back.resizeMode == "fixed")
    }

    // MARK: - Enum vocabulary

    @Test("the text enums carry the expected token sets")
    func enumTokenSets() {
        #expect(TextWeight.allCases.map(\.rawValue) == ["regular", "medium", "semibold", "bold"])
        #expect(TextAlign.allCases.map(\.rawValue) == ["left", "center", "right"])
    }
}
