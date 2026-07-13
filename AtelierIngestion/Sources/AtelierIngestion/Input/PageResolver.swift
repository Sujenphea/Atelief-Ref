// AtelierIngestion — page-URL resolver (001 · C2b)
//
// Turns a pasted PAGE url into link metadata (og:title / og:description / og:image)
// so a saved link gets a real title + thumbnail instead of a bare card. This is the
// second (and last) place the app reaches the network — strictly gated:
//   • http(s) only, and EVERY hop (initial + each redirect) passes ``SSRFGuard`` so
//     the fetch can never reach an internal / metadata / loopback address;
//   • redirects are followed MANUALLY (auto-follow disabled) so each `Location` is
//     re-validated — a public URL that 302s to `169.254.169.254` is caught;
//   • no cookies are sent (an ephemeral, cookie-less session), a redirect + body cap
//     bound the work.
//
// The og-tag PARSER is pure (`parse(html:baseURL:)`) and fixture-tested; the fetch is
// the thin guarded network layer around it. og-tags only in v1 (no oEmbed discovery
// request — added later if the hit-rate disappoints).

import Foundation

/// A resolved page's link metadata. Every field is best-effort — a page may expose
/// none (then the caller saves a bare link keyed by its URL).
public struct ResolvedPage: Sendable, Equatable {
    public var title: String?
    public var description: String?
    /// The absolute og:image URL (resolved against the final page URL), or nil.
    public var imageURL: URL?

    public init(title: String? = nil, description: String? = nil, imageURL: URL? = nil) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
    }
}

/// A typed page-resolution failure. `Equatable` so tests assert the exact case.
public enum PageResolveError: Error, Equatable {
    case requestFailed
    case httpStatus(Int)
    case tooManyRedirects
    /// The response wasn't HTML (e.g. a PDF / image / JSON) — nothing to scrape.
    case notHTML(String?)
    case tooLarge(bytes: Int)
    case emptyDocument
}

/// Fetches a page (SSRF-walled, manual redirects, cookie-less) and extracts its
/// link metadata. Injectable: the `URLSessionConfiguration` and the ``SSRFGuard``
/// are supplied so tests drive it through a `URLProtocol` stub + a fake resolver.
public struct PageResolver: Sendable {

