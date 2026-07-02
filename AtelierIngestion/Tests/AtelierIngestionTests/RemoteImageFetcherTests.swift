// AtelierIngestion — remote image download tests (backlog B1)
//
// The whole fetcher is exercised WITHOUT the network: a `URLProtocol` stub feeds
// each test a canned response (bytes + HTTP status + Content-Type), and the
// fetcher runs against a `URLSession` configured to use only that stub. The suite
// is `.serialized` because the stub's response handler is a single process-wide
// hook (`URLProtocol` gives no per-session storage) — running these tests one at
// a time keeps that hook unambiguous while the rest of the target still
// parallelizes.
//
// Coverage: the three paths B1 names — IMAGE (real PNG bytes → RemoteImage),
// NON-IMAGE (an HTML page → `.notAnImage`, NOT scraped), NETWORK ERROR
// (transport failure → `.requestFailed`) — plus the guards (non-http URL, non-2xx
// status, over-cap body) and the reader path (URL → a `.web` `IngestInput`).

import Foundation
import Testing
import UniformTypeIdentifiers

import AtelierCore
@testable import AtelierIngestion

@Suite("RemoteImageFetcher", .serialized)
struct RemoteImageFetcherTests {

    static let collectionID = UUID()
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let imageURL = URL(string: "https://i.pinimg.com/originals/ab/cd/ref.jpg")!

    /// A `URLSession` wired to `StubURLProtocol` only — no real network.
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Image path

    @Test("fetch a direct image URL → RemoteImage with the sniffed MIME/extension")
    func fetchImage() async throws {
        let png = try FixtureImages.solidImage(width: 12, height: 8, format: .png)
        StubURLProtocol.respond(status: 200, contentType: "image/png", body: png)
        let fetcher = RemoteImageFetcher(session: makeSession())

        let image = try await fetcher.fetch(Self.imageURL)

        #expect(image.data == png)
        // Type comes from the BYTES (ImageIO), not the header.
        #expect(image.mimeType == "image/png")
        #expect(image.fileExtension == "png")
    }

    @Test("a mislabeled Content-Type is ignored — bytes decide the type")
    func fetchImageIgnoresWrongContentType() async throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)
        // Server lies and calls PNG bytes "application/octet-stream".
        StubURLProtocol.respond(status: 200, contentType: "application/octet-stream", body: png)
        let fetcher = RemoteImageFetcher(session: makeSession())

        let image = try await fetcher.fetch(Self.imageURL)
        #expect(image.mimeType == "image/png")
    }

    // MARK: - Non-image path

    @Test("fetch a URL that returns an HTML page → .notAnImage (not scraped)")
    func fetchNonImageHTML() async throws {
        let html = Data("<!doctype html><html><body>a page, not an image</body></html>".utf8)
        StubURLProtocol.respond(status: 200, contentType: "text/html", body: html)
        let fetcher = RemoteImageFetcher(session: makeSession())

        await #expect(throws: RemoteImageFetchError.notAnImage(mime: "text/html")) {
            _ = try await fetcher.fetch(Self.imageURL)
        }
    }

    // MARK: - Network error path

    @Test("a transport failure → .requestFailed")
    func fetchNetworkError() async throws {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        let fetcher = RemoteImageFetcher(session: makeSession())

        await #expect(throws: RemoteImageFetchError.requestFailed) {
            _ = try await fetcher.fetch(Self.imageURL)
        }
    }

    // MARK: - Guards

    @Test("a non-http URL → .invalidURL (no request made)")
    func rejectsNonHTTPURL() async throws {
        let fetcher = RemoteImageFetcher(session: makeSession())
        let fileURL = URL(fileURLWithPath: "/tmp/ref.png")

        await #expect(throws: RemoteImageFetchError.invalidURL) {
            _ = try await fetcher.fetch(fileURL)
        }
    }

    @Test("a non-2xx status → .httpStatus")
    func rejectsNon2xx() async throws {
        StubURLProtocol.respond(status: 404, contentType: "text/plain", body: Data("nope".utf8))
        let fetcher = RemoteImageFetcher(session: makeSession())

        await #expect(throws: RemoteImageFetchError.httpStatus(404)) {
            _ = try await fetcher.fetch(Self.imageURL)
        }
    }

    @Test("a body over the byte cap → .tooLarge")
    func rejectsOverCap() async throws {
        let png = try FixtureImages.solidImage(width: 64, height: 64, format: .png)
        StubURLProtocol.respond(status: 200, contentType: "image/png", body: png)
        // A cap far below the real body size.
        let fetcher = RemoteImageFetcher(session: makeSession(), maxByteCount: 8)

        await #expect(throws: RemoteImageFetchError.tooLarge(bytes: png.count)) {
            _ = try await fetcher.fetch(Self.imageURL)
        }
    }

    // MARK: - Reader path (URL → IngestInput)

    @Test("ingestInput turns a bare image URL into a .web IngestInput")
    func ingestInputWebProvenance() async throws {
        let png = try FixtureImages.solidImage(width: 10, height: 10, format: .png)
        StubURLProtocol.respond(status: 200, contentType: "image/png", body: png)
        let fetcher = RemoteImageFetcher(session: makeSession())

        let input = try await fetcher.ingestInput(
            for: Self.imageURL, into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .web)
        #expect(input.provenance.originalURL == Self.imageURL.absoluteString)
        #expect(input.provenance.capturedAt == Self.capturedAt)
        #expect(input.collectionID == Self.collectionID)
        // The downloaded bytes ride in-memory.
        if case .data(let d) = input.source {
            #expect(d == png)
        } else {
            Issue.record("expected .data source carrying the downloaded bytes")
        }
    }
}

// MARK: - URLProtocol stub

/// A process-wide `URLProtocol` that answers every request with a canned response
/// (or a canned transport error). Only a `URLSession` configured with it in
/// `protocolClasses` routes through it, so it never affects the real network. The
/// response is set per-test; the enclosing suite is `.serialized` so there is only
/// ever one pending response at a time.
final class StubURLProtocol: URLProtocol {

    /// What the stub should do for the next request. `nonisolated(unsafe)` because
    /// `URLProtocol` reads it on URLSession's own threads; the `.serialized` suite
    /// guarantees no two tests set/read it concurrently.
    enum Outcome {
        case response(status: Int, contentType: String, body: Data)
        case failure(Error)
    }
    nonisolated(unsafe) static var outcome: Outcome?

    static func respond(status: Int, contentType: String, body: Data) {
        outcome = .response(status: status, contentType: contentType, body: body)
    }
    static func fail(with error: Error) {
        outcome = .failure(error)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client = client else { return }
        switch StubURLProtocol.outcome {
        case .response(let status, let contentType, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client.urlProtocol(self, didFailWithError: error)
        case nil:
            client.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }
}
