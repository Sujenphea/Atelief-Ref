// AtelierCapture — a harvested page, turned into provenance and a media URL
// (092 · S4b, tier 2).
//
// **What tier 2 is for.** `PageResolver.isAuthWalledHost` names x.com, instagram.com and
// pinterest.com: a cookie-less fetch of those pages returns a login wall or a 270px share
// card, never the post. So a link shared from one of them lands on the Mac as a bare card
// and stays one — the Mac's answer is "capture it with the browser extension", which rides
// an authenticated session. Safari on the phone IS that authenticated session, and the
// rendered DOM holds the real media URL and the real text. This file is what reads them.
//
// **It mirrors `extension/src/extractors/`, and the mirror is not free-hand.** Platform
// dispatch does not re-implement the five `match(url)` functions; it asks
// ``ShareCapture/platform(forURLString:)``, whose host table is already gated against the
// JS extractors by `extension/src/host-table.js` in CI. One table, one gate, two readers.
//
// What is NOT covered by that gate, and is stated rather than implied: the media-URL
// REWRITE rules below (`name=orig` for twimg, `/originals/` for pinimg) are a second
// mirror of `base.js:toOrigName` / `base.js:toOriginals`. They fail softly — a rule that
// drifts yields a smaller image, not a lost capture — which is why they are worth having
// without a gate, and why a gate would still be worth adding.
//
// **Three differences from the browser extension, all of them removals.**
//
// - **No `context`.** The JS extractors take the right-clicked element (`srcUrl`,
//   `linkUrl`) and prefer it over everything, because a browser capture is usually a
//   right-click in a feed. A share sheet has no right-click: the user shared THE PAGE, so
//   the page's URL and the page's media are all there is. Every `firstPostURL([context…])`
//   collapses to the live URL, which is what the JS falls back to anyway.
// - **No video frame.** See ``PageHarvest``'s header — the poster is harvested instead.
// - **No `mediaUrls[]`.** The browser extension carries up to four photos of a tweet as
//   payload references (003 · C3). The phone fetches exactly one file into one sidecar
//   (092 · S2), so a second URL would be a promise nothing keeps.

import Foundation
import AtelierCore

/// What a preprocessed page amounts to: provenance, and where its picture is.
public struct PageCapture: Equatable, Sendable {
    public var provenance: ProvenanceDTO
    /// The media to fetch, already rewritten to full resolution. Nil when the page
    /// rendered nothing fetchable — a text-only tweet is the ordinary case.
    public var mediaURL: String?
    /// What to try if ``mediaURL`` fails. `/originals/` can 404 on Pinterest and
    /// `name=orig` can be refused, and in both cases the size the page actually rendered
    /// is known to load.
    public var mediaURLFallback: String?

    public init(
        provenance: ProvenanceDTO, mediaURL: String? = nil, mediaURLFallback: String? = nil
    ) {
        self.provenance = provenance
        self.mediaURL = mediaURL
        self.mediaURLFallback = mediaURLFallback
    }
}

/// Reading a ``PageHarvest``. A namespace — `static` only, and pure.
public enum PageExtractor {

    /// The capture a harvested page amounts to.
    ///
    /// Dispatch is on the platform the LIVE URL names, so a page that redirected, or an
    /// SPA that pushed state, is classified by where the user actually is.
    public static func capture(from harvest: PageHarvest) -> PageCapture {
        let url = liveURL(harvest)
        switch ShareCapture.platform(forURLString: url) {
        case .twitter: return twitter(harvest, url: url)
        case .pinterest: return pinterest(harvest, url: url)
        case .instagram: return instagram(harvest, url: url)
        default: return web(harvest, url: url)
        }
    }

    // MARK: - Per platform

