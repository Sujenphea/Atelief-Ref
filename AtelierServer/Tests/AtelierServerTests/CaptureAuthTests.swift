// AtelierServer — auth + CORS gate tests (build-order #6, decision T2).
//
// The security gate is worthless if only the happy path is tested, so the whole
// negative-path matrix is asserted: missing/wrong token, foreign origin,
// preflight, pinned-id mismatch, plus the CORS header shape and the constant-time
// compare. All pure — no socket.

import Testing
@testable import AtelierServer

@Suite("CaptureAuth")
struct CaptureAuthTests {
    static let token = "s3cr3t-token"
    static let extOrigin = "chrome-extension://abcdefghijklmnop"
    let auth = CaptureAuth(token: token)

    private func ctx(
        method: String = "POST", origin: String? = extOrigin, token: String? = token
    ) -> RequestContext {
        RequestContext(method: method, origin: origin, token: token)
    }

    // MARK: - evaluate

    @Test("POST + extension origin + correct token → authorized")
    func authorizedHappyPath() {
        #expect(auth.evaluate(ctx()) == .authorized)
    }

    @Test("missing token → rejected")
    func missingToken() {
        #expect(auth.evaluate(ctx(token: nil)) == .rejected(reason: "Missing or invalid token."))
    }

    @Test("wrong token → rejected")
    func wrongToken() {
        #expect(auth.evaluate(ctx(token: "nope")) == .rejected(reason: "Missing or invalid token."))
    }

    @Test("foreign web origin → rejected (before token is even considered)")
    func foreignOrigin() {
        let decision = auth.evaluate(ctx(origin: "https://evil.example", token: Self.token))
        #expect(decision == .rejected(reason: "Origin not allowed."))
    }

    @Test("OPTIONS from allowed origin → preflight (no token required)")
    func preflightAllowed() {
        #expect(auth.evaluate(ctx(method: "OPTIONS", token: nil)) == .preflight)
    }

    @Test("OPTIONS from a foreign origin → rejected (origin barrier first)")
    func preflightForeign() {
        let decision = auth.evaluate(ctx(method: "OPTIONS", origin: "https://evil.example", token: nil))
        #expect(decision == .rejected(reason: "Origin not allowed."))
    }

    @Test("absent origin (non-browser client) + correct token → authorized")
    func absentOriginWithToken() {
        #expect(auth.evaluate(ctx(origin: nil)) == .authorized)
    }

    @Test("absent origin + no token → rejected (token still required)")
    func absentOriginNoToken() {
        #expect(auth.evaluate(ctx(origin: nil, token: nil)) == .rejected(reason: "Missing or invalid token."))
    }

    // MARK: - Pinned extension id

    @Test("pinned id: exact match allowed, mismatch rejected")
    func pinnedID() {
        let pinned = CaptureAuth(token: Self.token, pinnedExtensionID: "abcdefghijklmnop")
        #expect(pinned.evaluate(ctx()) == .authorized)
        let other = RequestContext(
            method: "POST", origin: "chrome-extension://zzzzzzzzzzzzzzzz", token: Self.token)
        #expect(pinned.evaluate(other) == .rejected(reason: "Origin not allowed."))
    }

    // MARK: - Origin schemes as data (3A)

    /// Safari's wrapper of the same extension. The id in its origin is a WRAPPER
    /// UUID, unrelated to the Chrome extension id — which is why the pin below
    /// must not apply to it.
    static let safariOrigin = "safari-web-extension://11112222-3333-4444-5555-666677778888"
    static let bothSchemes = ["chrome-extension", "safari-web-extension"]

    @Test("a listed second scheme is accepted")
    func secondSchemeAllowed() {
        let auth = CaptureAuth(token: Self.token, allowedOriginSchemes: Self.bothSchemes)
        #expect(auth.evaluate(ctx(origin: Self.safariOrigin)) == .authorized)
        // …and the first scheme still is.
        #expect(auth.evaluate(ctx()) == .authorized)
    }

