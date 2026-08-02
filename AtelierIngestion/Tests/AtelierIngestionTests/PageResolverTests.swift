// AtelierIngestion — page resolver tests (001 · C2b)
//
// Two halves: the PURE og-tag parser over committed HTML strings (og:image
// present/absent/relative, title/description fallbacks, entity decode, malformed
// input), and the GUARDED FETCH driven through a per-URL `URLProtocol` stub + an
// injected `SSRFGuard` — the security matrix (SSRF on the initial url AND on a
// redirect hop, manual redirect following, redirect cap, non-HTML, non-2xx, body
// cap). No real network anywhere.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("PageResolver — og-tag parser")
struct PageResolverParseTests {

    private let base = URL(string: "https://example.com/article")!

    @Test("extracts og:title / og:description / absolute og:image") func ogTags() {
        let html = """
        <html><head>
          <meta property="og:title" content="A Reference">
          <meta property="og:description" content="A short blurb.">
          <meta property="og:image" content="https://cdn.example.com/card.jpg">
        </head></html>
        """
        let page = PageResolver.parse(html: html, baseURL: base)
        #expect(page.title == "A Reference")
        #expect(page.description == "A short blurb.")
        #expect(page.imageURL == URL(string: "https://cdn.example.com/card.jpg"))
    }

    @Test("a RELATIVE og:image resolves against the (final) page URL") func relativeImage() {
        let html = #"<meta property="og:image" content="/img/card.png">"#
        let page = PageResolver.parse(html: html, baseURL: base)
        #expect(page.imageURL == URL(string: "https://example.com/img/card.png"))
    }

    @Test("falls back: twitter:* then <title> / meta description") func fallbacks() {
        let html = """
        <html><head>
          <title>Doc Title</title>
          <meta name="description" content="meta desc">
          <meta name="twitter:image" content="https://cdn/x.png">
        </head></html>
        """
        let page = PageResolver.parse(html: html, baseURL: base)
        #expect(page.title == "Doc Title")            // no og:title → <title>
        #expect(page.description == "meta desc")       // no og:description → meta description
        #expect(page.imageURL == URL(string: "https://cdn/x.png")) // twitter:image
    }

    @Test("the FIRST og:image wins; attribute order + single quotes are handled") func firstWinsAndQuoting() {
        let html = """
        <meta content='https://cdn/first.png' property='og:image'>
        <meta property="og:image" content="https://cdn/second.png">
        """
        #expect(PageResolver.parse(html: html, baseURL: base).imageURL
            == URL(string: "https://cdn/first.png"))
    }

    @Test("HTML entities in content are decoded") func entities() {
        let html = #"<meta property="og:title" content="Foo &amp; Bar &#39;quoted&#39;">"#
        #expect(PageResolver.parse(html: html, baseURL: base).title == "Foo & Bar 'quoted'")
    }

    @Test("a page with no tags → an all-nil result (never throws)") func noTags() {
        let page = PageResolver.parse(html: "<html><body>hi</body></html>", baseURL: base)
        #expect(page == ResolvedPage(title: nil, description: nil, imageURL: nil))
    }

    @Test("an empty / whitespace og:image is ignored (no bogus URL)") func emptyImage() {
        let html = #"<meta property="og:image" content="   ">"#
        #expect(PageResolver.parse(html: html, baseURL: base).imageURL == nil)
    }

    @Test("auth-walled hosts (x/twitter/instagram/pinterest/facebook/rednote + subdomains) are flagged")
    func authWalled() {
        for host in ["https://x.com/a/status/1", "https://twitter.com/a", "https://mobile.twitter.com/a",
                     "https://www.instagram.com/p/x", "https://pinterest.com/pin/1", "https://www.facebook.com/x",
                     "https://rednote.com/board/1", "https://www.rednote.com/explore/abc123",
                     "https://xiaohongshu.com/board/1", "https://www.xiaohongshu.com/explore/abc123"] {
            #expect(PageResolver.isAuthWalledHost(URL(string: host)!), "\(host) should be walled")
        }
        // A generic public page is NOT walled → the app resolves it.
        #expect(!PageResolver.isAuthWalledHost(URL(string: "https://example.com/article")!))
        #expect(!PageResolver.isAuthWalledHost(URL(string: "https://dribbble.com/shots/1")!))
        // Not fooled by the brand appearing elsewhere in the host.
        #expect(!PageResolver.isAuthWalledHost(URL(string: "https://x.com.evil.test/a")!))
        #expect(!PageResolver.isAuthWalledHost(URL(string: "https://rednote.com.evil.test/a")!))
    }
}

@Suite("PageResolver — guarded fetch (SSRF)", .serialized)
struct PageResolverFetchTests {