    /// X / Twitter (`extension/src/extractors/twitter.js`).
    ///
    /// The focal-tweet scoping is the rule worth keeping across the port: on a status page
    /// the first `<article>` is the tweet and everything after it is a REPLY, so a
    /// text-only tweet that borrows a reply's photo is the failure this prevents. When the
    /// snapshot carries no article structure there is nothing to scope to, and only then
    /// is `og:image` allowed to stand in — on a real tweet page, a focal tweet with no
    /// media is genuinely text-only and must stay image-less rather than pick up X's
    /// generic summary card.
    private static func twitter(_ harvest: PageHarvest, url: String?) -> PageCapture {
        let postURL = firstPostURL(
            [url, harvest.canonical], where: { pathSegments($0).count > 1 && pathSegments($0)[1] == "status" })
            ?? url
        let segments = pathSegments(postURL)
        // A handle exists only on a status page, `/<handle>/status/<id>` (457; 098 ·
        // finding 12). Until then the first path segment of ANY X URL became the
        // author: sharing `x.com/home` recorded `@home`, `/explore` recorded `@explore`,
        // and a profile page recorded its owner as the author of a capture with no
        // post. `twitter.js:61` still does that — the browser extension is always handed
        // a post link by its right-click context, so the feed case never reaches it there.
        // `i` is X's reserved namespace (`/i/status/<id>`, `/i/bookmarks`), never an
        // account, so it is not a handle even on a status page.
        let isStatus = segments.count > 2 && segments[1] == "status"
        let handle = isStatus && segments[0] != "i" ? "@" + segments[0] : nil
        let tweetID = isStatus ? segments[2] : nil

        let hasArticles = harvest.media.contains { ($0.articleIndex ?? -1) >= 0 }
        let focal = hasArticles
            ? PageHarvest(
                url: harvest.url, title: harvest.title, canonical: harvest.canonical,
                metas: harvest.metas, media: harvest.media.filter { $0.articleIndex == 0 })
            : harvest

        let photo = firstMedia(focal, matching: "pbs.twimg.com/media/")?.src
        let poster = firstMedia(
            focal, matchingAny: [
                "pbs.twimg.com/ext_tw_video_thumb", "pbs.twimg.com/amplify_video_thumb",
                "pbs.twimg.com/tweet_video_thumb",
            ])?.src
        let rendered = photo ?? poster
        let mediaURL = toOrigName(rendered) ?? (hasArticles ? nil : ogImage(harvest))

        return PageCapture(
            provenance: provenance(
                platform: .twitter, url: postURL,
                authorHandle: handle, authorName: nil,
                title: firstMeta(harvest, ["og:description", "twitter:description"]) ?? harvest.title,
                extra: tweetID.map { ["tweetId": .string($0)] } ?? [:]),
            mediaURL: mediaURL,
            mediaURLFallback: fallback(rendered: rendered, chosen: mediaURL))
    }

    /// Pinterest (`extension/src/extractors/pinterest.js`).
    ///
    /// A pin page's main image is the BIGGEST `i.pinimg.com` image on it — the rest are
    /// related pins and board thumbs — which is the opposite of X, where the focal item
    /// renders first. `s.pinimg.com` share logos are excluded by the host pattern.
    private static func pinterest(_ harvest: PageHarvest, url: String?) -> PageCapture {
        let pinURL = firstPostURL(
            [url, harvest.canonical], where: { pathSegments($0).first == "pin" }) ?? url
        let segments = pathSegments(pinURL)
        let pinID = segments.first == "pin" && segments.count > 1 ? segments[1] : nil

        let rendered = largestMedia(harvest, matching: "i.pinimg.com")?.src
        let mediaURL = toOriginals(rendered) ?? ogImage(harvest)

        return PageCapture(
            provenance: provenance(
                platform: .pinterest, url: pinURL,
                authorHandle: nil, authorName: firstMeta(harvest, ["og:site_name"]),
                title: firstMeta(harvest, ["og:title", "og:description"]) ?? harvest.title,
                extra: pinID.map { ["pinId": .string($0)] } ?? [:]),
            mediaURL: mediaURL,
            mediaURLFallback: fallback(rendered: rendered, chosen: mediaURL))
    }

    /// Instagram (`extension/src/extractors/instagram.js`).
    ///
    /// The handle comes out of `og:title`, which reads "Name (@handle) on Instagram: …" —
    /// the only place a post page states it in a form worth parsing.
    private static func instagram(_ harvest: PageHarvest, url: String?) -> PageCapture {
        let postURL = firstPostURL(
            [url, harvest.canonical],
            where: { ["p", "reel"].contains(pathSegments($0).first ?? "") }) ?? url
        let segments = pathSegments(postURL)
        let shortcode = (segments.first == "p" || segments.first == "reel") && segments.count > 1
            ? segments[1] : nil

        let rendered = largestMedia(
            harvest, matchingAny: ["cdninstagram.com", "fbcdn.net"])?.src
        let mediaURL = rendered ?? ogImage(harvest)

        return PageCapture(
            provenance: provenance(
                platform: .instagram, url: postURL,
                authorHandle: instagramHandle(harvest), authorName: nil,
                title: firstMeta(harvest, ["og:description"]) ?? harvest.title,
                extra: shortcode.map { ["shortcode": .string($0)] } ?? [:]),
            mediaURL: mediaURL)
    }

