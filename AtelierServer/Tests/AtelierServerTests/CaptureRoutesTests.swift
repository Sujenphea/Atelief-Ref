// AtelierServer — route logic tests (build-order #6, decisions T1/T3, P2/P3).
//
// Drives the pure `handleIngest` against a REAL temp library (services + store +
// coordinator) with no socket: asserts the HTTP status + response body AND that
// the asset actually persisted with the right provenance. Covers success, dedup,
// default-collection routing, the onCapture hook, and the failure paths.

import Foundation
import Testing

import AtelierCore
import AtelierIngestion
@testable import AtelierServer

/// Thread-safe recorder for the `onCapture` hook (called synchronously inside
/// `handleIngest`, so it is fully populated once the call returns).
final class OnCaptureSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(collectionID: UUID, count: Int)] = []
    func record(_ id: UUID, _ outcomes: [IngestOutcome]) {
        lock.lock(); _events.append((id, outcomes.count)); lock.unlock()
    }
    var events: [(collectionID: UUID, count: Int)] {
        lock.lock(); defer { lock.unlock() }; return _events
    }
}

@Suite("CaptureRoutes")
struct CaptureRoutesTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRoutes(
        _ env: ServerTestEnv, spy: OnCaptureSpy? = nil
    ) -> CaptureRoutes {
        let target = env.collectionID
        let onCapture: (@Sendable (UUID, [IngestOutcome]) -> Void)?
        if let spy {
            onCapture = { id, outcomes in spy.record(id, outcomes) }
        } else {
            onCapture = nil
        }
        return CaptureRoutes(
            coordinator: env.coordinator,
            defaultCollectionID: { target },
            onCapture: onCapture)
    }

    // MARK: - Video route

    /// Write mp4 bytes to a temp file (the transport streams to disk; the route
    /// ingests from the URL). Returns the URL; caller removes it.
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        return url
    }

    @Test("valid video → 200 ingested + persisted .video asset from the header")
    func validVideoPersists() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let file = try tempFile(ServerFixtures.mp4()); defer { try? FileManager.default.removeItem(at: file) }
        let header = ServerFixtures.provenanceHeader(collectionId: env.collectionID)

        let result = await routes.handleIngestVideo(
            fileURL: file, provenanceHeader: header, now: Self.now)

        #expect(result.statusCode == 200)
        #expect(result.response.status == "ingested")
        #expect(result.response.assetId != nil)
        let items = try await env.items()
        #expect(items.count == 1)
        #expect(items.first?.asset.kind == .video)
        #expect(items.first?.asset.mimeType == "video/mp4")
        #expect((items.first?.asset.duration ?? 0) > 0)
    }

    @Test("video with a missing provenance header → 400, nothing persisted")
    func videoMissingHeader() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let file = try tempFile(ServerFixtures.mp4()); defer { try? FileManager.default.removeItem(at: file) }

        let result = await routes.handleIngestVideo(
            fileURL: file, provenanceHeader: nil, now: Self.now)

        #expect(result.statusCode == 400)
        #expect(result.response.status == "error")
        #expect(try await env.items().isEmpty)
    }

    @Test("valid capture → 200 ingested + asset persisted with full provenance")
    func validCapturePersists() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let body = CaptureRequest.sample(collectionId: env.collectionID).jsonData()

        let result = await routes.handleIngest(body: body, now: Self.now)

        #expect(result.statusCode == 200)
        #expect(result.response.status == "ingested")
        #expect(result.response.deduplicated == false)
        #expect(result.response.assetId != nil)

        let items = try await env.items()
        #expect(items.count == 1)
        let detail = try #require(items.first)
        #expect(detail.source.platform == .twitter)
        #expect(detail.source.authorHandle == "@designer")
        #expect(detail.source.originalURL == "https://x.com/designer/status/42")
        #expect(detail.asset.id == result.response.assetId)
    }

    @Test("re-capturing identical bytes+provenance dedups: deduplicated true, one item")
    func dedupOnRecapture() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let body = CaptureRequest.sample(collectionId: env.collectionID).jsonData()

        let first = await routes.handleIngest(body: body, now: Self.now)
        let second = await routes.handleIngest(body: body, now: Self.now)

        #expect(first.response.deduplicated == false)
        #expect(second.response.deduplicated == true)
        #expect(try await env.items().count == 1)
    }

    @Test("no collectionId → routed to the default collection")
    func defaultCollectionRouting() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let body = CaptureRequest.sample(collectionId: nil).jsonData()

        let result = await routes.handleIngest(body: body, now: Self.now)

        #expect(result.statusCode == 200)
        #expect(try await env.items().count == 1)
    }

    @Test("onCapture fires once with the effective collection + one outcome")
    func onCaptureHook() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let spy = OnCaptureSpy()
        let routes = makeRoutes(env, spy: spy)
        let body = CaptureRequest.sample(collectionId: env.collectionID).jsonData()

        _ = await routes.handleIngest(body: body, now: Self.now)

        #expect(spy.events.count == 1)
        #expect(spy.events.first?.collectionID == env.collectionID)
        #expect(spy.events.first?.count == 1)
    }

    @Test("non-image bytes → 422 error, nothing persisted")
    func nonImageFails() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = CaptureRequest(
            image: ServerFixtures.nonImageBase64(),
            provenance: ProvenanceDTO(platform: "web", originalURL: "https://e.com/x"),
            collectionId: env.collectionID)

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 422)
        #expect(result.response.status == "error")
        #expect(try await env.items().isEmpty)
    }

    @Test("malformed base64 → 400, nothing persisted")
    func badBase64Fails() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = CaptureRequest(
            image: "!!!", provenance: ProvenanceDTO(platform: "web"))

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 400)
        #expect(try await env.items().isEmpty)
    }

    @Test("unknown target collection → 422 (persistence rejects it)")
    func bogusCollectionFails() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let body = CaptureRequest.sample(collectionId: UUID()).jsonData()

        let result = await routes.handleIngest(body: body, now: Self.now)

        #expect(result.statusCode == 422)
        #expect(try await env.items().isEmpty)
    }

    // MARK: - Content route (003 · C3)

    /// A media-less content capture request (no image; a `kind` + `payload`).
    private func contentRequest(
        kind: String, payload: AssetPayload, platform: String = "local_paste",
        originalURL: String? = nil, collectionId: UUID?
    ) -> CaptureRequest {
        CaptureRequest(
            provenance: ProvenanceDTO(platform: platform, originalURL: originalURL),
            collectionId: collectionId, kind: kind, payload: payload)
    }

    @Test("a media-less content capture → 200 ingested + persisted asset with nil bytes")
    func contentCapturePersists() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = contentRequest(
            kind: "color", payload: AssetPayload(color: ColorPayload(hex: "#FF0000")),
            collectionId: env.collectionID)

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 200)
        #expect(result.response.status == "ingested")
        let detail = try #require(try await env.items().first)
        #expect(detail.asset.kind == .color)
        #expect(detail.asset.blobHash == nil)             // no bytes
        #expect(detail.asset.content == .color(hex: "#ff0000"))
        #expect(detail.asset.id == result.response.assetId)
    }

    @Test("a link content capture dedups on canonical URL through the same coordinator")
    func contentDedupOnRecapture() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let payload = AssetPayload(link: LinkPayload(url: "https://ex.com/x"))
        let a = contentRequest(
            kind: "link", payload: payload, platform: "web",
            originalURL: "https://ex.com/x", collectionId: env.collectionID)
        // Trailing slash + tracking param → same canonical URL.
        let b = contentRequest(
            kind: "link",
            payload: AssetPayload(link: LinkPayload(url: "https://ex.com/x/?utm_source=tw")),
            platform: "web", originalURL: "https://ex.com/x/?utm_source=tw",
            collectionId: env.collectionID)

        let first = await routes.handleIngest(body: a.jsonData(), now: Self.now)
        let second = await routes.handleIngest(body: b.jsonData(), now: Self.now)

        #expect(first.response.deduplicated == false)
        #expect(second.response.deduplicated == true)
        #expect(try await env.items().count == 1)
    }

    @Test("an invalid content payload → 422, nothing persisted")
    func invalidContentFails() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = contentRequest(
            kind: "color", payload: AssetPayload(color: ColorPayload(hex: "nope")),
            collectionId: env.collectionID)

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 422)
        #expect(try await env.items().isEmpty)
    }

    @Test("a tweet content capture WITH a card image → 200 + blob-backed tweet asset")
    func contentWithImagePersists() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = CaptureRequest(
            image: ServerFixtures.pngBase64(),
            provenance: ProvenanceDTO(
                platform: "twitter", originalURL: "https://x.com/ava/status/900",
                authorHandle: "@ava"),
            collectionId: env.collectionID,
            kind: "tweet",
            payload: AssetPayload(tweet: TweetPayload(
                tweetID: "https://x.com/ava/status/900", text: "a brass lamp",
                authorHandle: "@ava",
                media: [TweetMedia(url: "https://pbs.example/a.jpg")])))

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 200)
        #expect(result.response.status == "ingested")
        let detail = try #require(try await env.items().first)
        #expect(detail.asset.kind == .tweet)
        #expect(detail.asset.dedupKey == "900")
        // The card image landed as a real blob AND surfaces as the tweet's card.
        let hash = try #require(detail.asset.blobHash)
        if case .tweet(let t) = detail.asset.content {
            #expect(t.cardImageBlobHash == hash)
            #expect(t.text == "a brass lamp")
        } else {
            Issue.record("expected .tweet content")
        }
        // Provenance is aligned to the deterministic permalink.
        #expect(detail.source.originalURL == "https://x.com/i/status/900")
    }

    @Test("an unknown content kind → 400, nothing persisted")
    func unknownContentKindFails() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = makeRoutes(env)
        let request = contentRequest(
            kind: "sticker", payload: AssetPayload(), collectionId: env.collectionID)

        let result = await routes.handleIngest(body: request.jsonData(), now: Self.now)

        #expect(result.statusCode == 400)
        #expect(try await env.items().isEmpty)
    }
}
