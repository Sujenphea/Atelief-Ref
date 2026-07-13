// AtelierCore — AssetContent / AssetPayload tests (003 · multi-kind items · C0)
//
// The render seam is pure and total, so it's unit-tested exhaustively here (no
// database): every `(kind, blobHash, payload)` combination maps to the right
// ``AssetContent`` — including the `.unknown` fallbacks where the backing data
// contradicts the kind — plus color hex canonicalization + payload round-trip.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Domain: AssetContent render seam (003 · O1)")
struct AssetContentTests {

    private func asset(
        kind: AssetKind, blobHash: String? = nil, payload: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash, mimeType: nil,
            width: nil, height: nil, fileSize: nil, downloadState: .downloaded,
            createdAt: Date(), sourceId: UUID(), payload: payload)
    }

    @Test("image with a blob → .image; without → .unknown")
    func imageMapping() {
        #expect(asset(kind: .image, blobHash: "abc").content == .image(blobHash: "abc"))
        #expect(asset(kind: .image, blobHash: nil).content == .unknown)
    }

    @Test("video with a blob → .video; without → .unknown")
    func videoMapping() {
        #expect(asset(kind: .video, blobHash: "def").content == .video(blobHash: "def"))
        #expect(asset(kind: .video, blobHash: nil).content == .unknown)
    }

    @Test("color with a hex payload → .color; missing/malformed payload → .unknown")
    func colorMapping() {
        let payload = AssetPayload(color: ColorPayload(hex: "#ff0000")).jsonString()
        #expect(asset(kind: .color, payload: payload).content == .color(hex: "#ff0000"))
        // No payload at all.
        #expect(asset(kind: .color, payload: nil).content == .unknown)
        // Payload present but no color sub-payload.
        #expect(asset(kind: .color, payload: "{}").content == .unknown)
        // Garbage JSON.
        #expect(asset(kind: .color, payload: "not json").content == .unknown)
    }

    @Test("link with a URL payload → .link (carrying the asset's blob as og:image)")
    func linkMapping() {
        let payload = AssetPayload(link: LinkPayload(
            url: "https://example.com/x", title: "Ex", description: "d")).jsonString()
        // Bare link: no blob → imageBlobHash nil.
        let bare = asset(kind: .link, payload: payload).content
        #expect(bare == .link(LinkContent(
            url: "https://example.com/x", title: "Ex", description: "d", imageBlobHash: nil)))
        // Resolved link: the asset's own blob is the og:image.
        let resolved = asset(kind: .link, blobHash: "ogimg", payload: payload).content
        #expect(resolved == .link(LinkContent(
            url: "https://example.com/x", title: "Ex", description: "d", imageBlobHash: "ogimg")))
        // No payload → unknown.
        #expect(asset(kind: .link, payload: nil).content == .unknown)
        #expect(asset(kind: .link, payload: "{}").content == .unknown)
    }

    @Test("tweet with a payload → .tweet (carrying the asset's blob as the card image)")
    func tweetMapping() {
        let payload = AssetPayload(tweet: TweetPayload(
            tweetID: "123", text: "hi", authorHandle: "ava", authorName: "Ava",
            media: [TweetMedia(url: "https://pbs.example/a.jpg", width: 4, height: 3)])).jsonString()
        // Bare tweet: no blob → cardImageBlobHash nil.
        #expect(asset(kind: .tweet, payload: payload).content == .tweet(TweetContent(
            tweetID: "123", text: "hi", authorHandle: "ava", authorName: "Ava",
            media: [TweetMedia(url: "https://pbs.example/a.jpg", width: 4, height: 3)],
            cardImageBlobHash: nil)))
        // Captured card image: the asset's own blob is the card.
        #expect(asset(kind: .tweet, blobHash: "card", payload: payload).content == .tweet(TweetContent(
            tweetID: "123", text: "hi", authorHandle: "ava", authorName: "Ava",
            media: [TweetMedia(url: "https://pbs.example/a.jpg", width: 4, height: 3)],
            cardImageBlobHash: "card")))
        // No / malformed payload → unknown.
        #expect(asset(kind: .tweet, payload: nil).content == .unknown)
        #expect(asset(kind: .tweet, payload: "{}").content == .unknown)
    }

    @Test("payloadValue decodes the color; nil for a byte-backed asset")
    func payloadValueDecodes() {
        let payload = AssetPayload(color: ColorPayload(hex: "#00ff00")).jsonString()
        #expect(asset(kind: .color, payload: payload).payloadValue?.color?.hex == "#00ff00")
        #expect(asset(kind: .image, blobHash: "abc").payloadValue == nil)
    }
}

@Suite("Domain: ColorPayload canonicalization (003 · C1)")
struct ColorPayloadTests {

    @Test("canonicalHex normalizes case, '#', and 3-digit shorthand", arguments: [
        ("#FF0000", "#ff0000"),
        ("ff0000", "#ff0000"),
        ("#f00", "#ff0000"),
        ("F00", "#ff0000"),
        ("  #AABBCC  ", "#aabbcc"),
        ("#0a0", "#00aa00"),
    ])
    func canonicalizes(input: String, expected: String) {
        #expect(ColorPayload.canonicalHex(input) == expected)
    }

