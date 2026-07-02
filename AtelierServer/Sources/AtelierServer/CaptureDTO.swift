// AtelierServer — the capture wire contract (build-order #6, decision CQ2).
//
// One Codable request DTO + one response DTO, JSON with a base64-encoded image
// (no multipart — FlyingFox has no multipart parser, and base64's +33% is
// negligible at a handful of captures). The extension POSTs `CaptureRequest`;
// the endpoint answers `CaptureResponse`.
//
// `decode(body:now:)` is the PURE seam the malformed-input tests target (T3):
// it turns raw JSON bytes into a validated `DecodedCapture` (image `Data` +
// `SourceDraft` + optional target collection) or throws a typed
// `CaptureDecodeError`. It never touches the network or the pipeline, so the
// whole matrix of bad inputs is asserted without any I/O.

import Foundation
import AtelierCore

/// Provenance as it arrives on the wire — the per-site fields the extension's
/// content script extracted. `platform` is a raw string validated against
/// ``Platform`` during decode; `rawMetadata` is the platform-specific escape
/// hatch (optional, defaults to an empty object).
public struct ProvenanceDTO: Codable, Equatable, Sendable {
    public var platform: String
    public var originalURL: String?
    public var authorHandle: String?
    public var authorName: String?
    public var title: String?
    public var rawMetadata: JSONValue?

    public init(
        platform: String,
        originalURL: String? = nil,
        authorHandle: String? = nil,
        authorName: String? = nil,
        title: String? = nil,
        rawMetadata: JSONValue? = nil
    ) {
        self.platform = platform
        self.originalURL = originalURL
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.title = title
        self.rawMetadata = rawMetadata
    }
}

/// The capture POST body: a base64 image, its provenance, and an optional target
/// collection (absent ⇒ the app's default import folder).
public struct CaptureRequest: Codable, Equatable, Sendable {
    /// Base64-encoded image bytes the extension already fetched in-browser.
    public var image: String
    public var provenance: ProvenanceDTO
    /// Target collection; when omitted the server routes to the default folder.
    public var collectionId: UUID?

    public init(image: String, provenance: ProvenanceDTO, collectionId: UUID? = nil) {
        self.image = image
        self.provenance = provenance
        self.collectionId = collectionId
    }
}

/// The capture response: `status` is `"ingested"` or `"error"`. On success the
/// new asset's id + whether the bytes deduplicated against an existing blob; on
/// failure a human-readable reason.
public struct CaptureResponse: Codable, Equatable, Sendable {
    public var status: String
    public var assetId: UUID?
    public var deduplicated: Bool?
    public var error: String?

    public init(
        status: String, assetId: UUID? = nil,
        deduplicated: Bool? = nil, error: String? = nil
    ) {
        self.status = status
        self.assetId = assetId
        self.deduplicated = deduplicated
        self.error = error
    }

    public static func ingested(assetId: UUID, deduplicated: Bool) -> CaptureResponse {
        CaptureResponse(
            status: "ingested", assetId: assetId, deduplicated: deduplicated)
    }

    public static func error(_ message: String) -> CaptureResponse {
        CaptureResponse(status: "error", error: message)
    }
}

/// The metadata that rides alongside a raw **video** upload. The image path
/// carries provenance inside the JSON body, but a video body is the raw file
/// bytes (streamed, never base64/JSON — see ``CaptureServer``), so its provenance
/// travels in the ``CaptureDecoder/provenanceHeaderName`` header as base64 JSON of
/// this DTO. Same fields as ``CaptureRequest`` minus the inline image.
public struct VideoCaptureHeader: Codable, Equatable, Sendable {
    public var provenance: ProvenanceDTO
    public var collectionId: UUID?

    public init(provenance: ProvenanceDTO, collectionId: UUID? = nil) {
        self.provenance = provenance
        self.collectionId = collectionId
    }
}

/// A validated capture, ready to become an ``IngestInput`` — the output of the
/// pure `decode` step.
public struct DecodedCapture: Equatable, Sendable {
    public let imageData: Data
    public let provenance: SourceDraft
    public let collectionID: UUID?
}

/// A validated **video** capture: its provenance (from the header) + target
/// collection. The bytes are NOT here — they were streamed to a temp file whose
/// URL the route pairs with this (``CaptureRoutes/handleIngestVideo``).
public struct DecodedVideoCapture: Equatable, Sendable {
    public let provenance: SourceDraft
    public let collectionID: UUID?
}

