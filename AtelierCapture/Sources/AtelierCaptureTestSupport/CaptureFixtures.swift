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
// with no inbox counterpart).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import AtelierCapture
import AtelierCore

/// Deterministic bytes and wire values shared by every capture-contract suite.
public enum CaptureFixtures {
    /// A valid `width × height` PNG (deterministic solid fill).
    public static func png(width: Int = 16, height: Int = 16) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
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

    public func jsonData() -> Data { try! JSONEncoder().encode(self) }
}
