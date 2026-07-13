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
///
/// `jobId` + `sourceId` are the OPTIONAL bulk-import tags (015 · 3A): when the
/// capture is one item of a sweep, they let the server record a `job_item` in the
/// ledger. Absent on ordinary single-item captures, so the wire is unchanged for
/// the existing path.
public struct CaptureRequest: Codable, Equatable, Sendable {
    /// Base64-encoded image bytes the extension already fetched in-browser.
    /// Optional (003 · C3): a MEDIA-LESS capture (`kind` + `payload`) carries no
    /// image, so this is absent for a tweet / link / color.
    public var image: String?
    public var provenance: ProvenanceDTO
    /// Target collection; when omitted the server routes to the default folder.
    public var collectionId: UUID?
    /// The owning bulk-import job, when this capture is part of a sweep.
    public var jobId: UUID?
    /// The platform's stable item id (tweet id / pin id), for the ledger row.
    public var sourceId: String?
    /// The asset kind for a MEDIA-LESS capture (003 · C3): `tweet` / `link` /
    /// `color`. Absent (or a byte kind) ⇒ the image path. Validated against
    /// ``AssetKind`` during decode; the funnel is the single content authority.
    public var kind: String?
    /// The media-less content's substance (003 · C3) — the ``AssetPayload`` the
    /// extension extracted (color hex / link URL / tweet id+text+media). The
    /// funnel canonicalizes + validates it, so the wire carries raw intent.
    public var payload: AssetPayload?

    public init(
        image: String? = nil, provenance: ProvenanceDTO, collectionId: UUID? = nil,
        jobId: UUID? = nil, sourceId: String? = nil,
        kind: String? = nil, payload: AssetPayload? = nil
    ) {
        self.image = image
        self.provenance = provenance
        self.collectionId = collectionId
        self.jobId = jobId
        self.sourceId = sourceId
        self.kind = kind
        self.payload = payload
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
    /// The owning job's current lifecycle status, stamped ONLY on a bulk-tagged
    /// capture's reply (7A relay feedback): when the user pauses/cancels in the app,
    /// the next item's response carries `paused`/`halted` and the extension halts the
    /// sweep. Absent (nil, unencoded) on ordinary single-item captures — the wire is
    /// unchanged for the existing path.
    public var jobStatus: String?

    public init(
        status: String, assetId: UUID? = nil,
        deduplicated: Bool? = nil, error: String? = nil, jobStatus: String? = nil
    ) {
        self.status = status
        self.assetId = assetId
        self.deduplicated = deduplicated
        self.error = error
        self.jobStatus = jobStatus
    }

    public static func ingested(
        assetId: UUID, deduplicated: Bool, jobStatus: String? = nil
    ) -> CaptureResponse {
        CaptureResponse(
            status: "ingested", assetId: assetId, deduplicated: deduplicated,
            jobStatus: jobStatus)
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
    /// The owning bulk-import job, when this capture is part of a sweep (3A).
    public var jobId: UUID?
    /// The platform's stable item id (tweet id / pin id), for the ledger row.
    public var sourceId: String?

    public init(
        provenance: ProvenanceDTO, collectionId: UUID? = nil,
        jobId: UUID? = nil, sourceId: String? = nil
    ) {
        self.provenance = provenance
        self.collectionId = collectionId
        self.jobId = jobId
        self.sourceId = sourceId
    }
}

/// A validated capture, ready to become an ``IngestInput`` — the output of the
/// pure `decode` step. `jobID`/`sourceID` are the optional bulk-import ledger
/// tags (3A), carried through so the route can record a `job_item`.
public struct DecodedCapture: Equatable, Sendable {
    public let imageData: Data
    public let provenance: SourceDraft
    public let collectionID: UUID?
    public let jobID: UUID?
    public let sourceID: String?
}

/// A validated **video** capture: its provenance (from the header) + target
/// collection. The bytes are NOT here — they were streamed to a temp file whose
/// URL the route pairs with this (``CaptureRoutes/handleIngestVideo``).
public struct DecodedVideoCapture: Equatable, Sendable {
    public let provenance: SourceDraft
    public let collectionID: UUID?
    public let jobID: UUID?
    public let sourceID: String?
}

/// A validated MEDIA-LESS capture (003 · C3): the ``AssetContentDraft`` the
/// funnel will ingest, plus provenance + target + the optional bulk-ledger tags.
/// The sibling of ``DecodedCapture`` for the content path — no image bytes.
public struct DecodedContentCapture: Equatable, Sendable {
    public let draft: AssetContentDraft
    public let provenance: SourceDraft
    public let collectionID: UUID?
    public let jobID: UUID?
    public let sourceID: String?
}

/// A validated MEDIA-LESS capture that ALSO carries a card image (003 · C3,
/// Option 3): the ``AssetContentDraft`` plus the decoded image bytes it renders,
/// with provenance + target + the optional bulk-ledger tags. A tweet whose
/// picture rides in with the request — the sibling of ``DecodedContentCapture``
/// with a real blob.
public struct DecodedContentImageCapture: Equatable, Sendable {
    public let draft: AssetContentDraft
    public let imageData: Data
    public let provenance: SourceDraft
    public let collectionID: UUID?
    public let jobID: UUID?
    public let sourceID: String?
}

/// What a JSON capture body decoded to (003 · C3): a byte-backed image, a
/// media-less content item, or a media-less item WITH a card image (Option 3).
/// The route branches on this once — all flow through the same coordinator
/// (ledger / live-refresh shared).
public enum DecodedInput: Equatable, Sendable {
    case image(DecodedCapture)
    case content(DecodedContentCapture)
    case contentWithImage(DecodedContentImageCapture)
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
    /// The `kind` field was present but is not a known ``AssetKind`` (003 · C3).
    case unknownKind(String)
    /// A media-less capture (`kind` present + media-less) carried no `payload`
    /// to ingest (003 · C3).
    case missingContentPayload

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
        case .unknownKind(let value): return "Unknown asset kind '\(value)'."
        case .missingContentPayload:
            return "A media-less capture is missing its `payload`."
        }
    }
}

