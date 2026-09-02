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
// **The URL is a page's, so the fetch is walled** (098 · finding 2). The page tier 2 exists
// for is one the user is signed in to and a cookie-less Mac cannot see; "attacker-
// influenceable" is not a hypothetical about it, it is its definition. Every decision the
// wall makes — may this candidate be requested, may this redirect hop be followed, may this
// body transfer — is `AtelierCapture`'s ``MediaFetchRefusal`` policy, pure and table-tested
// on macOS where this target's own code cannot be tested at all.
//
// **What is left here is glue, and the glue is untested.** Which delegate method carries
// which decision, and whether `URLSession` calls it, cannot be asserted without a test host
// this target does not have. Two consequences are worth stating rather than discovering:
//
//   • `didReceive response` is a `URLSessionDataDelegate` method and does NOT fire for a
//     download task, so the header-time size refusal hangs on `didWriteData`, which fires
//     as the first chunk lands. "Before a byte is transferred" is therefore "after the
//     first chunk and before the rest" — the difference between refusing a 4 GB file at
//     ~16 KB and refusing it at 4 GB, which is the difference that matters in a process
//     with a ~120 MB ceiling.
//   • If that callback ever stopped arriving, the fetch would degrade to exactly what it
//     did before this change: the real size is still checked once the body lands, and an
//     over-cap file is still refused. The wall would get later, not thinner.
//
// The rest is bounded as it was: http(s) only, one budget for the whole share rather than
// per attempt, the same byte cap `InboxWriter` enforces, and streamed to a FILE so nothing
// is held in memory (091 · D2).
//
// Split out of `ShareViewController` in 098 · P5 (finding 7).

import AtelierCapture
import Foundation
import OSLog

