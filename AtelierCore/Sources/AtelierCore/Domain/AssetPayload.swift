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

/// A `link` asset's substance (003 · C2). The canonical URL is the identity (and
/// dedup key); `title` / `description` are best-effort metadata — nil until a
/// page resolver (001) enriches them, so a bare paste still saves a usable link.
public struct LinkPayload: Codable, Sendable, Equatable, Hashable {
    /// Canonical URL (see ``LinkPayload/canonicalURL(_:)``) — also the dedup key.
    public var url: String
    /// Page title (og:title / `<title>`); nil until resolved.
    public var title: String?
    /// Short description (og:description / meta description); nil until resolved.
    public var description: String?

    public init(url: String, title: String? = nil, description: String? = nil) {
        self.url = url
        self.title = title
        self.description = description
    }

    /// Normalize a user-typed URL to a canonical form for dedup, or `nil` if it
    /// isn't a usable http(s) URL. **Moderate** canonicalization (003 · open Q2):
    /// prepend `https://` when scheme-less, lowercase scheme + host, drop the
    /// fragment and default port, strip a trailing slash, and remove common
    /// tracking params (`utm_*`, `fbclid`, `gclid`, …). Deliberately does NOT
    /// touch other query params or the path case — over-stripping would merge
    /// genuinely-distinct pages.
    public static func canonicalURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        comps.scheme = scheme
        comps.host = host.lowercased()
        comps.fragment = nil
        if (scheme == "http" && comps.port == 80) || (scheme == "https" && comps.port == 443) {
            comps.port = nil
        }
        if let items = comps.queryItems {
            let tracking: Set<String> = [
                "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                "fbclid", "gclid", "mc_cid", "mc_eid", "ref_src",
            ]
            let kept = items.filter { !tracking.contains($0.name.lowercased()) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        // Normalize a trailing slash — incl. the root "/", so `example.com` and
        // `example.com/` share one dedup key.
        if comps.path == "/" {
            comps.path = ""
        } else if comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        return comps.string
    }
}

/// The media-less content carrier for an ``Asset`` (003 · O1). Exactly the
/// sub-payload for the asset's ``AssetKind`` is populated; the rest are nil.
/// Stored as compact JSON TEXT in `asset.payload`.
public struct AssetPayload: Codable, Sendable, Equatable, Hashable {
    /// Set iff `kind == .color`.
    public var color: ColorPayload?
    /// Set iff `kind == .link` (003 · C2).
    public var link: LinkPayload?

    // Future kinds (C3) add their sub-payloads here — additive:
    //   public var tweet: TweetPayload?

    public init(color: ColorPayload? = nil, link: LinkPayload? = nil) {
        self.color = color
        self.link = link
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
