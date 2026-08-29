// AtelierServer — the auth + CORS gate (build-order #6, decisions A2 + CQ3).
//
// A localhost server is reachable by ANY process on the machine, including any
// web page via `fetch('http://127.0.0.1:PORT')`. Loopback binding is NOT
// isolation. Two independent barriers defend the endpoint:
//
//   1. Origin allowlist — the browser sets `Origin`, and a web page cannot forge
//      a `chrome-extension://` origin, so a drive-by page (Origin `https://…`) is
//      rejected. This is what actually blocks browser-based abuse: our CORS reply
//      only names the extension origin, so a foreign page's preflight fails and
//      the real request never fires.
//   2. Shared-secret token — a non-browser local process (curl, another app)
//      sends no forbidden Origin, so it must present the secret token to pass.
//
// This type is PURE (no FlyingFox, no sockets): it decides from a
// ``RequestContext`` and produces CORS headers, so the whole negative-path
// matrix (missing/wrong token, foreign origin, preflight) is unit-tested (T2).

import Foundation

import AtelierCapture

/// The fields of an inbound request the gate reasons about.
public struct RequestContext: Equatable, Sendable {
    /// Uppercased HTTP method, e.g. `"POST"`, `"OPTIONS"`.
    public let method: String
    /// The `Origin` header, if the client sent one (browsers always do).
    public let origin: String?
    /// The shared-secret token header, if present.
    public let token: String?

    public init(method: String, origin: String?, token: String?) {
        self.method = method
        self.origin = origin
        self.token = token
    }
}

/// The gate's verdict for a request.
public enum AuthDecision: Equatable, Sendable {
    /// A CORS preflight from an allowed origin → answer 204 + CORS headers so the
    /// real request may follow. (Preflights never carry the token.)
    case preflight
    /// Passed both barriers → dispatch to the route.
    case authorized
    /// Blocked → 403 with this reason.
    case rejected(reason: String)
}

/// The shared-secret + origin gate.
public struct CaptureAuth: Sendable {
    /// The request header carrying the shared secret.
    public static let tokenHeaderName = "X-Atelier-Token"

    private let token: String
    /// When set, only this exact extension id is allowed; when `nil`, any
    /// `chrome-extension://` origin is accepted (dev-friendly — the unpacked
    /// extension's id churns; the token remains the real secret).
    private let pinnedExtensionID: String?

    public init(token: String, pinnedExtensionID: String? = nil) {
        self.token = token
        self.pinnedExtensionID = pinnedExtensionID
    }

    /// Whether `origin` is an acceptable caller. An **absent** origin (a
    /// non-browser client) is allowed *here* — such a client is still stopped by
    /// the token check. A present origin must be the extension's.
    public func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard origin.hasPrefix("chrome-extension://") else { return false }
        if let pinnedExtensionID {
            return origin == "chrome-extension://\(pinnedExtensionID)"
        }
        return true
    }

    /// Decide a request. Order: origin barrier → preflight short-circuit → token
    /// barrier.
    public func evaluate(_ ctx: RequestContext) -> AuthDecision {
        guard isAllowedOrigin(ctx.origin) else {
            return .rejected(reason: "Origin not allowed.")
        }
        // A preflight (OPTIONS) never carries custom headers, so it can't present
        // the token; approve it on the origin alone. The CORS reply then lets the
        // real, token-bearing request through.
        if ctx.method == "OPTIONS" {
            return .preflight
        }
        guard let provided = ctx.token,
              Self.constantTimeEquals(provided, token) else {
            return .rejected(reason: "Missing or invalid token.")
        }
        return .authorized
    }

    /// CORS headers for a reply to `origin`. `Access-Control-Allow-Origin` echoes
    /// the caller's origin only when allowed (never `*`), so foreign pages get no
    /// permissive ACAO. Always names the token + content-type headers and the two
    /// methods, so the preflight authorizes the real POST.
    public func corsHeaders(origin: String?) -> [String: String] {
        var headers = [
            // GET covers the bulk-import `known-sources` route; its custom token
            // header makes it a preflighted request, so GET must be allow-listed.
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers":
                "Content-Type, \(Self.tokenHeaderName), \(CaptureDecoder.provenanceHeaderName)",
            "Access-Control-Max-Age": "600",
            "Vary": "Origin",
        ]
        if let origin, isAllowedOrigin(origin) {
            headers["Access-Control-Allow-Origin"] = origin
        }
        return headers
    }

    /// Length-independent-of-content comparison, to avoid leaking the token via
    /// response timing. Compares full byte buffers; unequal lengths still fold
    /// every byte before returning.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        let n = max(x.count, y.count)
        var i = 0
        while i < n {
            let xb = i < x.count ? x[i] : 0
            let yb = i < y.count ? y[i] : 0
            diff |= xb ^ yb
            i += 1
        }
        return diff == 0
    }
}