    /// Any other page (`registry.js`'s `web`).
    ///
    /// Here `og:image` is PREFERRED rather than a fallback, and that inversion is
    /// deliberate: on a generic article the share image is curated and correct, while the
    /// largest DOM image is as likely to be a hero banner or an ad.
    private static func web(_ harvest: PageHarvest, url: String?) -> PageCapture {
        let largest = largestMedia(harvest, matchingAny: ["http://", "https://"])?.src
        return PageCapture(
            provenance: provenance(
                platform: ShareCapture.platform(forURLString: url), url: cleanURL(url),
                authorHandle: nil,
                authorName: firstMeta(harvest, ["og:site_name"]) ?? hostname(url),
                title: firstMeta(harvest, ["og:title", "og:description"]) ?? harvest.title,
                extra: [:]),
            mediaURL: ogImage(harvest) ?? largest)
    }

    // MARK: - Provenance

    /// The provenance every extractor builds, with the phone's own stamp folded in.
    ///
    /// `capturedVia: ios_share` rides on a tier-2 capture exactly as it does on tier 1
    /// (``ShareCapture/provenance(urlString:title:)``): the act is a fact about the
    /// capture, and the site is `platform`. The per-site ids (`tweetId`, `pinId`,
    /// `shortcode`) sit beside it in the same object, which is the shape the browser
    /// extension's `rawMetadata` already has.
    private static func provenance(
        platform: Platform, url: String?, authorHandle: String?, authorName: String?,
        title: String?, extra: [String: JSONValue]
    ) -> ProvenanceDTO {
        var metadata: [String: JSONValue] = [
            ShareCapture.capturedViaKey: .string(ShareCapture.capturedViaValue)
        ]
        for (key, value) in extra { metadata[key] = value }
        return ProvenanceDTO(
            platform: platform.rawValue,
            originalURL: url,
            authorHandle: authorHandle,
            authorName: authorName,
            title: normalized(title),
            rawMetadata: .object(metadata))
    }

    /// A title worth recording. Emptiness is `TextRules.nonBlank`'s decision — the same
    /// one tier 1 makes in ``ShareCapture/sharedItem(image:urlString:title:)`` — so the
    /// two tiers cannot disagree about what an empty title is; the truncation is this
    /// file's, because `og:description` on a long post is a paragraph and `title` is a
    /// label.
    private static func normalized(_ raw: String?) -> String? {
        guard let title = TextRules.nonBlank(raw) else { return nil }
        guard title.count > maximumTitleLength else { return title }
        return String(title.prefix(maximumTitleLength)).trimmingCharacters(
            in: .whitespacesAndNewlines) + "…"
    }

    /// Where a scraped title stops being a title. A tweet is 280 characters and an
    /// `og:description` can be far longer; the Mac shows this on one line in a grid tile.
    static let maximumTitleLength = 280

    // MARK: - URLs

    /// `url` reduced to origin + path — query and fragment dropped
    /// (`base.js:cleanURL`).
    static func cleanURL(_ raw: String?) -> String? {
        guard let raw, let components = URLComponents(string: raw),
              let scheme = components.scheme, let host = components.host
        else { return raw }
        // The port belongs to the origin. `base.js` builds this from `url.origin`, which
        // INCLUDES a non-default port, and rebuilding from scheme and host alone dropped
        // it — silently turning `http://host:8080/p` into a different page's URL. Found
        // when a tier-2 capture off a loopback fixture recorded `127.0.0.1/page.html`.
        // A DEFAULT port is dropped, as `url.origin` drops it: `https://host:443/a` and
        // `https://host/a` are one page, and writing the port back out would stop a phone
        // capture matching the one the browser extension recorded for the same URL.
        let isDefault = (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443)
        let port = isDefault ? "" : components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(components.path)"
    }

    /// The live URL, preferred over `canonical` (`base.js:liveURL`).
    ///
    /// On an SPA the canonical link is frequently stale or points at the site root, while
    /// `location.href` is kept correct by `pushState`. This is the single most load-bearing
    /// rule the browser extension learned from real pages.
    static func liveURL(_ harvest: PageHarvest) -> String? {
        cleanURL(harvest.url ?? harvest.canonical)
    }

    /// The first candidate that looks like a post (`base.js:firstPostURL`).
    ///
    /// The candidate list is shorter than the browser extension's because there is no
    /// right-clicked link on a phone, but the rule is the same one: a page URL that is a
    /// feed rather than a post should not become the capture's identity if a better
    /// candidate exists.
    static func firstPostURL(
        _ candidates: [String?], where isPost: (String) -> Bool
    ) -> String? {
        for candidate in candidates {
            guard let clean = cleanURL(candidate), isPost(clean) else { continue }
            return clean
        }
        return nil
    }

    /// Non-empty path segments of a URL (`base.js:pathSegments`).
    static func pathSegments(_ raw: String?) -> [String] {
        guard let raw, let path = URLComponents(string: raw)?.path else { return [] }
        return path.split(separator: "/").map(String.init)
    }

    /// Lowercased host, or nil (`base.js:hostname`).
    static func hostname(_ raw: String?) -> String? {
        guard let raw, let host = URLComponents(string: raw)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }

