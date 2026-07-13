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

    @Test("not-yet-modelled kinds (link/tweet) resolve to .unknown until C2/C3")
    func futureKindsUnknown() {
        #expect(asset(kind: .link).content == .unknown)
        #expect(asset(kind: .tweet).content == .unknown)
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
}
