// AtelierCore — AssetPayload (003 · multi-kind items)
//
// The structured substance of a MEDIA-LESS asset (`tweet` / `link` / `color`),
// stored as JSON TEXT in the nullable `asset.payload` column — provenance stays
// in `source`, content lives here (003 · O1, "payload separate from
// raw_metadata"). Byte-backed kinds (`image` / `video`) leave `payload` nil.
//
// Modelled as an all-optional struct (the ``ElementStyle`` idiom) rather than a
// discriminated enum: ``Asset/kind`` IS the discriminator, so `payload` only
// carries the fields that kind needs, and adding `link` / `tweet` sub-payloads
// later is a purely additive optional field — no custom Codable, no breakage.
//
// Plain value types: no persistence here; the JSON (de)serialization mirrors
// ``ElementStyle`` (`jsonString()` / `init?(jsonString:)`).

import Foundation

/// A `color` asset's substance (003 · C1). v1 is a single canonical hex; a
/// future palette is an additive `swatches: [String]?` field, not a reshape.
public struct ColorPayload: Codable, Sendable, Equatable, Hashable {
    /// Canonical `#rrggbb`, lowercased (see ``ColorPayload/canonicalHex(_:)``) —
    /// also the dedup key, so `#FFF`, `#ffffff`, and `#FFFFFF` are one color.
    public var hex: String

    public init(hex: String) {
        self.hex = hex
    }

    /// Normalize a user-typed color to canonical `#rrggbb` lowercase, or `nil`
    /// if it isn't a valid 3- or 6-digit hex color. Accepts an optional leading
    /// `#`, expands shorthand (`#f0a` → `#ff00aa`), and lowercases — so equal
    /// colors written differently collapse to one dedup key.
    public static func canonicalHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        switch s.count {
        case 3:
            // Expand shorthand: each nibble is doubled (#f0a → ff00aa).
            s = s.map { "\($0)\($0)" }.joined()
        case 6:
            break
        default:
            return nil
        }
        return "#" + s
    }
}

/// The media-less content carrier for an ``Asset`` (003 · O1). Exactly the
/// sub-payload for the asset's ``AssetKind`` is populated; the rest are nil.
/// Stored as compact JSON TEXT in `asset.payload`.
public struct AssetPayload: Codable, Sendable, Equatable, Hashable {
    /// Set iff `kind == .color`.
    public var color: ColorPayload?

    // Future kinds (C2/C3) add their sub-payloads here — additive:
    //   public var link: LinkPayload?
    //   public var tweet: TweetPayload?

    public init(color: ColorPayload? = nil) {
        self.color = color
    }

    /// Encode to a compact JSON string for the `payload` TEXT column, or `nil`
    /// if encoding fails (which it cannot for a well-formed value).
    public func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from the `payload` TEXT column; `nil` for a nil / malformed string.
    public init?(jsonString: String?) {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AssetPayload.self, from: data)
        else { return nil }
        self = decoded
    }
}
