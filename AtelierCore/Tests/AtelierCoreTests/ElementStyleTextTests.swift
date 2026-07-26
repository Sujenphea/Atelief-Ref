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
            textAlign: TextAlign.center.rawValue, resizeMode: TextResize.autoHeight.rawValue)
        let json = try #require(style.jsonString())
        let back = try #require(ElementStyle(jsonString: json))
        #expect(back == style)
        // Accessors read the tokens we set.
        #expect(back.weight == .semibold)
        #expect(back.align == .center)
        #expect(back.resize == .autoHeight)
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
        #expect(style.resize == .fixed)
    }

    @Test("an entirely empty JSON object decodes to all-nil / defaults")
    func emptyObjectDefaults() throws {
        let style = try #require(ElementStyle(jsonString: "{}"))
        #expect(style.fontFamily == nil && style.fontWeight == nil)
        #expect(style.weight == .regular && style.align == .left && style.resize == .fixed)
    }

    // MARK: - Unknown / malformed tokens

    @Test("an unknown weight/align/resize token degrades to the owned default")
    func unknownTokenDefaults() {
        let style = ElementStyle(
            fontWeight: "ultrablack", textAlign: "justify", resizeMode: "elastic")
        #expect(style.weight == .regular)
        #expect(style.align == .left)
        #expect(style.resize == .fixed)
    }

    @Test("an unknown token survives a JSON round-trip and still defaults")
    func unknownTokenRoundTrips() throws {
        let style = ElementStyle(fontWeight: "ultrablack")
        let json = try #require(style.jsonString())
        let back = try #require(ElementStyle(jsonString: json))
        #expect(back.fontWeight == "ultrablack") // storage is forgiving — preserved verbatim
        #expect(back.weight == .regular)          // but the accessor still defaults
    }

    // MARK: - Enum vocabulary

    @Test("the text enums carry the expected token sets")
    func enumTokenSets() {
        #expect(TextWeight.allCases.map(\.rawValue) == ["regular", "medium", "semibold", "bold"])
        #expect(TextAlign.allCases.map(\.rawValue) == ["left", "center", "right"])
        #expect(TextResize.allCases.map(\.rawValue) == ["fixed", "autoWidth", "autoHeight"])
    }
}
