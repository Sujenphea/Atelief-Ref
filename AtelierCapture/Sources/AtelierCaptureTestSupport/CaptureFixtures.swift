// AtelierCaptureTestSupport — the canonical capture fixtures (092 · S0).
//
// A test-only target, not part of the `AtelierCapture` library: nothing ships
// it, and only test targets depend on it. It exists because the capture contract
// has more than one consumer now, and a fixture duplicated per consumer is the
// same drift the contract extraction exists to prevent — two `sample()` builders
// would silently disagree the first time a field is added on one side.
//
// It carries the pure image bytes + request builders. What stays behind in
// `AtelierServer`'s TestSupport is what only a server needs: the wired
// `ServerTestEnv` (a real migrated library, so it needs AtelierIngestion), and
// the synthesized MP4 (AVAssetWriter — the video path is an HTTP-streamed upload
// with no inbox counterpart). The richer image builders — JPEG, HEIC, an EXIF
// rotation, a truncated JPEG — are `FixtureImages` beside this (457); `png()` is
// one of them under the name every capture suite already uses.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import AtelierCapture
import AtelierCore

/// Deterministic bytes and wire values shared by every capture-contract suite.
public enum CaptureFixtures {
    /// A valid `width × height` PNG (deterministic solid fill).
    ///
    /// `FixtureImages.solidColorImage` under the name the capture suites use; PNG is
    /// lossless, so the bytes are a function of the size and a round trip through the
    /// inbox can compare them. Non-throwing because a `CGContext` of a positive size
    /// does not fail on any host this runs on, and sixty call sites should not `try`.
    public static func png(width: Int = 16, height: Int = 16) -> Data {
        try! FixtureImages.solidColorImage(
            width: width, height: height, red: 51, green: 128, blue: 204, format: .png)
    }

    /// The base64 of a valid PNG — the `image` field of a well-formed request.
    public static func pngBase64(width: Int = 16, height: Int = 16) -> String {
        png(width: width, height: height).base64EncodedString()
    }

    /// Non-image bytes (UTF-8 text) — a valid base64 payload that is NOT an image,
    /// to drive `IngestError.unsupportedType`.
    public static func nonImageBase64() -> String {
        Data("not an image".utf8).base64EncodedString()
    }

    /// The base64-JSON value for the `X-Atelier-Provenance` header of a video POST.
    public static func provenanceHeader(
        platform: String = "twitter", collectionId: UUID? = nil
    ) -> String {
        let header = VideoCaptureHeader(
            provenance: ProvenanceDTO(
                platform: platform,
                originalURL: "https://x.com/designer/status/42",
                authorHandle: "@designer",
                rawMetadata: .object(["tweetId": .string("42")])),
            collectionId: collectionId)
        return try! JSONEncoder().encode(header).base64EncodedString()
    }
}

// MARK: - Request builders

extension CaptureRequest {
    /// A well-formed capture with rich provenance.
    public static func sample(
        image: String = CaptureFixtures.pngBase64(),
        platform: String = "twitter",
        collectionId: UUID? = nil
    ) -> CaptureRequest {
        CaptureRequest(
            image: image,
            provenance: ProvenanceDTO(
                platform: platform,
                originalURL: "https://x.com/designer/status/42",
                authorHandle: "@designer",
                authorName: "A Designer",
                title: "a reference",
                rawMetadata: .object(["likes": .number(9)])),
            collectionId: collectionId)
    }

    /// A well-formed MEDIA-LESS capture (003 · C3) — a `tweet` / `link` / `color` with
    /// no bytes anywhere. The inbox path's other half (092 · S2): these produce a
    /// record with no payload sidecar, so the writer matrix needs one per kind.
    ///
    /// `originalURL` and `title` are parameters (457) so a suite asserting provenance
    /// crosses verbatim can name the URL it expects back, rather than building the
    /// request by hand beside this one.
    public static func sampleContent(
        kind: String = "link",
        payload: AssetPayload = AssetPayload(
            link: LinkPayload(url: "https://ex.com/p", title: "P")),
        platform: String = "web",
        originalURL: String? = "https://ex.com/p",
        title: String? = "P",
        collectionId: UUID? = nil
    ) -> CaptureRequest {
        CaptureRequest(
            provenance: ProvenanceDTO(
                platform: platform,
                originalURL: originalURL,
                title: title),
            collectionId: collectionId,
            kind: kind,
            payload: payload)
    }

    /// A media-less `link` capture of `url` and nothing else — no title, the shape
    /// `ShareCapture.draft(for: .link)` produces from a share sheet.
    public static func sampleLink(_ url: String, platform: String = "web") -> CaptureRequest {
        sampleContent(
            kind: AssetKind.link.rawValue,
            payload: AssetPayload(link: LinkPayload(url: url)),
            platform: platform, originalURL: url, title: nil)
    }

    public func jsonData() -> Data { try! JSONEncoder().encode(self) }
}