    private let pageURL = URL(string: "https://example.com/article")!

    /// A resolver over the per-URL stub + a guard that maps specific hosts to
    /// private IPs (everything else resolves to a public IP → allowed).
    private func resolver(privateHosts: Set<String> = []) -> PageResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageStubURLProtocol.self]
        let guardImpl = SSRFGuard { host in privateHosts.contains(host) ? ["10.0.0.5"] : ["93.184.216.34"] }
        return PageResolver(configuration: config, guard: guardImpl, maxRedirects: 3, maxByteCount: 64)
    }

    private func htmlBody(_ title: String) -> Data {
        Data(#"<meta property="og:title" content="\#(title)">"#.utf8)
    }

    @Test("a 200 HTML page is fetched + parsed") func happyPath() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"], body: htmlBody("Hello"))
        let page = try await resolver().resolve(pageURL)
        #expect(page.title == "Hello")
    }

    @Test("a redirect is followed MANUALLY and the final page parsed") func followsRedirect() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 302,
            headers: ["Location": "https://example.com/final"], body: Data())
        PageStubURLProtocol.stub("https://example.com/final", status: 200,
            headers: ["Content-Type": "text/html"], body: htmlBody("Final"))
        let page = try await resolver().resolve(pageURL)
        #expect(page.title == "Final")
    }

    @Test("a redirect to a PRIVATE host is blocked at the hop (SSRF)") func redirectToPrivateBlocked() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 302,
            headers: ["Location": "http://internal.corp/latest/meta-data"], body: Data())
        await #expect(throws: SSRFError.blockedAddress("10.0.0.5")) {
            _ = try await resolver(privateHosts: ["internal.corp"]).resolve(pageURL)
        }
    }

    @Test("the INITIAL url is SSRF-validated too") func initialBlocked() async throws {
        PageStubURLProtocol.reset()
        let internalURL = URL(string: "http://internal.corp/")!
        await #expect(throws: SSRFError.blockedAddress("10.0.0.5")) {
            _ = try await resolver(privateHosts: ["internal.corp"]).resolve(internalURL)
        }
    }

    @Test("a non-http(s) scheme is refused by the guard") func rejectsScheme() async throws {
        await #expect(throws: SSRFError.invalidScheme) {
            _ = try await resolver().resolve(URL(string: "file:///etc/passwd")!)
        }
    }

    @Test("too many redirects → .tooManyRedirects") func redirectCap() async throws {
        PageStubURLProtocol.reset()
        // A loop of redirects that never terminates within the cap.
        for i in 0...5 {
            PageStubURLProtocol.stub("https://example.com/r\(i)", status: 302,
                headers: ["Location": "https://example.com/r\(i + 1)"], body: Data())
        }
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 302,
            headers: ["Location": "https://example.com/r0"], body: Data())
        await #expect(throws: PageResolveError.tooManyRedirects) {
            _ = try await resolver().resolve(pageURL)
        }
    }

    @Test("a non-HTML content-type → .notHTML (nothing to scrape)") func rejectsNonHTML() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 200,
            headers: ["Content-Type": "application/pdf"], body: Data([0x25, 0x50]))
        await #expect(throws: PageResolveError.notHTML("application/pdf")) {
            _ = try await resolver().resolve(pageURL)
        }
    }

    @Test("a non-2xx status → .httpStatus") func rejectsNon2xx() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 404,
            headers: ["Content-Type": "text/html"], body: Data("nope".utf8))
        await #expect(throws: PageResolveError.httpStatus(404)) {
            _ = try await resolver().resolve(pageURL)
        }
    }

    @Test("a body over the cap → .tooLarge") func rejectsOverCap() async throws {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.stub(pageURL.absoluteString, status: 200,
            headers: ["Content-Type": "text/html"], body: Data(repeating: 0x41, count: 128)) // > 64 cap
        await #expect(throws: PageResolveError.self) {
            _ = try await resolver().resolve(pageURL)
        }
    }
}

// MARK: - per-URL URLProtocol stub

/// Answers each request from a URL→response map (so a redirect's `Location` gets its
/// own canned response). An unmapped URL fails the request. Process-wide, so the
/// suites that use it are `.serialized`.
final class PageStubURLProtocol: URLProtocol {
    struct Stub { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var responses: [String: Stub] = [:]

    static func reset() { responses = [:] }
    static func stub(_ url: String, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        responses[url] = Stub(status: status, headers: headers, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client else { return }
        guard let stub = PageStubURLProtocol.responses[request.url?.absoluteString ?? ""] else {
            client.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: stub.body)
        client.urlProtocolDidFinishLoading(self)
    }
}
