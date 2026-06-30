import Foundation
import Testing
@testable import AtelierCore

// JSONValue must round-trip arbitrary JSON faithfully — it is the lossless
// carrier for Source.rawMetadata (003 §data-model). These tests drive it from
// both directions: build a value → encode → decode, and parse a raw JSON
// literal → re-encode → re-parse.
@Suite("JSONValue")
struct JSONValueTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try decoder.decode(JSONValue.self, from: data)
    }

    @Test("scalar cases round-trip", arguments: [
        JSONValue.null,
        .bool(true),
        .bool(false),
        .number(0),
        .number(-42.5),
        .number(1_000_000),
        .string(""),
        .string("hello"),
        .string("emoji 🎨 and unicode ✓"),
    ])
    func scalars(value: JSONValue) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test("nested object with every case round-trips")
    func nestedObject() throws {
        let value: JSONValue = .object([
            "tweetId": .string("1234567890"),
            "likes": .number(42),
            "isPinned": .bool(true),
            "deletedAt": .null,
            "media": .array([
                .object(["url": .string("https://x.com/a.jpg"), "w": .number(800)]),
                .object(["url": .string("https://x.com/b.jpg"), "w": .number(1200)]),
            ]),
            "board": .object([
                "name": .string("moodboard"),
                "tags": .array([.string("design"), .string("type")]),
            ]),
        ])
        #expect(try roundTrip(value) == value)
    }

    @Test("decoding a raw JSON literal yields the expected value and re-encodes")
    func decodeFromLiteral() throws {
        let json = """
        {
            "a": 1,
            "b": "two",
            "c": [true, false, null],
            "d": { "nested": [1.5, 2.5] }
        }
        """
        let data = Data(json.utf8)
        let value = try decoder.decode(JSONValue.self, from: data)

        let expected: JSONValue = .object([
            "a": .number(1),
            "b": .string("two"),
            "c": .array([.bool(true), .bool(false), .null]),
            "d": .object(["nested": .array([.number(1.5), .number(2.5)])]),
        ])
        #expect(value == expected)
        // And it survives a second trip.
        #expect(try roundTrip(value) == expected)
    }

    @Test("top-level array round-trips")
    func topLevelArray() throws {
        let value: JSONValue = .array([.number(1), .string("x"), .null, .bool(false)])
        #expect(try roundTrip(value) == value)
    }

    @Test("empty object and empty array round-trip")
    func empties() throws {
        #expect(try roundTrip(.object([:])) == .object([:]))
        #expect(try roundTrip(.array([])) == .array([]))
    }

    // null vs false must not collapse — the decoder probes decodeNil first.
    @Test("null and false are distinct")
    func nullNotFalse() throws {
        #expect(try roundTrip(.null) == .null)
        #expect(try roundTrip(.bool(false)) == .bool(false))
        #expect(JSONValue.null != JSONValue.bool(false))
    }
}
