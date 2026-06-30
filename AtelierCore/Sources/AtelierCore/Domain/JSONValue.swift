// AtelierCore — JSONValue
//
// The explicit, lossless representation of `Source.raw_metadata` (003
// §data-model): platform-specific extras preserved verbatim. Each platform
// exposes different fields (Pinterest board, tweet id, IG shortcode, Cosmos
// cluster); we keep the raw blob so we never lose data we didn't model yet.
//
// Modelled as an explicit recursive enum rather than `Any`/AnyCodable —
// explicit over clever. It round-trips arbitrary JSON faithfully and is itself
// `Codable`, so a `Source` encodes as one nested document.

import Foundation

/// A single JSON value — the lossless carrier for a ``Source``'s
/// `rawMetadata`. Recursive: arrays and objects nest arbitrarily.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Codable

    /// Decodes any JSON value. Order matters: `null` is probed first (a JSON
    /// `null` would otherwise fail the typed `decode` calls), then the scalar
    /// types, then the containers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    /// Encodes back to the JSON shape it was decoded from, faithfully.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
