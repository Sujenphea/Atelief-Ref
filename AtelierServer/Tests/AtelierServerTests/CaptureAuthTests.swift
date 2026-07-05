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
