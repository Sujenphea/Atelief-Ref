// AtelierServer — pure decode tests (build-order #6, decision T3).
//
// A network boundary receives garbage by definition, so the DTO→SourceDraft
// decode is asserted across the whole malformed-input matrix, plus the happy
// path's full field mapping. No socket, no pipeline.

import Foundation
import Testing

import AtelierCore
@testable import AtelierServer

@Suite("CaptureDecoder")
struct CaptureDecoderTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let collectionID = UUID()

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
        let header = ServerFixtures.provenanceHeader(collectionId: collection)
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
        let header = ServerFixtures.provenanceHeader(platform: "myspace")
        #expect(throws: CaptureDecodeError.unknownPlatform("myspace")) {
            try CaptureDecoder.decodeVideoHeader(header, now: Self.now)
        }
    }

    @Test("absent optional fields → nil author/title, rawMetadata defaults to {}")
    func minimalMapping() throws {
        let request = CaptureRequest(
            image: ServerFixtures.pngBase64(),
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
        ("instagram", .instagram), ("cosmos", .cosmos), ("web", .web),
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
}