/// Why a raw capture body could not be turned into a `DecodedCapture`. Each maps
/// to a 4xx (see ``CaptureRoutes``); the `message` is surfaced to the extension.
public enum CaptureDecodeError: Error, Equatable {
    case malformedJSON
    case invalidBase64
    case emptyImage
    case unknownPlatform(String)
    case missingProvenanceHeader
    case malformedProvenanceHeader

    public var message: String {
        switch self {
        case .malformedJSON: return "Request body is not valid CaptureRequest JSON."
        case .invalidBase64: return "The `image` field is not valid base64."
        case .emptyImage: return "The decoded image is empty."
        case .unknownPlatform(let value): return "Unknown platform '\(value)'."
        case .missingProvenanceHeader:
            return "Missing the \(CaptureDecoder.provenanceHeaderName) header."
        case .malformedProvenanceHeader:
            return "The \(CaptureDecoder.provenanceHeaderName) header is not valid "
                + "base64-encoded VideoCaptureHeader JSON."
        }
    }
}

public enum CaptureDecoder {
    /// The request header carrying a video capture's provenance (base64 JSON of
    /// ``VideoCaptureHeader``). Named in the CORS allow-list so the browser lets
    /// the POST through (``CaptureAuth/corsHeaders(origin:)``).
    public static let provenanceHeaderName = "X-Atelier-Provenance"

    /// Turn a raw JSON request body into a validated ``DecodedCapture``.
    ///
    /// `now` is the server-owned capture timestamp (we do NOT trust a
    /// client-supplied time). Field-level provenance requirements (e.g. a
    /// platform that mandates `originalURL`) are intentionally NOT checked here —
    /// `AppServices.ingest` is the single validation authority for those, so this
    /// step only rejects what makes the request structurally unusable.
    public static func decode(body: Data, now: Date) throws -> DecodedCapture {
        let request: CaptureRequest
        do {
            request = try JSONDecoder().decode(CaptureRequest.self, from: body)
        } catch {
            throw CaptureDecodeError.malformedJSON
        }

        guard let imageData = Data(base64Encoded: request.image) else {
            throw CaptureDecodeError.invalidBase64
        }
        guard !imageData.isEmpty else {
            throw CaptureDecodeError.emptyImage
        }

        return DecodedCapture(
            imageData: imageData,
            provenance: try makeSourceDraft(request.provenance, now: now),
            collectionID: request.collectionId)
    }

    /// Turn the base64-JSON provenance header of a **video** upload into a
    /// validated ``DecodedVideoCapture``. The bytes are handled separately (the
    /// route streamed them to a temp file); this validates only the metadata, with
    /// the same platform check + server-owned `now` as ``decode(body:now:)``.
    public static func decodeVideoHeader(
        _ headerValue: String?, now: Date
    ) throws -> DecodedVideoCapture {
        guard let headerValue, !headerValue.isEmpty else {
            throw CaptureDecodeError.missingProvenanceHeader
        }
        guard let json = Data(base64Encoded: headerValue) else {
            throw CaptureDecodeError.malformedProvenanceHeader
        }
        let header: VideoCaptureHeader
        do {
            header = try JSONDecoder().decode(VideoCaptureHeader.self, from: json)
        } catch {
            throw CaptureDecodeError.malformedProvenanceHeader
        }
        return DecodedVideoCapture(
            provenance: try makeSourceDraft(header.provenance, now: now),
            collectionID: header.collectionId)
    }

    /// Validate a wire ``ProvenanceDTO`` into a ``SourceDraft`` (shared by the
    /// image and video paths — DRY). The only structural check is a known
    /// `platform`; `now` is the server-owned capture time.
    private static func makeSourceDraft(
        _ dto: ProvenanceDTO, now: Date
    ) throws -> SourceDraft {
        guard let platform = Platform(rawValue: dto.platform) else {
            throw CaptureDecodeError.unknownPlatform(dto.platform)
        }
        return SourceDraft(
            platform: platform,
            originalURL: dto.originalURL,
            authorHandle: dto.authorHandle,
            authorName: dto.authorName,
            title: dto.title,
            capturedAt: now,
            rawMetadata: dto.rawMetadata ?? .object([:]))
    }
}
