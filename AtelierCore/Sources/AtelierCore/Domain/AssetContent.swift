// AtelierCore — AssetContent (003 · multi-kind items · the render seam)
//
// The ONE exhaustive projection of "what an asset actually is to render",
// computed from `(kind, blobHash, payload)`. Views switch on this ONCE instead
// of nil-checking bytes at every call site — the seam that keeps the now-nullable
// byte columns (003 · O1) from leaking `if let blobHash` branches across the app.
//
// A media-less kind whose payload is missing / malformed resolves to `.unknown`
// (honest: the data disagrees with the kind), so a view always has a total,
// non-crashing branch.

import Foundation

/// What an ``Asset`` renders as (003 · O1). Exhaustive over the current kinds;
/// `.unknown` is the total fallback for a kind whose backing data is absent or
/// not yet modelled (`link` / `tweet` land in C2 / C3).
public enum AssetContent: Sendable, Equatable, Hashable {
    /// A byte-backed still image; carries its non-nil blob hash.
    case image(blobHash: String)
    /// A byte-backed video; carries its non-nil blob hash.
    case video(blobHash: String)
    /// A media-less color swatch; carries its canonical `#rrggbb` hex.
    case color(hex: String)
    /// The kind's backing data is missing/malformed, or the kind isn't rendered
    /// yet — a view shows a neutral placeholder rather than crashing.
    case unknown
}

extension Asset {
    /// The decoded ``AssetPayload``, or `nil` for a byte-backed asset / malformed
    /// JSON. Cheap enough to recompute; not cached (assets are value types).
    public var payloadValue: AssetPayload? { AssetPayload(jsonString: payload) }

    /// The render projection (003 · O1) — the single switch every view uses.
    /// A byte kind with a nil hash, or a media-less kind with no payload, is
    /// `.unknown` (the data contradicts the kind).
    public var content: AssetContent {
        switch kind {
        case .image:
            blobHash.map(AssetContent.image) ?? .unknown
        case .video:
            blobHash.map(AssetContent.video) ?? .unknown
        case .color:
            payloadValue?.color.map { AssetContent.color(hex: $0.hex) } ?? .unknown
        case .link, .tweet:
            // Modelled in C2 / C3; until then they have no render branch.
            .unknown
        }
    }
}
