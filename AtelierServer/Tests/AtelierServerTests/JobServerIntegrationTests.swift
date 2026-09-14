// AtelierServer — bulk-import job socket integration tests (015 · 3A, T11).
//
// Binds a REAL listener on an ephemeral port wired to a REAL job ledger
// (AppServices) and round-trips the `/jobs` handshake over HTTP: open a job,
// tagged ingests record job_items, known-sources reports the landed set, complete
// transitions the status — all gated by the SAME CaptureAuth. Includes the
// concurrent-tagged-POST consistency check (11A) and the idempotent re-POST.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore
@testable import AtelierServer

@Suite("CaptureServer /jobs (socket + real ledger)")
struct JobServerIntegrationTests {
    static let token = "job-integration-token"
    static let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
    static let caps = CapsDTO(
        maxBodyBytes: CaptureServer.defaultMaxBodyBytes,
        maxVideoBodyBytes: CaptureServer.defaultMaxVideoBodyBytes)

    private struct Running {
        let server: CaptureServer
        let env: ServerTestEnv
        let port: UInt16
    }

    private func start() async throws -> Running {
        let env = try await makeServerTestEnv()
        let target = env.collectionID
        // The real AppServices is both the ingest coordinator's store AND the job
        // ledger (it conforms to JobLedger) — one source of truth.
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { target },
            jobLedger: env.services)
        let jobRoutes = JobRoutes(ledger: env.services, caps: Self.caps)
        let server = CaptureServer(
            port: 0, auth: CaptureAuth(token: Self.token),
            routes: routes, jobRoutes: jobRoutes)
        try await server.start()
        let port = try #require(await server.boundPort())
        return Running(server: server, env: env, port: port)
    }

    private func request(
        _ running: Running, method: String, path: String,
        origin: String? = origin, token: String? = token, body: Data? = nil
    ) -> URLRequest {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(running.port)\(path)")!)
        req.httpMethod = method
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        if let token { req.setValue(token, forHTTPHeaderField: CaptureAuth.tokenHeaderName) }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// A tagged capture body (part of a sweep): distinct provenance per `sourceId`
    /// so each is a distinct landed item.
    private func taggedCapture(_ collectionID: UUID, jobID: UUID, sourceID: String) -> Data {
        CaptureRequest(
            image: CaptureFixtures.pngBase64(),
            provenance: ProvenanceDTO(
                platform: "pinterest",
                originalURL: "https://pinterest.com/pin/\(sourceID)/"),
            collectionId: collectionID, jobId: jobID, sourceId: sourceID).jsonData()
    }

    private func createJob(_ running: Running) async throws -> UUID {
        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs",
                         body: try! JSONEncoder().encode(
                            CreateJobRequest(platform: "pinterest", scope: "board:1", totalEstimate: 3))))
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        let decoded = try JSONDecoder().decode(JobResponse.self, from: data)
        #expect(decoded.status == "created")
        #expect(decoded.caps == Self.caps)  // 8A: server surfaces its own caps
        return try #require(decoded.jobId)
    }

    @Test("POST /jobs opens a persisted, open job and returns id + caps")
    func createPersists() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)
        let job = try await running.env.services.getJob(id: jobID)
        #expect(job.platform == .pinterest)
        #expect(job.scope == "board:1")
        #expect(job.status == .open)
        #expect(job.totalEstimate == 3)
    }

    @Test("a tagged ingest records a job_item; known-sources then reports it")
    func taggedIngestThenKnownSources() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)

        let (_, ingestResponse) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/ingest",
                         body: taggedCapture(running.env.collectionID, jobID: jobID, sourceID: "pin-1")))
        #expect((ingestResponse as? HTTPURLResponse)?.statusCode == 200)

        // The ledger now knows pin-1, and the progress counter reflects it.
        #expect(try await running.env.services.getJob(id: jobID).ingestedCount == 1)
        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "GET", path: "/jobs/\(jobID)/known-sources"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoded = try JSONDecoder().decode(JobResponse.self, from: data)
        #expect(decoded.sourceIds == ["pin-1"])
    }

    @Test("re-POSTing the same tagged capture is idempotent (one item, count stays 1)")
    func idempotentRePost() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)
        let body = taggedCapture(running.env.collectionID, jobID: jobID, sourceID: "pin-1")

        _ = try await URLSession.shared.data(for: request(running, method: "POST", path: "/ingest", body: body))
        _ = try await URLSession.shared.data(for: request(running, method: "POST", path: "/ingest", body: body))

        #expect(try await running.env.services.getJob(id: jobID).ingestedCount == 1)
        #expect(try await running.env.services.jobItems(forJob: jobID).count == 1)
    }

    @Test("concurrent tagged POSTs all land with an exactly-consistent count (11A)")
    func concurrentTaggedPosts() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)
        let sources = (0..<8).map { "pin-\($0)" }

        // Fire all captures concurrently into the one job.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for source in sources {
                group.addTask {
                    let (_, response) = try await URLSession.shared.data(
                        for: self.request(
                            running, method: "POST", path: "/ingest",
                            body: self.taggedCapture(running.env.collectionID, jobID: jobID, sourceID: source)))
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            for try await status in group { #expect(status == 200) }
        }

        // No lost updates: the recompute-in-txn counter equals the distinct items,
        // and known-sources lists every one.
        #expect(try await running.env.services.getJob(id: jobID).ingestedCount == sources.count)
        let (data, _) = try await URLSession.shared.data(
            for: request(running, method: "GET", path: "/jobs/\(jobID)/known-sources"))
        let decoded = try JSONDecoder().decode(JobResponse.self, from: data)
        #expect(decoded.sourceIds?.count == sources.count)
        #expect(Set(decoded.sourceIds ?? []) == Set(sources))
    }

    @Test("POST /jobs/{id}/complete transitions the persisted status")
    func completeTransitions() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)

        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs/\(jobID)/complete",
                         body: try! JSONEncoder().encode(CompleteJobRequest(status: "complete"))))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await running.env.services.getJob(id: jobID).status == .complete)
    }

    @Test("POST /jobs/{id}/progress keeps a relay-free sweep off the staleness reconciler")
    func progressKeepsAnOpenSweepAlive() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)
        let opened = try await running.env.services.getJob(id: jobID).updatedAt

        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs/\(jobID)/progress",
                         body: try! JSONEncoder().encode(JobProgressRequest(skipped: 82))))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoded = try JSONDecoder().decode(JobResponse.self, from: data)
        #expect(decoded.status == "progress")
        #expect(decoded.jobStatus == "open")

        // The two things the Sweeps tab reads off this row: the count it cannot derive
        // (a dedup skip never reaches /ingest), and a fresh `updated_at` so the 90s
        // reconciler leaves a live-but-quiet sweep alone.
        let job = try await running.env.services.getJob(id: jobID)
        #expect(job.skippedCount == 82)
        #expect(job.updatedAt > opened)
        #expect(job.status == .open)
    }

    @Test("a ping cannot reopen a job the user paused mid-sweep")
    func progressNeverResurrects() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let jobID = try await createJob(running)
        try await running.env.services.setJobStatus(jobID: jobID, to: .paused)

        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs/\(jobID)/progress",
                         body: try! JSONEncoder().encode(JobProgressRequest(skipped: 5))))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // The sweep learns of the pause from the reply rather than undoing it.
        let decoded = try JSONDecoder().decode(JobResponse.self, from: data)
        #expect(decoded.jobStatus == "paused")
        #expect(try await running.env.services.getJob(id: jobID).status == .paused)
    }

    @Test("progress for an absent job → 404, and the route is token-gated like the rest")
    func progressAbsentAndGated() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let (_, absent) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs/\(UUID())/progress", body: Data()))
        #expect((absent as? HTTPURLResponse)?.statusCode == 404)

        let jobID = try await createJob(running)
        let (_, untokened) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs/\(jobID)/progress",
                         token: nil, body: Data()))
        #expect((untokened as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test("known-sources for an absent job → 404")
    func knownSourcesAbsent() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "GET", path: "/jobs/\(UUID())/known-sources"))
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("every /jobs route is gated by CaptureAuth: no token → 403")
    func jobsRequireToken() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/jobs", token: nil,
                         body: try! JSONEncoder().encode(CreateJobRequest(platform: "pinterest"))))
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test("OPTIONS /jobs preflight → 204 and Allow-Methods includes GET")
    func jobsPreflightAllowsGet() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "OPTIONS", path: "/jobs", token: nil))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Methods")?.contains("GET") == true)
    }
}
