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
}