/// Fetching the picture a page named, within a budget and behind a wall.
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
    /// happen anyway. **The guard's DNS lookup is inside that budget**, deliberately: a
    /// resolution that hangs is a share sheet that hangs, and it should spend the fetch's
    /// own time rather than time nobody accounted for.
    static func pageItem(for capture: PageCapture) async -> SharedItem {
        let candidates = ShareCapture.mediaCandidates(for: capture)
        guard !candidates.isEmpty else { return .page(capture) }

        // One guard, so one DNS posture for the whole share. `SSRFGuard()`'s default
        // resolver is `getaddrinfo`, which is synchronous — it runs here rather than on the
        // main actor because this whole namespace is `nonisolated`.
        let wall = SSRFGuard()
        let delegate = RedirectWall(wall: wall)
        let session = makeMediaSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(mediaFetchBudget))
        for candidate in candidates {
            let remaining = remainingSeconds(until: deadline)
            guard remaining > 0 else {
                ShareLog.share.info("media budget spent before another candidate")
                break
            }
            if let file = await fetchMedia(
                candidate, in: session, through: wall, watchedBy: delegate,
                timeout: remaining) {
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
    ///
    /// The delegate is set on the SESSION rather than passed per task. A task-scoped
    /// delegate is documented to receive life-cycle callbacks, and `didWriteData` is not
    /// obviously one of those; the session's delegate receives both it and the redirect
    /// callback with no ambiguity, and this session's whole lifetime is one share.
    private static func makeMediaSession(delegate: RedirectWall) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = mediaFetchBudget
        // The share-wide ceiling. Per-request time is bounded again, more tightly, by the
        // `timeout` each call passes.
        configuration.timeoutIntervalForResource = mediaFetchBudget
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Download `urlString` to a file this process owns, or nil.
    ///
    /// **Streamed to disk, never held.** `URLSession.download` writes the body to a
    /// temporary file, so a 12 MB photo costs this process no memory — the same reason
    /// `loadFileRepresentation` is preferred over `loadDataRepresentation` in
    /// ``ProviderPayloads``, and the reason a fetch is affordable at all inside a ~120 MB
    /// ceiling (091 · D2).
    ///
    /// **The size is checked three times, and the middle one is the new one.** The
    /// candidate is walled before the request; ``RedirectWall`` cancels on the declared
    /// length as the first chunk arrives, which is what the comment that used to sit here
    /// always claimed `expectedContentLength` did and it did not — it was read from the
    /// result of a `download` that had already written the entire body; and the real size
    /// is checked afterwards, by `ShareCapture.acceptsFetched` and again by `adopt`,
    /// because a server can lie or send no length at all.
    ///
    /// `session` is the share's, not this call's — see ``pageItem(for:)``. `timeout` is
    /// what remains of the share's budget, carried on the request so a second candidate
    /// cannot spend a second full allowance.
    private static func fetchMedia(
        _ urlString: String, in session: URLSession, through wall: SSRFGuard,
        watchedBy delegate: RedirectWall, timeout: TimeInterval
    ) async -> URL? {
        let url: URL
        do {
            url = try ShareCapture.fetchableURL(for: urlString, through: wall)
        } catch {
            // `.public` because every field of a `MediaFetchRefusal` is a scheme, a status
            // or an IP address the guard classified — the vocabulary, not the content. The
            // candidate URL itself is not interpolated, for the reason `pageCapture`'s
            // `chose=` is `.private`.
            ShareLog.share.error(
                "media candidate refused: \(String(describing: error), privacy: .public)")
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (file, response) = try await session.download(for: request)
            // **One removal, on every path out.** `adopt` COPIES, so the download is this
            // call's to delete whatever happens to it, and a `defer` is the only spelling
            // of that which a new early return cannot forget.
            defer { try? FileManager.default.removeItem(at: file) }

            let http = response as? HTTPURLResponse
            do {
                try ShareCapture.acceptsFetched(
                    length: http?.expectedContentLength, status: http?.statusCode)
            } catch {
                ShareLog.share.info(
                    "media response refused: \(String(describing: error), privacy: .public)")
                return nil
            }
            // The downloaded file lives in a temporary location the system reclaims, so
            // it is adopted immediately — the same discipline `loadFileRepresentation`
            // needs, for the same reason. `adopt` also applies the byte cap.
            return try ProviderPayloads.adopt(file)
        } catch {
            // A refusal the delegate made is reported by `URLSession` as a plain
            // cancellation, which says nothing; the reason it recorded is what makes the
            // line worth reading.
            let refused = delegate.takeRefusal().map { " refusal=\(String(describing: $0))" } ?? ""
            ShareLog.share.info(
                """
                media fetch failed: \(String(describing: error), privacy: .public)\
                \(refused, privacy: .public)
                """)
            return nil
        }
    }

    // MARK: - The wall, on the session's callbacks

    /// Re-validates every redirect hop, and cancels an over-cap body as it starts to arrive.
    ///
    /// **A wall that only checks the first URL is not a wall** — `https://cdn.example/a.jpg`
    /// resolving to a public address says nothing about where its `302` points, and
    /// "redirect to `http://169.254.169.254/`" is the classic shape of the attack. So
    /// `URLSession`'s automatic following is intercepted and each `Location` goes back
    /// through `ShareCapture.redirectTarget`, which re-runs the guard and refuses an
    /// https→http downgrade. Returning `nil` from the redirect callback means "do not
    /// follow"; the task then completes carrying the redirect response itself, whose 3xx
    /// status `acceptsFetched` refuses.
    ///
    /// `@unchecked Sendable` over an `NSLock`, the shape `PageResolver.RedirectBlocker`
    /// uses: `URLSession` calls these on its own delegate queue, and the one piece of
    /// mutable state is the refusal that a `cancel()` would otherwise erase.
    ///
    /// One slot rather than a table keyed by task, because ``pageItem(for:)`` awaits each
    /// candidate before starting the next — at most one task of this session is ever in
    /// flight — and the slot is drained by the fetch that failed.
    private final class RedirectWall: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let wall: SSRFGuard
        private let lock = NSLock()
        private var refusal: MediaFetchRefusal?

        init(wall: SSRFGuard) {
            self.wall = wall
        }

        /// The refusal this delegate recorded, cleared as it is read.
        func takeRefusal() -> MediaFetchRefusal? {
            lock.withLock {
                defer { refusal = nil }
                return refusal
            }
        }

        /// First refusal wins: it is the one that describes what actually stopped the task.
        private func record(_ new: MediaFetchRefusal) {
            lock.withLock { refusal = refusal ?? new }
        }

        /// The completion-handler spelling rather than the `async` one, and not by taste:
        /// Swift 6.3.3 crashes in SILGen emitting the ObjC thunk for the `async` overload of
        /// this method (`emitNativeToForeignThunk`) under this target's settings. The two
        /// are the same callback; this one compiles.
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let current = task.currentRequest?.url ?? task.originalRequest?.url,
                  let next = request.url else {
                record(.malformedURL("a redirect with no URL"))
                return completionHandler(nil)
            }
            do {
                _ = try ShareCapture.redirectTarget(from: current, to: next, through: wall)
                completionHandler(request)
            } catch {
                record(error)
                completionHandler(nil)
            }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            // Both numbers, against one cap. The DECLARED length is what refuses a 4 GB
            // file at the first chunk; the WRITTEN count is what catches a server that
            // declared `NSURLSessionTransferSizeUnknown` (-1) or lied, which is the case a
            // header-time predicate cannot decide at all.
            do {
                try ShareCapture.acceptsFetched(
                    length: max(totalBytesExpectedToWrite, totalBytesWritten), status: nil)
            } catch {
                record(error)
                downloadTask.cancel()
            }
        }

        /// Required by `URLSessionDownloadDelegate` and deliberately empty: the async
        /// `download(for:)` delivers the file as its return value, and this callback is not
        /// invoked for a task that carries one.
        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }
}