    @Test("canonicalHex rejects non-hex / wrong-length input", arguments: [
        "", "#", "#12", "#12345", "#1234567", "#gggggg", "red", "#ff00zz",
    ])
    func rejects(input: String) {
        #expect(ColorPayload.canonicalHex(input) == nil)
    }

    @Test("AssetPayload round-trips through its JSON string")
    func payloadRoundTrips() {
        let payload = AssetPayload(color: ColorPayload(hex: "#123abc"))
        let json = payload.jsonString()
        #expect(AssetPayload(jsonString: json) == payload)
        // A nil / malformed string decodes to nil.
        #expect(AssetPayload(jsonString: nil) == nil)
        #expect(AssetPayload(jsonString: "{{{") == nil)
    }

    @Test("a link AssetPayload round-trips")
    func linkPayloadRoundTrips() {
        let payload = AssetPayload(link: LinkPayload(
            url: "https://a.test/p", title: "T", description: "D"))
        #expect(AssetPayload(jsonString: payload.jsonString()) == payload)
    }

    @Test("a tweet AssetPayload round-trips (incl. media)")
    func tweetPayloadRoundTrips() {
        let payload = AssetPayload(tweet: TweetPayload(
            tweetID: "42", text: "hello", authorHandle: "ava", authorName: "Ava",
            media: [TweetMedia(url: "https://m.test/1.jpg", width: 8, height: 6)]))
        #expect(AssetPayload(jsonString: payload.jsonString()) == payload)
    }
}

@Suite("Domain: TweetPayload canonicalization (003 · C3)")
struct TweetPayloadTests {

    @Test("canonicalTweetID extracts the numeric id from a bare id or status URL", arguments: [
        ("123456", "123456"),
        ("  789  ", "789"),
        ("https://x.com/ava/status/123456", "123456"),
        ("https://twitter.com/ava/statuses/123456", "123456"),
        ("x.com/ava/status/123456?s=20", "123456"),
        ("https://x.com/ava/status/123456/photo/1", "123456"),
    ])
    func canonicalizes(input: String, expected: String) {
        #expect(TweetPayload.canonicalTweetID(input) == expected)
    }

    @Test("canonicalTweetID rejects input with no usable id", arguments: [
        "", "   ", "https://x.com/ava", "not a url", "https://x.com/ava/status/",
    ])
    func rejects(input: String) {
        #expect(TweetPayload.canonicalTweetID(input) == nil)
    }

    @Test("the same tweet captured via x.com / twitter.com collapses to one id")
    func equalTweetsCollapse() {
        let a = TweetPayload.canonicalTweetID("https://x.com/ava/status/999")
        let b = TweetPayload.canonicalTweetID("https://twitter.com/ava/statuses/999?s=20")
        let c = TweetPayload.canonicalTweetID("999")
        #expect(a == b)
        #expect(b == c)
    }

    @Test("canonicalTweetURL is a deterministic permalink for the id")
    func canonicalURLFromID() {
        #expect(TweetPayload.canonicalTweetURL(id: "999") == "https://x.com/i/status/999")
    }
}

@Suite("Domain: LinkPayload canonicalization (003 · C2)")
struct LinkPayloadTests {

    @Test("canonicalURL normalizes scheme, host case, fragment, default port, trailing slash", arguments: [
        ("example.com", "https://example.com"),
        ("HTTP://Example.COM/Path/", "http://example.com/Path"),
        ("https://example.com:443/x", "https://example.com/x"),
        ("http://example.com:80/x", "http://example.com/x"),
        ("https://example.com/a#section", "https://example.com/a"),
        ("https://example.com/", "https://example.com"),
    ])
    func canonicalizes(input: String, expected: String) {
        #expect(LinkPayload.canonicalURL(input) == expected)
    }

    @Test("canonicalURL strips tracking params but keeps meaningful ones")
    func stripsTracking() {
        #expect(LinkPayload.canonicalURL("https://x.test/p?utm_source=tw&utm_medium=x")
                == "https://x.test/p")
        #expect(LinkPayload.canonicalURL("https://x.test/p?id=7&fbclid=abc")
                == "https://x.test/p?id=7")
    }

    @Test("canonicalURL rejects non-http(s) and junk", arguments: [
        "", "   ", "ftp://x.test/a", "file:///etc/passwd", "https://", "not a url with spaces",
    ])
    func rejects(input: String) {
        #expect(LinkPayload.canonicalURL(input) == nil)
    }

    @Test("equal pages written differently canonicalize identically (dedup key)")
    func equalPagesCollapse() {
        let a = LinkPayload.canonicalURL("example.com/post/")
        let b = LinkPayload.canonicalURL("https://example.com/post")
        let c = LinkPayload.canonicalURL("https://EXAMPLE.com/post?utm_campaign=z#top")
        #expect(a == b)
        #expect(b == c)
    }
}