    @Test("an unlisted scheme is rejected")
    func unlistedSchemeRejected() {
        // The default allowlist is Chrome's alone, so Safari's origin is foreign.
        #expect(auth.evaluate(ctx(origin: Self.safariOrigin))
            == .rejected(reason: "Origin not allowed."))
        // And a listed-Safari gate rejects Chrome, proving the list is the rule
        // rather than a superset that happens to contain everything.
        let safariOnly = CaptureAuth(
            token: Self.token, allowedOriginSchemes: ["safari-web-extension"])
        #expect(safariOnly.evaluate(ctx()) == .rejected(reason: "Origin not allowed."))
    }

    @Test("the pinned extension id does not apply to the second scheme")
    func pinDoesNotApplyToSecondScheme() {
        let pinned = CaptureAuth(
            token: Self.token,
            allowedOriginSchemes: Self.bothSchemes,
            pinnedExtensionID: "abcdefghijklmnop")
        // Chrome is still pinned…
        #expect(pinned.evaluate(ctx()) == .authorized)
        #expect(pinned.evaluate(ctx(origin: "chrome-extension://zzzzzzzzzzzzzzzz"))
            == .rejected(reason: "Origin not allowed."))
        // …while Safari passes on its scheme alone, carrying a wholly different id.
        #expect(pinned.evaluate(ctx(origin: Self.safariOrigin)) == .authorized)
    }

    @Test("an origin with no :// is rejected")
    func malformedNoSeparator() {
        for origin in ["chrome-extension", "chrome-extension:/abc", "null", "abcdefghijklmnop"] {
            #expect(auth.evaluate(ctx(origin: origin))
                == .rejected(reason: "Origin not allowed."), "\(origin)")
        }
    }

    @Test("an origin with an empty scheme is rejected")
    func malformedEmptyScheme() {
        #expect(auth.evaluate(ctx(origin: "://abcdefghijklmnop"))
            == .rejected(reason: "Origin not allowed."))
    }

    @Test("a scheme-only origin is rejected")
    func malformedSchemeOnly() {
        // `hasPrefix` used to accept exactly this: the allowed scheme and nothing
        // behind it. A parse rejects it because there is no origin to allow.
        #expect(auth.evaluate(ctx(origin: "chrome-extension://"))
            == .rejected(reason: "Origin not allowed."))
    }

    @Test("an absent origin still requires the token, whatever the scheme list")
    func absentOriginWithSchemeList() {
        let auth = CaptureAuth(token: Self.token, allowedOriginSchemes: Self.bothSchemes)
        #expect(auth.evaluate(ctx(origin: nil, token: nil))
            == .rejected(reason: "Missing or invalid token."))
        #expect(auth.evaluate(ctx(origin: nil)) == .authorized)
    }

    @Test("scheme matching is case-insensitive, the rest is not")
    func schemeCaseInsensitive() {
        // RFC 3986 schemes are case-insensitive; the id after `://` is not, so a
        // pinned gate still refuses a differently-cased id.
        #expect(auth.evaluate(ctx(origin: "CHROME-EXTENSION://abcdefghijklmnop")) == .authorized)
        let pinned = CaptureAuth(token: Self.token, pinnedExtensionID: "abcdefghijklmnop")
        #expect(pinned.evaluate(ctx(origin: "chrome-extension://ABCDEFGHIJKLMNOP"))
            == .rejected(reason: "Origin not allowed."))
    }

    @Test("parseOrigin splits a scheme, and refuses the three malformed shapes")
    func parseOriginShapes() {
        let parsed = CaptureAuth.parseOrigin("chrome-extension://abc")
        #expect(parsed?.scheme == "chrome-extension")
        #expect(parsed?.rest == "abc")
        // Only the FIRST separator splits, so a path that contains one cannot
        // smuggle an allowed scheme past the check.
        #expect(CaptureAuth.parseOrigin("https://evil.example/chrome-extension://x")?.scheme
            == "https")
        #expect(CaptureAuth.parseOrigin("chrome-extension") == nil)
        #expect(CaptureAuth.parseOrigin("://abc") == nil)
        #expect(CaptureAuth.parseOrigin("chrome-extension://") == nil)
        #expect(CaptureAuth.parseOrigin("") == nil)
    }

    @Test("CORS: an origin on a listed second scheme is echoed")
    func corsSecondScheme() {
        let auth = CaptureAuth(token: Self.token, allowedOriginSchemes: Self.bothSchemes)
        #expect(auth.corsHeaders(origin: Self.safariOrigin)["Access-Control-Allow-Origin"]
            == Self.safariOrigin)
        // The default gate does not echo it.
        #expect(self.auth.corsHeaders(origin: Self.safariOrigin)["Access-Control-Allow-Origin"]
            == nil)
    }

    // MARK: - CORS headers

    @Test("CORS: allowed origin is echoed, never wildcard")
    func corsAllowedOrigin() {
        let headers = auth.corsHeaders(origin: Self.extOrigin)
        #expect(headers["Access-Control-Allow-Origin"] == Self.extOrigin)
        // GET was added for the bulk-import `known-sources` route (015 · 3A).
        #expect(headers["Access-Control-Allow-Methods"] == "GET, POST, OPTIONS")
        #expect(headers["Access-Control-Allow-Headers"]?.contains(CaptureAuth.tokenHeaderName) == true)
    }

    @Test("CORS: foreign origin gets NO Access-Control-Allow-Origin")
    func corsForeignOrigin() {
        let headers = auth.corsHeaders(origin: "https://evil.example")
        #expect(headers["Access-Control-Allow-Origin"] == nil)
    }

    // MARK: - Constant-time compare

    @Test("constantTimeEquals matches only identical strings")
    func constantTime() {
        #expect(CaptureAuth.constantTimeEquals("abc", "abc"))
        #expect(!CaptureAuth.constantTimeEquals("abc", "abd"))
        #expect(!CaptureAuth.constantTimeEquals("abc", "abcd"))
        #expect(!CaptureAuth.constantTimeEquals("", "x"))
        #expect(CaptureAuth.constantTimeEquals("", ""))
    }
}
