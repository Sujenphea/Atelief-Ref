// AtelierCapture tests — the wall around a page-chosen URL (098 · finding 2, P5).
//
// The share extension has no test host, so tier 2's fetch was written as three pure
// decisions in ``MediaFetchPolicy`` and a thin `URLSession` glue that hangs them on
// delegate callbacks. This file is the decisions. The glue — which delegate method, and
// when `URLSession` calls it — is not covered here and is not covered anywhere: it is
// named in `MediaFetcher`'s own header and in the changelog as untested.
//
// The matrix is deliberately broad for the same reason `SSRFGuardTests`' is: a miss in the
// candidate check or the redirect check is an SSRF hole, and a miss in `acceptsFetched` is
// an unbounded body landing in a process with a ~120 MB ceiling. The guard's resolver is
// injected throughout, so nothing here touches DNS.

import Foundation
import Testing

import AtelierCapture

@Suite("Tier-2 media fetch policy (098 · finding 2)")
struct MediaFetchPolicyTests {

    /// A guard whose DNS is a fixed host→IPs map (no real network) — `SSRFGuardTests`' rig.
    private func guarded(_ map: [String: [String]]) -> SSRFGuard {
        SSRFGuard { host in map[host] ?? [] }
    }

    /// The one public host every "this is allowed" case resolves through.
    private var publicCDN: SSRFGuard {
        guarded([
            "cdn.example.com": ["93.184.216.34"],
            "images.example.com": ["93.184.216.34"],
            "evil.example.com": ["93.184.216.34"],
        ])
    }

    // MARK: - The candidate

    @Test("a public http(s) candidate is fetchable")
    func publicCandidatePasses() throws {
        let url = try ShareCapture.fetchableURL(
            for: "https://cdn.example.com/a.jpg", through: publicCDN)
        #expect(url.absoluteString == "https://cdn.example.com/a.jpg")
    }

