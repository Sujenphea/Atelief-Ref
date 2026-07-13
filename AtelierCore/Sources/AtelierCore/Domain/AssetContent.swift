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
    /// A media-less saved link (003 · C2); carries its URL + best-effort
    /// metadata, plus an optional og:image blob hash (nil until resolved).
    case link(LinkContent)
    /// A media-less saved tweet (003 · C3); carries its text / author / media
    /// references, plus an optional card-image blob hash (nil until captured).
    case tweet(TweetContent)
    /// The kind's backing data is missing/malformed, or the kind isn't rendered
    /// yet — a view shows a neutral placeholder rather than crashing.
    case unknown
}

/// The render-ready projection of a `link` asset (003 · C2): the payload's URL /
/// title / description plus the asset's own `blobHash` as the optional og:image
/// thumbnail (present once a resolver stores one; nil for a bare paste).
public struct LinkContent: Sendable, Equatable, Hashable {
    public let url: String
    public let title: String?
    public let description: String?
    /// The og:image blob hash (the asset's own bytes), or nil when the link has
    /// no thumbnail — the grid then draws a link card instead.
    public let imageBlobHash: String?

    public init(url: String, title: String?, description: String?, imageBlobHash: String?) {
        self.url = url
        self.title = title
        self.description = description
        self.imageBlobHash = imageBlobHash
    }
}

/// The render-ready projection of a `tweet` asset (003 · C3): the payload's text /
/// author / media references plus the asset's own `blobHash` as the optional card
/// image (present once captured; nil for a bare tweet → the grid draws a text
/// card). Media are URL references (the C3 model), not first-class assets.
public struct TweetContent: Sendable, Equatable, Hashable {
    public let tweetID: String
    public let text: String?
    public let authorHandle: String?
    public let authorName: String?
    /// The tweet's image / video URLs (references, not blobs — no local bytes).
    public let media: [TweetMedia]
    /// The card-image blob hash (the asset's own bytes), or nil when the tweet
    /// has none — the grid then draws a text card instead.
    public let cardImageBlobHash: String?

    public init(
        tweetID: String, text: String?, authorHandle: String?, authorName: String?,
        media: [TweetMedia], cardImageBlobHash: String?
    ) {
        self.tweetID = tweetID
        self.text = text
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.media = media
        self.cardImageBlobHash = cardImageBlobHash
    }
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
        case .link:
            payloadValue?.link.map {
                AssetContent.link(LinkContent(
                    url: $0.url, title: $0.title, description: $0.description,
                    imageBlobHash: blobHash))
            } ?? .unknown
        case .tweet:
            payloadValue?.tweet.map {
                AssetContent.tweet(TweetContent(
                    tweetID: $0.tweetID, text: $0.text,
                    authorHandle: $0.authorHandle, authorName: $0.authorName,
                    media: $0.media, cardImageBlobHash: blobHash))
            } ?? .unknown
        }
    }
}
