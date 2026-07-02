// AtelierServer — the FlyingFox transport + lifecycle (build-order #6, A1/A2/P4).
//
// The thin socket adapter over the pure logic (`CaptureAuth` + `CaptureRoutes`).
// It binds an IPv4 loopback listener — `127.0.0.1`, NOT FlyingFox's default
// `.loopback` which is IPv6 `::1` only (the extension POSTs to `http://127.0.0.1`,
// so binding `::1` would silently refuse it). A single root `HTTPHandler`
// centralizes the auth+CORS gate and body-size cap (CQ3/P1), then dispatches to
// the routes. `start()`/`stop()` own the listener's lifecycle (P4).

import Foundation
import FlyingFox
import FlyingSocks

/// A random URL-safe secret the app hands to the extension (A2).
public enum CaptureToken {
    /// 32 bytes of system randomness, hex-encoded (256-bit secret).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &rng))
        }.joined()
    }
}

/// Owns the loopback HTTP listener for the capture endpoint.
public actor CaptureServer {
    /// The fixed default port the extension hard-codes (P4). `0` lets the OS pick
    /// an ephemeral port (used by integration tests).
    public static let defaultPort: UInt16 = 47321
    /// Reject bodies larger than this (P1). 50 MB comfortably covers any single
    /// captured image while bounding worst-case memory.
    public static let defaultMaxBodyBytes = 50 * 1024 * 1024

    private let port: UInt16
    private let handler: CaptureHTTPHandler
    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?

    public init(
        port: UInt16 = CaptureServer.defaultPort,
        auth: CaptureAuth,
        routes: CaptureRoutes,
        maxBodyBytes: Int = CaptureServer.defaultMaxBodyBytes
    ) {
        self.port = port
        self.handler = CaptureHTTPHandler(
            auth: auth, routes: routes, maxBodyBytes: maxBodyBytes)
    }

    /// Bind the loopback listener and start serving. Idempotent. Throws if the
    /// port is already in use (surfaced to the caller so the app can report it).
    public func start() async throws {
        guard server == nil else { return }
        // `.inet` resolves to a concrete IPv4 `sockaddr_in` in the `address:`
        // context — 127.0.0.1, not FlyingFox's IPv6-only `.loopback`.
        let server = HTTPServer(
            address: try .inet(ip4: "127.0.0.1", port: port), handler: handler)
        self.server = server
        runTask = Task { try? await server.run() }
        do {
            try await server.waitUntilListening()
        } catch {
            // Failed to bind (e.g. port in use) — unwind so `start()` truly threw.
            runTask?.cancel()
            self.server = nil
            self.runTask = nil
            throw error
        }
    }

    /// Stop serving and release the port. Idempotent.
    public func stop() async {
        await server?.stop(timeout: 0)
        runTask?.cancel()
        server = nil
        runTask = nil
    }

    /// The actual bound port (useful when constructed with port `0`), or `nil`
    /// before `start()` completes.
    public func boundPort() async -> UInt16? {
        guard let server else { return nil }
        switch await server.listeningAddress {
        case .ip4(_, let port): return port
        case .ip6(_, let port): return port
        default: return nil
        }
    }
}

/// The single root handler: gate every request (auth + CORS + body cap), then
/// dispatch. Kept `struct` + `Sendable` so FlyingFox can fan it out safely.
struct CaptureHTTPHandler: HTTPHandler {
    let auth: CaptureAuth
    let routes: CaptureRoutes
    let maxBodyBytes: Int

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let origin = request.headers[HTTPHeader("Origin")]
        let token = request.headers[HTTPHeader(CaptureAuth.tokenHeaderName)]
        let cors = auth.corsHeaders(origin: origin)
        let ctx = RequestContext(
            method: request.method.rawValue, origin: origin, token: token)

        switch auth.evaluate(ctx) {
        case .preflight:
            return makeResponse(.noContent, cors: cors, body: nil)
        case .rejected(let reason):
            return makeResponse(.forbidden, cors: cors, body: .error(reason))
        case .authorized:
            break
        }

        // Liveness/authorized probe.
        if request.method == .GET, request.path == "/health" {
            return makeResponse(.ok, cors: cors, body: CaptureResponse(status: "ok"))
        }

        guard request.method == .POST, request.path == "/ingest" else {
            return makeResponse(.notFound, cors: cors, body: .error("Not found."))
        }

        // Body-size cap (P1): reject via Content-Length before buffering when we
        // can, then re-check the actual bytes in case the header was absent/lying.
        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader), declared > maxBodyBytes {
            return makeResponse(
                .payloadTooLarge, cors: cors, body: .error("Payload too large."))
        }
        let body = try await request.bodyData
        guard body.count <= maxBodyBytes else {
            return makeResponse(
                .payloadTooLarge, cors: cors, body: .error("Payload too large."))
        }

        let result = await routes.handleIngest(body: body, now: Date())
        return makeResponse(
            statusCode(result.statusCode), cors: cors, body: result.response)
    }

    private func makeResponse(
        _ status: HTTPStatusCode, cors: [String: String], body: CaptureResponse?
    ) -> HTTPResponse {
        var headers: [HTTPHeader: String] = [:]
        for (key, value) in cors { headers[HTTPHeader(key)] = value }
        var data = Data()
        if let body {
            headers[.contentType] = "application/json"
            data = (try? JSONEncoder().encode(body)) ?? Data()
        }
        return HTTPResponse(
            statusCode: status, headers: HTTPHeaders(headers), body: data)
    }

    /// Map the routes' plain Int status to a FlyingFox status code (routes stay
    /// FlyingFox-free so they're unit-testable without the transport).
    private func statusCode(_ code: Int) -> HTTPStatusCode {
        switch code {
        case 200: return .ok
        case 400: return .badRequest
        case 413: return .payloadTooLarge
        case 422: return .unprocessableContent
        case 500: return .internalServerError
        default: return HTTPStatusCode(code, phrase: "")
        }
    }
}