    @Test(
        "a candidate whose host resolves anywhere internal is refused, and names the address",
        arguments: [
            ("127.0.0.1", "loopback"),
            ("169.254.169.254", "the metadata endpoint"),
            ("10.1.2.3", "RFC1918"),
            ("192.168.0.9", "a home router"),
            ("::1", "IPv6 loopback"),
            ("fd00::1", "a ULA"),
        ])
    func privateCandidateIsRefused(address: String, why: String) {
        let ssrf = guarded(["cdn.example.com": [address]])
        #expect(throws: MediaFetchRefusal.blockedHost(.blockedAddress(address))) {
            try ShareCapture.fetchableURL(for: "https://cdn.example.com/a.jpg", through: ssrf)
        }
    }

    @Test("one private address among public ones still refuses the whole host")
    func mixedRecordsAreRefused() {
        let ssrf = guarded(["cdn.example.com": ["93.184.216.34", "127.0.0.1"]])
        #expect(throws: MediaFetchRefusal.blockedHost(.blockedAddress("127.0.0.1"))) {
            try ShareCapture.fetchableURL(for: "https://cdn.example.com/a.jpg", through: ssrf)
        }
    }

    @Test("an IP-literal candidate is classified without DNS")
    func ipLiteralCandidate() {
        // The resolver would answer for nothing here, so a pass proves no lookup happened.
        let ssrf = guarded([:])
        #expect(throws: MediaFetchRefusal.blockedHost(.blockedAddress("127.0.0.1"))) {
            try ShareCapture.fetchableURL(for: "http://127.0.0.1/a.jpg", through: ssrf)
        }
        #expect(throws: Never.self) {
            try ShareCapture.fetchableURL(for: "https://93.184.216.34/a.jpg", through: ssrf)
        }
    }

    @Test("an unresolvable host is refused rather than attempted")
    func unresolvableCandidate() {
        #expect(throws: MediaFetchRefusal.blockedHost(.unresolvable("gone.example.com"))) {
            try ShareCapture.fetchableURL(
                for: "https://gone.example.com/a.jpg", through: guarded([:]))
        }
    }

    @Test(
        "the guard re-checks the scheme the extractor already filtered",
        arguments: [
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "ftp://cdn.example.com/a.jpg",
        ])
    func nonWebSchemesAreRefusedAgain(candidate: String) {
        // `mediaCandidates` drops these first; the guard is a boundary and does not trust
        // that it was called after a filter.
        #expect(throws: MediaFetchRefusal.blockedHost(.invalidScheme)) {
            try ShareCapture.fetchableURL(for: candidate, through: publicCDN)
        }
    }

    @Test(
        "a string that is not a URL is refused before any resolution",
        arguments: ["", "   ", "http://"])
    func malformedCandidate(candidate: String) {
        #expect(throws: (any Error).self) {
            try ShareCapture.fetchableURL(for: candidate, through: guarded([:]))
        }
    }

    // MARK: - The redirect

    @Test("a hop to another public https host is followed")
    func publicRedirectIsFollowed() throws {
        let next = try ShareCapture.redirectTarget(
            from: URL(string: "https://cdn.example.com/a.jpg")!,
            to: URL(string: "https://images.example.com/a.jpg")!,
            through: publicCDN)
        #expect(next.host == "images.example.com")
    }

    @Test(
        "a hop to a private, loopback or link-local host is refused",
        arguments: [
            "http://127.0.0.1/a.jpg",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/a.jpg",
            "http://10.0.0.1/a.jpg",
        ])
    func redirectToAnInternalHostIsRefused(target: String) {
        // The initial host is entirely public and passes — which is the whole shape of the
        // attack: the interesting address is the one the server hands back.
        #expect(throws: (any Error).self) {
            try ShareCapture.redirectTarget(
                from: URL(string: "http://evil.example.com/a.jpg")!,
                to: URL(string: target)!,
                through: publicCDN)
        }
    }

    @Test("a hop from https to http is refused even when the host is public")
    func httpsDowngradeIsRefused() {
        #expect(throws: MediaFetchRefusal.insecureRedirect) {
            try ShareCapture.redirectTarget(
                from: URL(string: "https://cdn.example.com/a.jpg")!,
                to: URL(string: "http://cdn.example.com/a.jpg")!,
                through: publicCDN)
        }
    }

    @Test("the other three scheme transitions are allowed")
    func onlyTheDowngradeIsRefused() throws {
        let hops = [
            ("https://cdn.example.com/a", "https://images.example.com/a"),
            ("http://cdn.example.com/a", "http://images.example.com/a"),
            ("http://cdn.example.com/a", "https://images.example.com/a"),
        ]
        for (from, to) in hops {
            #expect(throws: Never.self) {
                try ShareCapture.redirectTarget(
                    from: URL(string: from)!, to: URL(string: to)!, through: publicCDN)
            }
        }
    }

    @Test("a hop to a non-web scheme is refused")
    func redirectToANonWebSchemeIsRefused() {
        #expect(throws: MediaFetchRefusal.blockedHost(.invalidScheme)) {
            try ShareCapture.redirectTarget(
                from: URL(string: "http://evil.example.com/a.jpg")!,
                to: URL(string: "file:///etc/passwd")!,
                through: publicCDN)
        }
    }

    // MARK: - The response

    /// The table 098 · P5 asks for: status 200 / 301 / 404 against a length that is absent,
    /// at the cap, over the cap, and the `-1` `URLSession` uses for "unknown".
    @Test(
        "the response table",
        arguments: [
            // Accepted: 200 with nothing over the cap to declare.
            (200 as Int?, nil as Int64?, nil as MediaFetchRefusal?),
            (200, -1, nil),
            (200, 0, nil),
            (200, Int64(InboxWriter.maximumPayloadBytes), nil),
            (200, Int64(InboxWriter.maximumPayloadBytes) - 1, nil),
            // Refused on size — one byte past the cap is past it.
            (200, Int64(InboxWriter.maximumPayloadBytes) + 1,
             .tooLarge(bytes: Int64(InboxWriter.maximumPayloadBytes) + 1,
                       limit: InboxWriter.maximumPayloadBytes)),
            (200, 4_000_000_000,
             .tooLarge(bytes: 4_000_000_000, limit: InboxWriter.maximumPayloadBytes)),
            // Refused on status. A 301 here is a redirect that was NOT followed.
            (301, nil, .httpStatus(301)),
            (404, nil, .httpStatus(404)),
            (500, -1, .httpStatus(500)),
            // Size beats status, which is the order the replaced code used.
            (404, 4_000_000_000,
             .tooLarge(bytes: 4_000_000_000, limit: InboxWriter.maximumPayloadBytes)),
            // Not an HTTP response at all: no status to object to.
            (nil, nil, nil),
            (nil, Int64(InboxWriter.maximumPayloadBytes) + 1,
             .tooLarge(bytes: Int64(InboxWriter.maximumPayloadBytes) + 1,
                       limit: InboxWriter.maximumPayloadBytes)),
        ])
    func responseTable(status: Int?, length: Int64?, refusal: MediaFetchRefusal?) {
        if let refusal {
            #expect(throws: refusal) {
                try ShareCapture.acceptsFetched(length: length, status: status)
            }
        } else {
            #expect(throws: Never.self) {
                try ShareCapture.acceptsFetched(length: length, status: status)
            }
        }
    }

    @Test("the cap this predicate enforces is the inbox's own, not a second number")
    func theCapIsTheWritersCap() {
        // If `InboxWriter.maximumPayloadBytes` moves, this predicate moves with it — a
        // fetch that accepted what the writer then refused would spend the whole budget
        // downloading a file that could never be written.
        #expect(throws: MediaFetchRefusal.tooLarge(
            bytes: Int64(InboxWriter.maximumPayloadBytes) + 1,
            limit: InboxWriter.maximumPayloadBytes)) {
            try ShareCapture.acceptsFetched(
                length: Int64(InboxWriter.maximumPayloadBytes) + 1, status: 200)
        }
    }
}
