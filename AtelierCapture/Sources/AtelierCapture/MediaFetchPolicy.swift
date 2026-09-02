// AtelierCapture — the wall around a page-chosen URL (098 · finding 2, P5).
//
// **What this file is for.** Tier 2's media fetch downloads a URL that a WEB PAGE named.
// The page is attacker-influenceable by construction — that is the whole premise of the
// feature, since the pages tier 2 exists for are ones the user is signed in to and a Mac
// cannot see — so the URL is exactly the input `SSRFGuard` was written for (001 · C2b).
// The Mac already walls the identical fetch. Until this file, the phone did not: 098 ·
// finding 2 found `mediaCandidates` filtering on SCHEME only, `URLSession` following
// redirects unchecked, and the byte cap applied after the whole body had landed.
//
// **Why the decisions are here and not in the extension.** The share extension has no test
// host; that is a settled constraint of this project, not an oversight. The bargain it buys
// is only defensible if the extension holds no decisions, so the three decisions in a
// walled fetch — may this candidate be requested, may this redirect hop be followed, may
// this response's body transfer — are pure functions over values, here, tested under
// `swift test` on macOS against an injected resolver. What is left in `MediaFetcher` is
// `URLSession` glue: which delegate method to hang them on. That glue is untested and says
// so in its own header.
//
// **One refusal vocabulary.** All three decisions throw the same typed error, because they
// all answer one question — is this fetch allowed to proceed — and a caller that logs three
// different enums is a caller that logs three different sentences for one condition.
//
// The guard's own limitation carries over unchanged and is worth restating where a reader
// of this file will meet it: validation is of a host's CURRENTLY-resolved addresses, and
// the socket is not pinned to the address that was validated, so a DNS-rebinding attacker
// who flips the record between validate and connect is not fully closed. Accepted for a
// user-gesture-only fetch; recorded here as it is recorded in `SSRFGuard.swift`.

import Foundation

/// Why a tier-2 media fetch was refused. `Equatable` so the table tests assert the case.
public enum MediaFetchRefusal: Error, Equatable, Sendable {
    /// The candidate string is not a URL at all.
    case malformedURL(String)
    /// The URL's host is not one this app may fetch — the ``SSRFGuard``'s answer, carried
    /// verbatim so the log can say *which* address or *which* scheme was the problem.
    case blockedHost(SSRFError)
    /// A redirect from `https` to `http`. Refused on its own, before the guard sees it: the
    /// host may be perfectly public and the hop is still a downgrade of a connection the
    /// page's own URL promised would be encrypted.
    case insecureRedirect
    /// The response declared, or delivered, more bytes than the inbox will accept.
    case tooLarge(bytes: Int64, limit: Int)
    /// A non-200 response. A redirect reaching here means one that was NOT followed.
    case httpStatus(Int)
}

extension ShareCapture {

    // MARK: - The candidate

    /// The URL to fetch for one of ``mediaCandidates(for:)``'s strings, or why not.
    ///
    /// Two refusals, in the order that costs least: a string that is not a URL is decided
    /// without touching DNS, and only then is the host resolved and classified.
    ///
    /// **The scheme is checked twice and that is not redundancy.** ``mediaCandidates(for:)``
    /// filters to http(s) because a `javascript:` or `data:` src reaching a `URLSession` is
    /// a decision rather than an accident, and it is the side of the boundary a test of the
    /// EXTRACTOR can see. ``SSRFGuard/validate(_:)`` checks it again because the guard is a
    /// security boundary and a security boundary that trusts its caller to have filtered is
    /// not one. The two are independent on purpose.
    public static func fetchableURL(
        for candidate: String, through ssrf: SSRFGuard
    ) throws(MediaFetchRefusal) -> URL {
        guard let url = URL(string: candidate) else {
            throw .malformedURL(candidate)
        }
        do {
            try ssrf.validate(url)
        } catch let error as SSRFError {
            throw .blockedHost(error)
        } catch {
            // `validate` throws `SSRFError` and nothing else; this is the compiler's
            // requirement, not a case.
            throw .blockedHost(.missingHost)
        }
        return url
    }

    // MARK: - The redirect

    /// The URL a redirect hop may be followed to, or why it may not be.
    ///
    /// **A wall that only checks the first URL is not a wall.** `https://cdn.example/a.jpg`
    /// resolving to a public address says nothing about where a `302` points, and "follow
    /// the redirect to `http://169.254.169.254/`" is the classic shape of the attack the
    /// guard exists to stop — the initial host is the attacker's own, entirely public, and
    /// the interesting address is the one it hands back. So every hop is re-validated, and
    /// `URLSession`'s automatic following is the thing that has to be intercepted for that
    /// to be possible at all. This is `PageResolver`'s discipline (`PageResolver.swift:53-62`)
    /// expressed as a function rather than as a loop, because the extension follows hops
    /// through a delegate rather than by re-requesting.
    ///
    /// **The downgrade is refused before the guard runs**, and it is a separate rule. A
    /// public http host passes the SSRF guard cleanly — nothing about it is private — and
    /// the objection is different: the media URL a page named was https, the user is on a
    /// phone on somebody's Wi-Fi, and a hop to http is a picture fetched in the clear that
    /// anything on the path can replace. `https → https`, `http → http` and `http → https`
    /// are all allowed; only the one direction is not.
    public static func redirectTarget(
        from current: URL, to next: URL, through ssrf: SSRFGuard
    ) throws(MediaFetchRefusal) -> URL {
        if current.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
            throw .insecureRedirect
        }
        return try fetchableURL(for: next.absoluteString, through: ssrf)
    }

    // MARK: - The response

    /// Whether a response's headers permit its body to transfer at all.
    ///
    /// **This is the half of finding 2 that had a comment claiming it was already done.**
    /// `fetchMedia` said `expectedContentLength` "refuses an absurd file before a byte is
    /// transferred" and then read it from the result of `session.download(for:)`, which
    /// returns only once the ENTIRE body has landed on disk. A hostile page naming a 4 GB
    /// file got a 4 GB file written into the container of a process with a ~120 MB budget
    /// and then a tidy log line about the cap. Refusing on the headers is what the comment
    /// always described.
    ///
    /// - Parameters:
    ///   - length: `expectedContentLength` / `totalBytesExpectedToWrite`. **`nil` and any
    ///     negative value both mean UNKNOWN and are accepted** — `URLSession` spells that
    ///     `NSURLSessionTransferSizeUnknown`, which is `-1`, and a chunked response has no
    ///     length to declare. That is exactly why the real size is still checked after the
    ///     body lands: this predicate can only refuse what the server admits to.
    ///   - status: the HTTP status, or `nil` for a response that is not HTTP. Only 200 is
    ///     accepted; a redirect status reaching here is one that was not followed.
    ///
    /// The size is decided before the status, which is the order the code being replaced
    /// used: an over-cap body is over-cap whatever the status line said about it.
    public static func acceptsFetched(
        length: Int64?, status: Int?
    ) throws(MediaFetchRefusal) {
        let limit = InboxWriter.maximumPayloadBytes
        if let length, length > Int64(limit) {
            throw .tooLarge(bytes: length, limit: limit)
        }
        if let status, status != 200 {
            throw .httpStatus(status)
        }
    }
}
