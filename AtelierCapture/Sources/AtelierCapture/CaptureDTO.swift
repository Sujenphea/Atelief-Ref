// AtelierCapture — the capture wire contract (build-order #6, decision CQ2;
// extracted from AtelierServer by 092 · S0).
//
// One Codable request DTO, JSON with a base64-encoded image (no multipart —
// FlyingFox has no multipart parser, and base64's +33% is negligible at a
// handful of captures). The Chrome extension POSTs `CaptureRequest` to the
// loopback endpoint; the iOS share extension writes the same shape into the
// inbox (091 · D2). One contract, two producers — see this package's
// `Package.swift` for why that matters and what stayed behind.
//
// `decode(body:now:)` is the PURE seam the malformed-input tests target (T3):
// it turns raw JSON bytes into a validated `DecodedCapture` (image `Data` +
// `SourceDraft` + optional target collection) or throws a typed
// `CaptureDecodeError`. It never touches the network or the pipeline, so the
// whole matrix of bad inputs is asserted without any I/O.
//
// A NOTE ON THE BASE64 `image` FIELD: it is the HTTP producer's path, bounded by
// the server's body cap. The inbox producer leaves it nil and writes the bytes
// to a sidecar file instead (092 · S2) — neither process should hold a base64
// string of an image in memory when the bytes are already on disk.

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

/// A validated capture whose BYTES ARE ELSEWHERE — everything but the media
/// itself, for a producer that hands the pipeline a file URL.
///
/// Named for the video route that needed it first (``CaptureRoutes/handleIngestVideo``
/// streams the body to a temp file and pairs its URL with this), but the shape is
/// about transport, not media type: 092 · S3's inbox drain has exactly the same
/// problem — the bytes are already a `.bin` sidecar on disk — and reuses it rather
/// than declaring a fourth near-identical struct.
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

/// What a capture decoded to when its BYTES ARE A FILE the caller already holds
/// (092 · S3) — the inbox drain's shape, and the reason it is a separate result
/// type rather than a flag on ``DecodedInput``.
///
/// ``DecodedInput`` carries `Data` in two of its three cases, because the HTTP
/// producer's bytes arrive base64 inside the JSON. The inbox producer's bytes are
/// already a `.bin` sidecar next to the record, and reading them into memory to
/// hand them to a pipeline that will write them back out is the one mistake the
/// whole handoff design exists to avoid — so this enum carries the SAME validated
/// provenance / target / ledger tags with no bytes in it at all, and the caller
/// pairs each case with the file URL it already has.
///
/// The routing is identical to ``CaptureDecoder/decodeInput(_:now:)``: a
/// media-less `kind` is a content capture (here always WITH a card image, since
/// there is a file), anything else is byte-backed.
public enum DecodedFileInput: Equatable, Sendable {
    /// A byte-backed capture — the file IS the asset.
    case bytes(DecodedVideoCapture)
    /// A media-less capture that also carries a card image (003 · C3, Option 3),
    /// where the card image is the file.
    case contentWithFile(DecodedContentCapture)
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
        try decodeInput(decodeRequest(body), now: now)
    }

    /// The same funnel over a request that has ALREADY been decoded from JSON
    /// (092 · S3).
    ///
    /// The inbox producer's capture arrives as a `CaptureRequest` nested inside an
    /// `InboxRecord`, not as a loose body — so the body-taking entry point above is
    /// now *decode the JSON, then run this*, and the two producers share every line
    /// of validation and routing that follows. Re-encoding a record's request back
    /// to JSON just to re-parse it would be the alternative, and a funnel that can
    /// only be entered through a serializer is a funnel with a second copy waiting
    /// to be written.
    public static func decodeInput(_ request: CaptureRequest, now: Date) throws -> DecodedInput {
        if let kind = try mediaLessKind(request.kind) {
            // A media-less kind carrying image bytes → the hybrid card-image
            // path (Option 3); otherwise a pure text-card content item.
            if request.image != nil {
                return .contentWithImage(
                    try decodeContentWithImage(request, kind: kind, now: now))
            }
            return .content(try decodeContent(request, kind: kind, now: now))
        }
        return .image(try decodeImage(request, now: now))
    }

    /// The funnel for a capture whose bytes are a FILE the caller already holds —
    /// the inbox drain (092 · S3).
    ///
    /// Same kind validation, same provenance validation, same routing as
    /// ``decodeInput(_:now:)``; the only difference is that nothing here looks at
    /// the base64 `image` field, because on this path the bytes never were a
    /// string. The caller pairs the result with its file URL.
    ///
    /// Note what is NOT rejected: a byte-backed capture is valid by virtue of the
    /// file existing, which the caller established before asking (the record is the
    /// commit marker — see `InboxLayout.isComplete(_:)`), so there is no
    /// `.emptyImage` case to reach.
    public static func decodeFileInput(
        _ request: CaptureRequest, now: Date
    ) throws -> DecodedFileInput {
        if let kind = try mediaLessKind(request.kind) {
            return .contentWithFile(try decodeContent(request, kind: kind, now: now))
        }
        return .bytes(
            DecodedVideoCapture(
                provenance: try makeSourceDraft(request.provenance, now: now),
                collectionID: request.collectionId,
                jobID: request.jobId,
                sourceID: request.sourceId))
    }

    /// Validate a raw `kind` and answer *is this a media-less capture* — the one
    /// routing decision both funnels above make, spelled once.
    ///
    /// `nil` means "take the byte path": either no `kind` at all, or a byte kind
    /// (`image` / `video`), which still needs its bytes from wherever they live. An
    /// unrecognized string is structurally unusable and throws.
    private static func mediaLessKind(_ rawKind: String?) throws -> AssetKind? {
        guard let rawKind else { return nil }
        guard let kind = AssetKind(rawValue: rawKind) else {
            throw CaptureDecodeError.unknownKind(rawKind)
        }
        return kind.isByteBacked ? nil : kind
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