    /// Blocks URLSession's automatic redirect following so the resolver can validate
    /// each `Location` itself (`completionHandler(nil)` = "don't follow").
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil // never auto-follow; the resolver re-validates + re-requests each hop
        }
    }

    private let session: URLSession
    private let ssrf: SSRFGuard
    private let maxRedirects: Int
    private let maxByteCount: Int

    /// A cookie-less ephemeral configuration with sane timeouts — the resolver sends
    /// no credentials and keeps nothing.
    public static var defaultConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return config
    }

    public init(
        configuration: URLSessionConfiguration? = nil,
        guard ssrf: SSRFGuard = SSRFGuard(),
        maxRedirects: Int = 5,
        maxByteCount: Int = 5 * 1024 * 1024
    ) {
        self.session = URLSession(
            configuration: configuration ?? PageResolver.defaultConfiguration,
            delegate: RedirectBlocker(), delegateQueue: nil)
        self.ssrf = ssrf
        self.maxRedirects = maxRedirects
        self.maxByteCount = maxByteCount
    }

    /// Known auth-walled / media hosts where an app-side page fetch returns a login
    /// page or a low-res share card, NOT the real content (001 · O3). The caller
    /// routes these to "Capture with the extension" instead of resolving a garbage
    /// link — the extension rides the browser's authenticated session. Match is
    /// host-exact or a subdomain (`mobile.twitter.com`).
    public static func isAuthWalledHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let walled = ["x.com", "twitter.com", "instagram.com", "pinterest.com", "facebook.com"]
        return walled.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Resolve `url` to its link metadata, or throw. Non-isolated so the network I/O
    /// runs off the calling actor.
    public func resolve(_ url: URL) async throws -> ResolvedPage {
        let (data, finalURL) = try await fetch(url)
        guard let html = Self.decodeHTML(data) else { throw PageResolveError.emptyDocument }
        return Self.parse(html: html, baseURL: finalURL)
    }

    // MARK: - Guarded fetch (manual redirects, SSRF per hop, body cap)

    private func fetch(_ url: URL) async throws -> (data: Data, finalURL: URL) {
        var current = url
        for _ in 0...maxRedirects {
            try ssrf.validate(current) // scheme + SSRF on the initial url AND each hop

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(from: current)
            } catch {
                throw PageResolveError.requestFailed
            }
            guard let http = response as? HTTPURLResponse else { throw PageResolveError.requestFailed }

            // Redirect — re-validate the Location on the NEXT loop; don't read the body.
            if (300...399).contains(http.statusCode), http.statusCode != 304 {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw PageResolveError.httpStatus(http.statusCode)
                }
                current = next
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw PageResolveError.httpStatus(http.statusCode)
            }

            // Only parse HTML; a PDF / image / JSON page has no og-tags to scrape. An
            // ABSENT Content-Type is tolerated (some servers omit it) — the parser just
            // finds nothing and the caller saves a bare link.
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !contentType.isEmpty, !contentType.contains("html"), !contentType.contains("xml") {
                throw PageResolveError.notHTML(contentType)
            }

            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxByteCount { throw PageResolveError.tooLarge(bytes: data.count) }
                }
            } catch let error as PageResolveError {
                throw error
            } catch {
                throw PageResolveError.requestFailed
            }
            return (data, current)
        }
        throw PageResolveError.tooManyRedirects
    }

    // MARK: - HTML decode

    /// Decode HTML bytes to a string: UTF-8, falling back to Latin-1 (which never
    /// fails) so a mis-encoded page still yields its ASCII og-tags. `nil` if empty.
    static func decodeHTML(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Pure og-tag parser (fixture-tested)

    /// Extract link metadata from HTML. `baseURL` (the FINAL page URL after redirects)
    /// resolves a relative og:image. Total: a page with no tags → an all-nil result.
    public static func parse(html: String, baseURL: URL) -> ResolvedPage {
        var metas: [String: String] = [:] // property/name (lowercased) → content, first wins
        for tag in metaTags(in: html) {
            let attrs = attributes(of: tag)
            guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
                  let content = attrs["content"], !content.isEmpty else { continue }
            if metas[key] == nil { metas[key] = content }
        }

        let rawTitle = metas["og:title"] ?? metas["twitter:title"] ?? titleTag(in: html)
        let rawDescription = metas["og:description"] ?? metas["twitter:description"] ?? metas["description"]
        let rawImage = metas["og:image"] ?? metas["og:image:url"]
            ?? metas["og:image:secure_url"] ?? metas["twitter:image"] ?? metas["twitter:image:src"]

        let imageURL = rawImage
            .map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: baseURL)?.absoluteURL }

        return ResolvedPage(
            title: cleaned(rawTitle),
            description: cleaned(rawDescription),
            imageURL: imageURL)
    }

    /// Decode common entities + trim; nil for an empty/whitespace-only result.
    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The `<meta …>` tags in `html` (opening tags, attributes intact).
    private static func metaTags(in html: String) -> [String] {
        matches(of: "<meta\\b[^>]*>", in: html, options: [.caseInsensitive])
    }

    /// The `<title>` text, or nil.
    private static func titleTag(in html: String) -> String? {
        matches(of: "<title[^>]*>([\\s\\S]*?)</title>", in: html,
                options: [.caseInsensitive], group: 1).first
    }

    /// Parse an HTML tag's `name="value"` / `name='value'` / `name=value` attributes
    /// into a lowercased-key → value map.
    private static func attributes(of tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            // The value is whichever quoted / unquoted group matched.
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                if attrs[name] == nil { attrs[name] = ns.substring(with: match.range(at: group)) }
                break
            }
        }
        return attrs
    }

    /// All matches of `pattern` in `text` (a chosen capture `group`, default whole match).
    private static func matches(
        of pattern: String, in text: String,
        options: NSRegularExpression.Options = [], group: Int = 0
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let range = $0.range(at: group)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// Decode the handful of HTML entities that show up in og content (best-effort).
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&#x27;": "'", "&nbsp;": " "]
        for (entity, replacement) in named { out = out.replacingOccurrences(of: entity, with: replacement) }
        return out
    }
}