    /// Rewrite a `pbs.twimg.com` URL to original resolution (`base.js:toOrigName`).
    ///
    /// Only a URL that ALREADY carries a `name=` parameter is rewritten — a bare URL is
    /// left alone, which is the browser extension's default and the reason it takes an
    /// `addIfAbsent` flag for its bulk path. The phone has no bulk path.
    static func toOrigName(_ src: String?) -> String? {
        guard let src, var components = URLComponents(string: src),
              let items = components.queryItems,
              items.contains(where: { $0.name == "name" })
        else { return src }
        // **`format=webp` and `name=orig` are incompatible** — twimg 404s the pair, and
        // the caller then falls back to the rendered size, silently capturing a `medium`
        // where the whole point of the rewrite was the original. `base.js` never hit this
        // because a browser capture starts from a right-clicked `srcUrl`, which is jpg;
        // the phone starts from the DOM's `currentSrc`, which Safari negotiates to webp.
        // Observed on a real device: `?format=webp&name=orig` → 404, `format=jpg` → 200.
        components.queryItems = items.map { item in
            switch item.name {
            case "name": URLQueryItem(name: "name", value: "orig")
            case "format" where item.value == "webp": URLQueryItem(name: "format", value: "jpg")
            default: item
            }
        }
        return components.string ?? src
    }

    /// Rewrite a sized `i.pinimg.com` path to `/originals/` (`base.js:toOriginals`).
    ///
    /// The pattern is the JS regex character for character — `/474x/` and `/236x236/` are
    /// both sizes Pinterest serves, and only the segment between the host and the rest of
    /// the path is replaced.
    static func toOriginals(_ src: String?) -> String? {
        guard let src else { return nil }
        return src.replacingOccurrences(
            of: #"i\.pinimg\.com/\d+x(?:\d+)?/"#,
            with: "i.pinimg.com/originals/",
            options: .regularExpression)
    }

    /// The rendered URL, when the chosen one is a rewrite of it and might not resolve.
    private static func fallback(rendered: String?, chosen: String?) -> String? {
        guard let rendered, let chosen, chosen != rendered else { return nil }
        return rendered
    }

    // MARK: - Media and metas

    static func meta(_ harvest: PageHarvest, _ key: String) -> String? {
        harvest.metas[key]
    }

    static func firstMeta(_ harvest: PageHarvest, _ keys: [String]) -> String? {
        for key in keys {
            if let value = harvest.metas[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// The share image a page declares (`base.js:ogImage`).
    static func ogImage(_ harvest: PageHarvest) -> String? {
        firstMeta(harvest, ["og:image", "og:image:url", "twitter:image"])
    }

    /// First in DOM order whose src contains `pattern` — for feeds where the focused item
    /// renders first (`base.js:firstMedia`).
    static func firstMedia(_ harvest: PageHarvest, matching pattern: String) -> PageHarvest.Media? {
        firstMedia(harvest, matchingAny: [pattern])
    }

    static func firstMedia(
        _ harvest: PageHarvest, matchingAny patterns: [String]
    ) -> PageHarvest.Media? {
        harvest.media.first { media in patterns.contains { media.src.contains($0) } }
    }

    /// Largest by rendered area — for closeup pages where the main image is the biggest
    /// (`base.js:largestMedia`).
    static func largestMedia(
        _ harvest: PageHarvest, matching pattern: String
    ) -> PageHarvest.Media? {
        largestMedia(harvest, matchingAny: [pattern])
    }

    /// Ties go to DOM ORDER, which `max(by:)` would not do — it returns the LAST maximal
    /// element, and a page whose images all report 0×0 (lazy-loaded, never laid out)
    /// would then yield its footer logo instead of its first image.
    static func largestMedia(
        _ harvest: PageHarvest, matchingAny patterns: [String]
    ) -> PageHarvest.Media? {
        var best: PageHarvest.Media?
        for media in harvest.media
        where patterns.contains(where: { media.src.contains($0) }) {
            if best == nil || media.area > best!.area { best = media }
        }
        return best
    }

    /// The handle out of Instagram's `og:title`, which reads
    /// "Name (@handle) on Instagram: …" — the only place a post page states it in a form
    /// worth parsing (`extension/src/extractors/instagram.js:33`).
    static func instagramHandle(_ harvest: PageHarvest) -> String? {
        guard let title = meta(harvest, "og:title"),
              let range = title.range(
                of: #"\(@[A-Za-z0-9._]+\)"#, options: .regularExpression)
        else { return nil }
        let handle = title[range].dropFirst(2).dropLast()   // "(@name)" → "name"
        return handle.isEmpty ? nil : "@" + handle
    }
}
