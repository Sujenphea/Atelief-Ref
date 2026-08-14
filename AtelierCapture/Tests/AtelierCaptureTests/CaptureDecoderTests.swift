// AtelierCapture — pure decode tests (build-order #6, decision T3; moved here
// with the code they cover by 092 · S0).
//
// A capture boundary receives garbage by definition, so the DTO→SourceDraft
// decode is asserted across the whole malformed-input matrix, plus the happy
// path's full field mapping. No socket, no pipeline — and now no server either:
// the suite ran unchanged on both sides of the extraction, which is what proved
// the move behaviour-preserving.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore

@Suite("CaptureDecoder")
struct CaptureDecoderTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let collectionID = UUID()

    // MARK: - Cross-language wire contract (decision 1A)

    /// The shared fixture the extension's `endpoint.test.js` also asserts against.
    /// The extension proves it PRODUCES these shapes; this proves the server
    /// DECODES them into the matching `SourceDraft` — a field rename on either side
    /// breaks a test. One file is the single source of truth for the wire shape.
    struct Contract: Decodable {
        struct Expected: Decodable {
            let captureRequest: CaptureRequest
            let contentCaptureRequest: CaptureRequest
            let videoHeader: VideoCaptureHeader
        }
        let expected: Expected
    }

    /// Load the fixture relative to THIS source file (repo root is 4 levels up),
    /// so the JS and Swift suites read the exact same bytes.
    static func loadContract() throws -> Contract {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent("extension/test/fixtures/capture-contract.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    @Test("contract fixture: the canonical CaptureRequest decodes to the expected SourceDraft")
    func contractImage() throws {
        let fixture = try Self.loadContract()
        let body = try JSONEncoder().encode(fixture.expected.captureRequest)
        let decoded = try CaptureDecoder.decode(body: body, now: Self.now)

        #expect(!decoded.imageData.isEmpty)
        let p = decoded.provenance
        #expect(p.platform == .twitter)
        #expect(p.originalURL == "https://x.com/designer/status/42")
        #expect(p.authorHandle == "@designer")
        #expect(p.authorName == "A Designer")
        #expect(p.title == "a reference")
        #expect(p.rawMetadata == .object(["tweetId": .string("42")]))
    }

    @Test("contract fixture: the canonical tweet content-capture routes to .contentWithImage")
    func contractContent() throws {
        let fixture = try Self.loadContract()
        let body = try JSONEncoder().encode(fixture.expected.contentCaptureRequest)
        guard case .contentWithImage(let c) = try CaptureDecoder.decodeInput(
            body: body, now: Self.now) else {
            Issue.record("expected .contentWithImage"); return
        }
        #expect(c.draft.kind == .tweet)
        #expect(!c.imageData.isEmpty)
        let tweet = try #require(c.draft.payload.tweet)
        #expect(tweet.tweetID == "42")
        #expect(tweet.text == "a reference")
        #expect(tweet.authorHandle == "@designer")
        #expect(tweet.media == [TweetMedia(url: "https://pbs.twimg.example/a.jpg")])
        #expect(c.provenance.platform == .twitter)
        #expect(c.provenance.originalURL == "https://x.com/designer/status/42")
    }

    @Test("contract fixture: the canonical video header decodes to the expected SourceDraft")
    func contractVideo() throws {
        let fixture = try Self.loadContract()
        let headerB64 = try JSONEncoder().encode(fixture.expected.videoHeader).base64EncodedString()
        let decoded = try CaptureDecoder.decodeVideoHeader(headerB64, now: Self.now)

        #expect(decoded.provenance.platform == .twitter)
        #expect(decoded.provenance.authorHandle == "@designer")
        #expect(decoded.provenance.title == "a reference")
        #expect(decoded.provenance.rawMetadata == .object(["tweetId": .string("42")]))
    }

    @Test("valid request → SourceDraft with every provenance field mapped")
    func validFullMapping() throws {
        let request = CaptureRequest.sample(collectionId: Self.collectionID)
        let decoded = try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)

        #expect(!decoded.imageData.isEmpty)
        #expect(decoded.collectionID == Self.collectionID)
        let p = decoded.provenance
        #expect(p.platform == .twitter)
        #expect(p.originalURL == "https://x.com/designer/status/42")
        #expect(p.authorHandle == "@designer")
        #expect(p.authorName == "A Designer")
        #expect(p.title == "a reference")
        #expect(p.rawMetadata == .object(["likes": .number(9)]))
        // The capture time is server-owned, not client-supplied.
        #expect(p.capturedAt == Self.now)
    }

    // MARK: - Video provenance header (base64 JSON, no body)

    @Test("valid provenance header → SourceDraft + collectionId, server-owned time")
    func videoHeaderValid() throws {
        let collection = UUID()
        let header = CaptureFixtures.provenanceHeader(collectionId: collection)
        let decoded = try CaptureDecoder.decodeVideoHeader(header, now: Self.now)

        #expect(decoded.collectionID == collection)
        #expect(decoded.provenance.platform == .twitter)
        #expect(decoded.provenance.authorHandle == "@designer")
        #expect(decoded.provenance.rawMetadata == .object(["tweetId": .string("42")]))
        #expect(decoded.provenance.capturedAt == Self.now)
    }

    @Test("absent provenance header → missingProvenanceHeader")
    func videoHeaderMissing() {
        #expect(throws: CaptureDecodeError.missingProvenanceHeader) {
            try CaptureDecoder.decodeVideoHeader(nil, now: Self.now)
        }
        #expect(throws: CaptureDecodeError.missingProvenanceHeader) {
            try CaptureDecoder.decodeVideoHeader("", now: Self.now)
        }
    }

    @Test("non-base64 header → malformedProvenanceHeader")
    func videoHeaderNotBase64() {
        #expect(throws: CaptureDecodeError.malformedProvenanceHeader) {
            try CaptureDecoder.decodeVideoHeader("!!!not base64!!!", now: Self.now)
        }
    }

    @Test("base64 of non-VideoCaptureHeader JSON → malformedProvenanceHeader")
    func videoHeaderWrongJSON() {
        let junk = Data(#"{"nope":true}"#.utf8).base64EncodedString()
        #expect(throws: CaptureDecodeError.malformedProvenanceHeader) {
            try CaptureDecoder.decodeVideoHeader(junk, now: Self.now)
        }
    }

    @Test("unknown platform in header → unknownPlatform")
    func videoHeaderUnknownPlatform() {
        let header = CaptureFixtures.provenanceHeader(platform: "myspace")
        #expect(throws: CaptureDecodeError.unknownPlatform("myspace")) {
            try CaptureDecoder.decodeVideoHeader(header, now: Self.now)
        }
    }

    @Test("absent optional fields → nil author/title, rawMetadata defaults to {}")
    func minimalMapping() throws {
        let request = CaptureRequest(
            image: CaptureFixtures.pngBase64(),
            provenance: ProvenanceDTO(platform: "pinterest"),
            collectionId: nil)
        let decoded = try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)

        #expect(decoded.collectionID == nil)
        #expect(decoded.provenance.platform == .pinterest)
        #expect(decoded.provenance.originalURL == nil)
        #expect(decoded.provenance.authorHandle == nil)
        #expect(decoded.provenance.title == nil)
        #expect(decoded.provenance.rawMetadata == .object([:]))
    }

    @Test("every accepted platform string maps to its Platform case", arguments: [
        ("twitter", Platform.twitter), ("pinterest", .pinterest),
        ("instagram", .instagram), ("cosmos", .cosmos), ("rednote", .rednote),
        ("web", .web), ("clipboard", .clipboard),
    ])
    func platformMapping(raw: String, expected: Platform) throws {
        let request = CaptureRequest.sample(platform: raw)
        let decoded = try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)
        #expect(decoded.provenance.platform == expected)
    }

    @Test("malformed JSON → .malformedJSON")
    func malformedJSON() {
        let body = Data("{ not json ".utf8)
        #expect(throws: CaptureDecodeError.malformedJSON) {
            try CaptureDecoder.decode(body: body, now: Self.now)
        }
    }

    @Test("valid JSON but wrong shape → .malformedJSON")
    func wrongShape() {
        let body = Data(#"{"foo": "bar"}"#.utf8)
        #expect(throws: CaptureDecodeError.malformedJSON) {
            try CaptureDecoder.decode(body: body, now: Self.now)
        }
    }

    @Test("non-base64 image field → .invalidBase64")
    func invalidBase64() {
        let request = CaptureRequest(
            image: "!!! not base64 !!!",
            provenance: ProvenanceDTO(platform: "web"))
        #expect(throws: CaptureDecodeError.invalidBase64) {
            try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)
        }
    }

    @Test("empty (but valid base64) image → .emptyImage")
    func emptyImage() {
        let request = CaptureRequest(
            image: "", provenance: ProvenanceDTO(platform: "web"))
        #expect(throws: CaptureDecodeError.emptyImage) {
            try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)
        }
    }

    @Test("unknown platform string → .unknownPlatform(value)")
    func unknownPlatform() {
        let request = CaptureRequest.sample(platform: "myspace")
        #expect(throws: CaptureDecodeError.unknownPlatform("myspace")) {
            try CaptureDecoder.decode(body: request.jsonData(), now: Self.now)
        }
    }

    @Test("local platform aliases decode via their raw values")
    func localPlatformRawValues() throws {
        for (raw, expected) in [
            ("local_paste", Platform.localPaste), ("local_drag", .localDrag),
        ] {
            let request = CaptureRequest.sample(platform: raw)
            let decoded = try CaptureDecoder.decode(
                body: request.jsonData(), now: Self.now)
            #expect(decoded.provenance.platform == expected)
        }
    }

    // MARK: - Content routing (003 · C3)

    @Test("decodeInput routes a media-less kind → .content carrying the built draft")
    func decodesContent() throws {
        let request = CaptureRequest(
            provenance: ProvenanceDTO(platform: "web", originalURL: "https://ex.com/p"),
            collectionId: Self.collectionID,
            kind: "link",
            payload: AssetPayload(link: LinkPayload(url: "https://ex.com/p", title: "P")))
        guard case .content(let c) = try CaptureDecoder.decodeInput(
            body: request.jsonData(), now: Self.now) else {
            Issue.record("expected .content"); return
        }
        #expect(c.draft.kind == .link)
        #expect(c.draft.payload.link?.url == "https://ex.com/p")
        #expect(c.provenance.platform == .web)
        #expect(c.collectionID == Self.collectionID)
    }

    @Test("decodeInput routes an absent or byte kind → .image")
    func decodesImageByDefault() throws {
        // No `kind` → image.
        guard case .image = try CaptureDecoder.decodeInput(
            body: CaptureRequest.sample().jsonData(), now: Self.now) else {
            Issue.record("expected .image for an absent kind"); return
        }
        // An explicit byte kind still takes the image path (it needs its bytes).
        let explicit = CaptureRequest(
            image: CaptureFixtures.pngBase64(),
            provenance: ProvenanceDTO(platform: "twitter", originalURL: "https://x.com/a/status/1"),
            kind: "image")
        guard case .image = try CaptureDecoder.decodeInput(
            body: explicit.jsonData(), now: Self.now) else {
            Issue.record("expected .image for a byte kind"); return
        }
    }

    @Test("decodeInput routes a media-less kind WITH an image → .contentWithImage")
    func decodesContentWithImage() throws {
        let request = CaptureRequest(
            image: CaptureFixtures.pngBase64(),
            provenance: ProvenanceDTO(platform: "twitter", originalURL: "https://x.com/a/status/9"),
            collectionId: Self.collectionID,
            kind: "tweet",
            payload: AssetPayload(tweet: TweetPayload(tweetID: "9", text: "hi")))
        guard case .contentWithImage(let c) = try CaptureDecoder.decodeInput(
            body: request.jsonData(), now: Self.now) else {
            Issue.record("expected .contentWithImage"); return
        }
        #expect(c.draft.kind == .tweet)
        #expect(c.draft.payload.tweet?.tweetID == "9")
        #expect(!c.imageData.isEmpty)
        #expect(c.collectionID == Self.collectionID)
    }

    @Test("decodeInput rejects a media-less kind whose image is malformed base64 (.invalidBase64)")
    func contentWithImageBadBase64() {
        let request = CaptureRequest(
            image: "!!! not base64 !!!",
            provenance: ProvenanceDTO(platform: "twitter", originalURL: "https://x.com/a/status/9"),
            kind: "tweet",
            payload: AssetPayload(tweet: TweetPayload(tweetID: "9", text: "hi")))
        #expect(throws: CaptureDecodeError.invalidBase64) {
            try CaptureDecoder.decodeInput(body: request.jsonData(), now: Self.now)
        }
    }

    @Test("decodeInput rejects an unknown kind (.unknownKind)")
    func unknownKind() {
        let request = CaptureRequest(
            provenance: ProvenanceDTO(platform: "web", originalURL: "https://e.com"),
            kind: "sticker", payload: AssetPayload())
        #expect(throws: CaptureDecodeError.unknownKind("sticker")) {
            try CaptureDecoder.decodeInput(body: request.jsonData(), now: Self.now)
        }
    }

    @Test("decodeInput rejects a media-less kind with no payload (.missingContentPayload)")
    func missingContentPayload() {
        let request = CaptureRequest(
            provenance: ProvenanceDTO(platform: "local_paste"), kind: "color")
        #expect(throws: CaptureDecodeError.missingContentPayload) {
            try CaptureDecoder.decodeInput(body: request.jsonData(), now: Self.now)
        }
    }
}
