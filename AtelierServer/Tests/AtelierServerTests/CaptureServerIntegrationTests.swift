// AtelierServer — socket integration tests (build-order #6, decision T1).
//
// A thin layer that binds a REAL listener on an ephemeral port (0) and round-
// trips over HTTP via URLSession, proving the wire, the CORS preflight, the auth
// rejections, and the body-size cap actually work end to end.
//
// CAVEAT (documented in the plan): `swift test` runs UNSANDBOXED, so these prove
// the HTTP/CORS/handler logic but NOT that the signed, sandboxed app can bind
// with `com.apple.security.network.server` — that stays a manual app check.

import Foundation
import Testing

import AtelierCore
@testable import AtelierServer

@Suite("CaptureServer (socket)")
struct CaptureServerIntegrationTests {
    static let token = "integration-token"
    static let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

    /// A running server bound to an ephemeral port, wired to a temp library.
    private struct Running {
        let server: CaptureServer
        let env: ServerTestEnv
        let port: UInt16
    }

    private func start(maxBodyBytes: Int = CaptureServer.defaultMaxBodyBytes) async throws -> Running {
        let env = try await makeServerTestEnv()
        let target = env.collectionID
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { target })
        let server = CaptureServer(
            port: 0,
            auth: CaptureAuth(token: Self.token),
            routes: routes,
            maxBodyBytes: maxBodyBytes)
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

    @Test("valid POST /ingest over the socket → 200 + asset persisted")
    func validPost() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let body = CaptureRequest.sample(collectionId: running.env.collectionID).jsonData()

        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/ingest", body: body))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(CaptureResponse.self, from: data)
        #expect(decoded.status == "ingested")
        #expect(try await running.env.items().count == 1)
    }

    @Test("OPTIONS /ingest preflight → 204 + Access-Control-Allow-Origin echoes the origin")
    func preflight() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }

        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "OPTIONS", path: "/ingest", token: nil))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == Self.origin)
    }

    @Test("POST without token → 403")
    func missingToken() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let body = CaptureRequest.sample(collectionId: running.env.collectionID).jsonData()

        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/ingest", token: nil, body: body))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 403)
        #expect(try await running.env.items().isEmpty)
    }

    @Test("POST from a foreign origin → 403 (origin barrier)")
    func foreignOrigin() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }
        let body = CaptureRequest.sample(collectionId: running.env.collectionID).jsonData()

        let (data, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/ingest",
                         origin: "https://evil.example", body: body))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 403)
        let decoded = try JSONDecoder().decode(CaptureResponse.self, from: data)
        #expect(decoded.error?.contains("Origin") == true)
        #expect(try await running.env.items().isEmpty)
    }

    @Test("body larger than the cap → 413")
    func oversizedBody() async throws {
        // Tiny cap so a normal capture body trips it.
        let running = try await start(maxBodyBytes: 10)
        defer { Task { await running.server.stop() } }
        let body = CaptureRequest.sample(collectionId: running.env.collectionID).jsonData()

        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "POST", path: "/ingest", body: body))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 413)
    }

    @Test("GET /health with a valid token → 200")
    func health() async throws {
        let running = try await start(); defer { Task { await running.server.stop() } }

        let (_, response) = try await URLSession.shared.data(
            for: request(running, method: "GET", path: "/health"))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
    }
}
