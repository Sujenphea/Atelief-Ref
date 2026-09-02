// AtelierRefsShare — the one network call this extension makes (092 · S4b, tier 2).
//
// A tier-2 page arrives with provenance and no picture: the DOM named a media URL and
// somebody has to go and get it. That is this file, and it is the ONLY place in the
// extension that opens a socket.
//
// **Every failure here is a success somewhere else.** A media-less `.page` still carries
// the author, the permalink and the post id the DOM gave up, which is more than tier 1
// could ever have known — so a fetch that fails degrades to a good capture rather than to
// a lost one. That property is what makes fetching inside a share sheet defensible at all,
// and it is why nothing in this file throws.
//
// It is bounded on every axis that can hurt: http(s) only, one budget for the whole share
// rather than per attempt, the same byte cap `InboxWriter` enforces, and streamed to a FILE
// so nothing is held in memory (091 · D2).
//
// Split out of `ShareViewController` in 098 · P5 (finding 7).

import AtelierCapture
import Foundation
import OSLog

/// Fetching the picture a page named, within a budget.
nonisolated enum MediaFetcher {

    /// A page capture with its media fetched, or without it.
    ///
    /// Never throws and never fails the share: everything here is best-effort by
    /// construction, because the alternative to a picture is a link that still carries
    /// the DOM's provenance.
    ///
    /// **The budget is for the SHARE, not for each attempt** — which is what
    /// ``mediaFetchBudget``'s own wording always claimed and the code did not do.
    ///
    /// `mediaCandidates` returns up to two URLs, and the second exists precisely because
    /// the first is a rewrite that is KNOWN to fail sometimes (`/originals/` 404s on
    /// Pinterest, `name=orig` gets refused). So two attempts is the expected path when the
    /// rewrite is wrong, not an exotic one — and with the timeout applied per attempt, two
    /// slow-or-dead CDN requests left the user watching the card for sixteen seconds. At
    /// that length a share sheet does not read as "fetching", it reads as a hang.
    ///
    /// One deadline for the whole loop, and each attempt gets what is left of it. A
    /// candidate reached with no budget remaining is not attempted at all, because starting
    /// a request that is already out of time only delays the fallback that was going to
    /// happen anyway.
    ///
    /// One session for the loop as well. Its `timeoutIntervalForResource` is the whole
    /// budget — a genuine ceiling on the share rather than on a request — while each
    /// request carries the remainder as its own `timeoutInterval`. The two together are
    /// what make the bound hold whether one candidate hangs or both are merely slow.
    static func pageItem(for capture: PageCapture) async -> SharedItem {
        let candidates = ShareCapture.mediaCandidates(for: capture)
        guard !candidates.isEmpty else { return .page(capture) }

        let session = makeMediaSession()
        defer { session.finishTasksAndInvalidate() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(mediaFetchBudget))
        for candidate in candidates {
            let remaining = remainingSeconds(until: deadline)
            guard remaining > 0 else {
                ShareLog.share.info("media budget spent before \(candidate, privacy: .public)")
                break
            }
            if let file = await fetchMedia(candidate, in: session, timeout: remaining) {
                return .page(capture, bytes: .fileURL(file))
            }
        }
        return .page(capture)
    }

    /// Seconds left before `deadline`, floored at zero.
    ///
    /// `ContinuousClock` rather than `Date`: it does not move when the wall clock does, and
    /// a share sheet that got longer because the user crossed a timezone would be an
    /// absurd bug to own.
    private static func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return 0 }
        let (seconds, attoseconds) = left.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// How long the whole media fetch may take before the share gives up on it.
    ///
    /// A receipt the user is watching is on the other side of this. 093 § 1 wants the
    /// card in under a second; a picture is worth waiting a little longer for, and a CDN
    /// that has not answered in eight seconds is not about to make anyone happy.
    ///
    /// Renamed from `mediaFetchTimeout` when it became one: a "timeout" is a property of a
    /// request and this is a property of the share, and the old name is most of why it was
    /// applied per candidate for as long as it was.
    private static let mediaFetchBudget: TimeInterval = 8

    /// The one session a share's fetches share.
    ///
    /// A cookie-less ephemeral session, matching `PageResolver`'s posture on the Mac: the
    /// URL came out of a page, this is a fetch of a public CDN asset, and there is no
    /// reason to hand it anybody's cookies.
    private static func makeMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = mediaFetchBudget
        // The share-wide ceiling. Per-request time is bounded again, more tightly, by the
        // `timeout` each call passes.
        configuration.timeoutIntervalForResource = mediaFetchBudget
        return URLSession(configuration: configuration)
    }

    /// Download `urlString` to a file this process owns, or nil.
    ///
    /// **Streamed to disk, never held.** `URLSession.download` writes the body to a
    /// temporary file, so a 12 MB photo costs this process no memory — the same reason
    /// `loadFileRepresentation` is preferred over `loadDataRepresentation` in
    /// ``ProviderPayloads``, and the reason a fetch is affordable at all inside a ~120 MB
    /// ceiling (091 · D2).
    ///
    /// The size is checked TWICE and both are necessary: `expectedContentLength` refuses
    /// an absurd file before a byte is transferred, and the file's real size catches a
    /// server that lied or sent no length at all.
    ///
    /// `session` is the share's, not this call's — see ``pageItem(for:)``. `timeout` is
    /// what remains of the share's budget, carried on the request so a second candidate
    /// cannot spend a second full allowance.
    private static func fetchMedia(
        _ urlString: String, in session: URLSession, timeout: TimeInterval
    ) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (file, response) = try await session.download(for: request)
            // **One removal, on every path out** (098 · finding 7). The two refusals below
            // each removed the download themselves and the `adopt` path did not, so a file
            // over the cap — the one case where the file is BIG — was left in the temporary
            // directory of a process with a ~120 MB budget for the system to reclaim on its
            // own schedule. `adopt` COPIES, so the download is this call's to delete
            // whatever happens to it, and a `defer` is the only spelling of that which a
            // new early return cannot forget.
            defer { try? FileManager.default.removeItem(at: file) }

            if let expected = (response as? HTTPURLResponse)?.expectedContentLength,
               expected > Int64(InboxWriter.maximumPayloadBytes) {
                ShareLog.share.info("media of \(expected, privacy: .public) bytes is over the cap")
                return nil
            }
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                ShareLog.share.info("media fetch returned \(status, privacy: .public)")
                return nil
            }
            // The downloaded file lives in a temporary location the system reclaims, so
            // it is adopted immediately — the same discipline `loadFileRepresentation`
            // needs, for the same reason. `adopt` also applies the byte cap.
            return try ProviderPayloads.adopt(file)
        } catch {
            ShareLog.share.info("media fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