public enum CaptureDecoder {
    /// The request header carrying a video capture's provenance (base64 JSON of
    /// ``VideoCaptureHeader``). Named in the CORS allow-list so the browser lets
    /// the POST through (``CaptureAuth/corsHeaders(origin:)``).
    public static let provenanceHeaderName = "X-Atelier-Provenance"

    /// Turn a raw JSON request body into a validated ``DecodedInput`` (003 · C3) —
    /// a byte-backed image or a media-less content item. The route branches on the
    /// result; both share the ingest coordinator downstream.
    ///
    /// Routing: a `kind` naming a MEDIA-LESS ``AssetKind`` (`tweet` / `link` /
    /// `color`) is a content capture — and when it ALSO carries an `image` (a
    /// tweet's card picture, Option 3) it routes to ``contentWithImage`` so the
    /// asset gets a real blob; without an image it stays a pure text-card
    /// ``content``. An absent `kind` or a byte kind (`image` / `video`) is the
    /// image path. As with the image decode, per-kind content requirements (valid
    /// hex / URL / tweet id) are NOT checked here — `AppServices.ingestContent` is
    /// the single content authority; this only rejects what is structurally
    /// unusable (unknown kind, no payload, malformed image base64).
    public static func decodeInput(body: Data, now: Date) throws -> DecodedInput {
        let request = try decodeRequest(body)
        if let rawKind = request.kind {
            guard let kind = AssetKind(rawValue: rawKind) else {
                throw CaptureDecodeError.unknownKind(rawKind)
            }
            if !kind.isByteBacked {
                // A media-less kind carrying image bytes → the hybrid card-image
                // path (Option 3); otherwise a pure text-card content item.
                if request.image != nil {
                    return .contentWithImage(
                        try decodeContentWithImage(request, kind: kind, now: now))
                }
                return .content(try decodeContent(request, kind: kind, now: now))
            }
            // A byte kind (image/video) still needs its bytes — image path.
        }
        return .image(try decodeImage(request, now: now))
    }

    /// Turn a raw JSON request body into a validated ``DecodedCapture`` (the
    /// byte-backed image path). Kept as the image-only entry point (the content
    /// router is ``decodeInput(body:now:)``).
    ///
    /// `now` is the server-owned capture timestamp (we do NOT trust a
    /// client-supplied time). Field-level provenance requirements (e.g. a
    /// platform that mandates `originalURL`) are intentionally NOT checked here —
    /// `AppServices.ingest` is the single validation authority for those, so this
    /// step only rejects what makes the request structurally unusable.
    public static func decode(body: Data, now: Date) throws -> DecodedCapture {
        try decodeImage(decodeRequest(body), now: now)
    }

    /// Decode + reject a malformed JSON body once (shared by both entry points).
    private static func decodeRequest(_ body: Data) throws -> CaptureRequest {
        do {
            return try JSONDecoder().decode(CaptureRequest.self, from: body)
        } catch {
            throw CaptureDecodeError.malformedJSON
        }
    }

    /// The image path: require present, valid, non-empty base64 image bytes.
    private static func decodeImage(
        _ request: CaptureRequest, now: Date
    ) throws -> DecodedCapture {
        return DecodedCapture(
            imageData: try decodeImageBytes(request.image),
            provenance: try makeSourceDraft(request.provenance, now: now),
            collectionID: request.collectionId,
            jobID: request.jobId,
            sourceID: request.sourceId)
    }

    /// The content path: a media-less capture needs a `payload`; the funnel then
    /// canonicalizes + validates it per kind (003 · C3).
    private static func decodeContent(
        _ request: CaptureRequest, kind: AssetKind, now: Date
    ) throws -> DecodedContentCapture {
        guard let payload = request.payload else {
            throw CaptureDecodeError.missingContentPayload
        }
        return DecodedContentCapture(
            draft: AssetContentDraft(kind: kind, payload: payload),
            provenance: try makeSourceDraft(request.provenance, now: now),
            collectionID: request.collectionId,
            jobID: request.jobId,
            sourceID: request.sourceId)
    }

    /// The hybrid content-with-card-image path (003 · C3, Option 3): a media-less
    /// `payload` AND valid non-empty base64 image bytes. Both must be structurally
    /// usable; the funnel validates the content per kind downstream.
    private static func decodeContentWithImage(
        _ request: CaptureRequest, kind: AssetKind, now: Date
    ) throws -> DecodedContentImageCapture {
        guard let payload = request.payload else {
            throw CaptureDecodeError.missingContentPayload
        }
        return DecodedContentImageCapture(
            draft: AssetContentDraft(kind: kind, payload: payload),
            imageData: try decodeImageBytes(request.image),
            provenance: try makeSourceDraft(request.provenance, now: now),
            collectionID: request.collectionId,
            jobID: request.jobId,
            sourceID: request.sourceId)
    }

    /// Validate a base64 `image` field into non-empty bytes (shared by the image
    /// and hybrid content-with-image paths — DRY).
    private static func decodeImageBytes(_ image: String?) throws -> Data {
        guard let image else { throw CaptureDecodeError.emptyImage }
        guard let imageData = Data(base64Encoded: image) else {
            throw CaptureDecodeError.invalidBase64
        }
        guard !imageData.isEmpty else { throw CaptureDecodeError.emptyImage }
        return imageData
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
            collectionID: header.collectionId,
            jobID: header.jobId,
            sourceID: header.sourceId)
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
