// AtelierCapture — a share, turned into a capture (092 · S4b-ii).
//
// The iOS share extension has no test host, and this slice deliberately does not
// invent one. So the rule is: everything that can be decided without `UIKit` or an
// `NSExtensionContext` is decided HERE, as pure functions over values, and tested
// under `swift test` on macOS like the rest of this package. What is left in
// `ShareViewController` is the part that genuinely needs a process — loading item
// providers, hosting a view, and completing the extension request.
//
// The seam is ``SharedItem``: what the extension found in the share, stripped of
// every Cocoa type. Everything downstream of it — which ``Platform`` the URL's host
// names, whether the capture is media-less, what goes in `rawMetadata` — is
// arithmetic over strings and bytes, and none of it needs a device.
//
// **406 moved the seam one step earlier.** `harvest` used to decide four things inside
// the extension where nothing could test them: that image bytes beat a URL, that the
// URL then becomes the image's `sourceURL`, that a `file://` attachment is not
// provenance, and that an empty title is no title. All four are now
// ``ShareCapture/sharedItem(image:urlString:title:)`` and ``ShareCapture/webURLString(_:)``,
// pure over three optionals, and the extension calls them. What stayed behind is the
// `UTType` conformance check, which needs UIKit, and the item-provider loading itself,
// which is asynchronous and Cocoa. This is the split S4b-ii chose, applied to the
// decisions that had leaked past it — not a new mechanism.
//
// **The platform mapping is the load-bearing decision** (092 · S4b). `platform`
// records which SITE the content came from, and it persists as a string in SQLite,
// so there is no `iosShare` case and there must not be one: a new case touches the
// migrator, every filter and the archive contract. The act of sharing from a phone
// is recorded instead in `rawMetadata.capturedVia`, which is the escape hatch that
// exists for exactly this. An unrecognized host is ``Platform/web``, never a guess —
// the URL itself survives verbatim in `originalURL`, so nothing is lost by declining
// to classify it.
//
// The host table mirrors `extension/src/extractors/` domain for domain, because the
// browser extension and the phone are the two producers of one contract and a host
// that means `twitter` in one of them cannot mean `web` in the other. Matching is
// `hostIs` — equal to the domain, or a subdomain of it — which is the same predicate
// `extension/src/extractors/base.js:25` uses.

import Foundation
import AtelierCore

/// What the share extension harvested from an `NSExtensionItem`, with every Cocoa
/// type already gone (092 · S4b-ii).
///
/// Tier 1 only: a URL, or image bytes. `public.plain-text` and everything else are
/// refused earlier, by the extension's `NSExtensionActivationRule`, so there is no
/// case here for them — an item shape this enum cannot express is one the share
/// sheet should never have offered Atelier for.
///
/// The image case names its bytes by a ``PayloadSource`` and never by an image object:
/// the extension writes them straight through to the sidecar, and decoding them to
/// learn anything (dimensions, format) is the memory mistake 092 · S2 exists to
/// prevent. Since 406 the source is usually a FILE — the bytes are on disk and stay
/// there until `InboxWriter` copies them into the inbox, so the extension holds an
/// image's worth of nothing.
public enum SharedItem: Equatable, Sendable {
    /// A web URL — a media-less `link` capture. Nothing is fetched here, and nothing
    /// fetches it later either.
    ///
    /// **This used to say the Mac resolves og-tags at drain time through `PageResolver`,
    /// and that was never true** (098 · "also found"). It was copied from 092 · S4b, which
    /// said the same thing, and both have been corrected. `InboxDrain.makeInput` routes a
    /// `link` record to `remoteContent` (`InboxDrain.swift:708`–`:712`); `PageResolver` is
    /// reached only from the Mac's PASTE path, which an inbox record never takes. So a
    /// tier-1 link carries this URL and whatever title the share sheet supplied, on both
    /// platforms, for the life of the capture.
    ///
    /// What exists instead is a read-side fallback with no network: `BrowseFormat.linkTitle`
    /// shows the title, else the URL's host, else the raw URL, so a bare link is recognised
    /// by its site rather than rendered as a query string (098 · P3). Mac-side enrichment
    /// after import is a follow-up outside that pass — and is why tier 2 exists at all:
    /// a page shared from Safari brings its own DOM and needs no resolver.
    case link(url: String, title: String? = nil)
    /// Image bytes — on disk or, when a provider offered no file representation, in
    /// memory — with the page or media URL they came from when the share carried one
    /// (a photo shared out of Photos carries none).
    case image(bytes: PayloadSource, sourceURL: String? = nil, title: String? = nil)
    /// A page Safari preprocessed (tier 2): provenance the DOM gave us, and the media
    /// the extension managed to fetch from it.
    ///
    /// `bytes` is nil when the page rendered nothing fetchable — a text-only tweet — or
    /// when the fetch failed, and those two collapse ON PURPOSE. Both mean the same
    /// thing to the user (a capture with no picture) and both degrade to the same
    /// place: a link capture that still carries everything the DOM said. Tier 2 failing
    /// is tier 1 succeeding, which is the property that makes fetching in the extension
    /// safe to attempt at all.
    case page(PageCapture, bytes: PayloadSource? = nil)
}

/// A capture ready for ``InboxWriter/write(_:payload:id:capturedAt:)`` — the request
/// and the bytes that belong beside it.
///
/// One value rather than two returns, because the pairing is the invariant: a
/// media-less request must carry no payload and a byte-backed one must carry its
/// bytes, and a caller that can pass them separately is a caller that can pass them
/// crossed.
public struct ShareCaptureDraft: Equatable, Sendable {
    public let request: CaptureRequest
    /// Where the media bytes are, or nil for a media-less capture. It is a
    /// ``PayloadSource`` rather than a `Data` so the file the extension was handed
    /// stays a file all the way to ``InboxWriter``.
    public let payload: PayloadSource?

    public init(request: CaptureRequest, payload: PayloadSource?) {
        self.request = request
        self.payload = payload
    }
}

/// What a share resolves to once every attachment has been read — the answer
/// ``ShareCapture/resolution(image:urlString:title:page:)`` gives.
///
/// Three cases because a share has three fates and only two of them are finished. A
/// `SharedItem?` could express "here it is" and "there is nothing", but not "this is a
/// tier-2 page whose picture still has to be fetched" — and fetching needs the network,
/// which is the one thing that cannot happen in a pure function. Collapsing that third
/// case into either of the others is how the decision ended up in the extension in the
/// first place.
public enum ShareResolution: Equatable, Sendable {
    /// Finished: this is the capture.
    case resolved(SharedItem)
    /// A tier-2 page carrying provenance but no bytes yet. The caller walks
    /// ``ShareCapture/mediaCandidates(for:)`` and folds the result — including a failure,
    /// which is a media-less `.page` and still a good capture — back into a `SharedItem`.
    case needsMedia(PageCapture)
    /// Nothing capturable: no page, no bytes, no web URL. The extension's activation rule
    /// should make this unreachable, which is exactly why it is decided somewhere a test
    /// can reach.
    case nothing
}

/// Turning a share into a capture. A namespace — `static` only, and pure.
public enum ShareCapture {
    /// The `rawMetadata` key recording the ACT of capture, as distinct from the
    /// `platform` recording the site (092 · S4b).
    public static let capturedViaKey = "capturedVia"

    /// The value that key carries for a share from the phone.
    public static let capturedViaValue = "ios_share"

    /// Host → ``Platform``, mirroring `extension/src/extractors/` and
    /// `extension/src/media-hosts.js`.
    ///
    /// The CDN domains are in here beside the page domains on purpose: an image
    /// shared out of a browser carries the media URL, not the page URL, and
    /// `pbs.twimg.com` names its site exactly as unambiguously as `x.com` does.
    /// Order is irrelevant — no host is a subdomain of another entry.
    ///
    /// `pinterest.co.uk` is listed explicitly rather than matched by a
    /// `pinterest.<anything>` rule, which is the extractor's own choice
    /// (`extension/src/extractors/pinterest.js:19`–`:21`): a rule loose enough to
    /// catch every Pinterest ccTLD is also loose enough to catch
    /// `pinterest.com.example.net`, and the cost of missing one is a `.web` capture
    /// with the URL intact, not a lost share.
    static let hostPlatforms: [(domain: String, platform: Platform)] = [
        ("x.com", .twitter),
        ("twitter.com", .twitter),
        ("t.co", .twitter),
        ("twimg.com", .twitter),
        ("pinterest.com", .pinterest),
        ("pinterest.co.uk", .pinterest),
        ("pin.it", .pinterest),
        ("pinimg.com", .pinterest),
        ("instagram.com", .instagram),
        ("cdninstagram.com", .instagram),
        ("fbcdn.net", .instagram),
        ("cosmos.so", .cosmos),
        ("rednote.com", .rednote),
        ("xiaohongshu.com", .rednote),
        ("rednotecdn.com", .rednote),
    ]

    /// The ``Platform`` a shared URL names, or ``Platform/web``.
    ///
    /// The string is normalized through ``LinkPayload/canonicalURL(_:)`` before its
    /// host is read, which buys two things for one line: a scheme-less `x.com/i/1`
    /// resolves (it prepends `https://`) and the host arrives lowercased. It is used
    /// only to READ the host; what the capture stores is the raw string, because the
    /// ingest funnel is the single canonicalization authority (`Validation.linkURL`).
    ///
    /// **A foreign scheme is rejected before that, not by it.** `canonicalURL`
    /// decides a string is scheme-less by looking for `://`, so `mailto:a@x.com`
    /// becomes `https://mailto:a@x.com` — which parses, with `mailto:a` as userinfo
    /// and `x.com` as the host, and would have made an email address into twitter
    /// provenance. The activation rule means such a string should never arrive, and
    /// that is exactly why the guard is cheap to keep: the case that cannot happen is
    /// the one nobody notices going wrong.
    public static func platform(forURLString raw: String?) -> Platform {
        guard let raw else { return .web }
        if let scheme = URLComponents(string: raw)?.scheme, !isWebScheme(scheme) {
            return .web
        }
        guard let canonical = LinkPayload.canonicalURL(raw),
              let host = URL(string: canonical)?.host()?.lowercased(),
              !host.isEmpty
        else { return .web }
        for entry in hostPlatforms
        where host == entry.domain || host.hasSuffix("." + entry.domain) {
            return entry.platform
        }
        return .web
    }

    /// Whether a URL scheme is one a capture may be built from — the single authority
    /// both the harvest filter and the platform mapping ask (406).
    ///
    /// The two ask it differently and that difference is not an accident.
    /// ``webURLString(_:)`` demands a scheme AND that it pass this; ``platform(forURLString:)``
    /// only refuses a scheme that fails it, because a scheme-less `x.com/i/1` is
    /// something `LinkPayload.canonicalURL` is expected to repair and a shared `URL`
    /// always arrives with a scheme.
    static func isWebScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A shared URL string, if it is a WEB URL — otherwise nil (406, issue 11).
    ///
    /// **This filter exists because `public.file-url` conforms to `public.url`.** An
    /// image shared out of Files arrives with a `file://` attachment beside it, and
    /// storing that as `originalURL` would put a path from a container that no longer
    /// exists into a capture's provenance. A share with no web URL is not a broken
    /// share — it is a photo.
    ///
    /// It lived in the extension until 406, where nothing could test it. It is a
    /// predicate over a string, so it belongs here; the `UTType` conformance check it
    /// sits beside genuinely needs UIKit and stayed.
    public static func webURLString(_ raw: String?) -> String? {
        guard let raw,
              let scheme = URLComponents(string: raw)?.scheme,
              isWebScheme(scheme)
        else { return nil }
        return raw
    }

    /// What a share amounts to, given what the extension managed to pull out of its
    /// item providers — or nil when there is nothing capturable (406, issue 11).
    ///
    /// This is `harvest`'s decision, with the asynchronous Cocoa loading lifted off it
    /// so what remains is a function over three optionals that tests on macOS today:
    ///
    ///   • **Image bytes win over a URL**, and the URL then becomes the image's
    ///     `sourceURL` — an image shared out of a browser carries the media URL beside
    ///     the bytes, and that is where its provenance comes from. Preferring the link
    ///     would throw away the actual picture.
    ///   • **The URL must be a web URL**, per ``webURLString(_:)``. A `file://` is
    ///     dropped rather than becoming provenance, on both branches.
    ///   • **An empty title is no title**, per `TextRules.nonBlank` — a sharing app that
    ///     supplies `""`, or a line of spaces, has supplied no title, and storing one
    ///     would put a blank string where the Mac expects either a title or nothing.
    ///   • **Neither one means nil**, which the caller renders as a lost capture. The
    ///     extension's activation rule should make it unreachable, which is exactly why
    ///     it is decided somewhere a test can reach.
    public static func sharedItem(
        image: PayloadSource?, urlString: String?, title: String? = nil
    ) -> SharedItem? {
        let webURL = webURLString(urlString)
        let title = TextRules.nonBlank(title)
        if let image {
            return .image(bytes: image, sourceURL: webURL, title: title)
        }
        if let webURL {
            return .link(url: webURL, title: title)
        }
        return nil
    }

    /// What a share amounts to once the tier-2 page snapshot is in hand as well — the
    /// whole precedence decision, including the tier-1 case, as one function.
    ///
    /// **Why this exists.** 406 · issue 11 moved four decisions out of the extension's
    /// `harvest` and into ``sharedItem(image:urlString:title:)``, and the doc comment there
    /// says the function "no longer decides anything". Tier 2 then put three decisions back
    /// — a page beats tier 1 outright, arrived bytes beat fetched bytes, no page means tier
    /// 1 — in the one file in the project with no test host. They are pure over four
    /// optionals, so they belong here, and this is the same relocation 406 already performed
    /// on the same function rather than a new mechanism.
    ///
    /// The three rules, in order:
    ///
    ///   • **A page snapshot wins the provenance outright.** The DOM knows the author, the
    ///     post's canonical URL and the tweet id; an item provider's `attributedTitle` and
    ///     the shared URL know none of that. So `urlString` and `title` are DROPPED when a
    ///     page is present — deliberately, and stated here because silently discarding a
    ///     title is exactly the kind of thing that should not live where nothing can assert
    ///     it.
    ///   • **Bytes that ARRIVED with the share still win as the picture.** Long-pressing an
    ///     image in Safari shares that image; re-fetching "the largest image on the page"
    ///     would hand the user a different picture than the one they pressed. This is tier
    ///     1's own image-beats-URL rule applied one level up.
    ///   • **No page is tier 1**, unchanged, through ``sharedItem(image:urlString:title:)``.
    ///
    /// ``ShareResolution/needsMedia(_:)`` is the one outcome this cannot finish, and that is
    /// the point of returning an enum rather than a `SharedItem?`: fetching needs the
    /// network, which needs a process. The caller walks
    /// ``mediaCandidates(for:)`` and folds whatever comes back — including nothing — into
    /// `.page(capture, bytes:)`.
    public static func resolution(
        image: PayloadSource?, urlString: String?, title: String? = nil,
        page: PageCapture? = nil
    ) -> ShareResolution {
        guard let page else {
            guard let item = sharedItem(image: image, urlString: urlString, title: title) else {
                return .nothing
            }
            return .resolved(item)
        }
        if let image { return .resolved(.page(page, bytes: image)) }
        return .needsMedia(page)
    }

    /// The provenance a share carries: the site the content came from, the URL
    /// verbatim, and the stamp saying a phone did this.
    ///
    /// `rawMetadata` is `{ "capturedVia": "ios_share" }` on every share, including
    /// the ones with no URL at all — the act is a fact about the capture, not about
    /// the link.
    public static func provenance(
        urlString: String?, title: String? = nil
    ) -> ProvenanceDTO {
        ProvenanceDTO(
            platform: platform(forURLString: urlString).rawValue,
            originalURL: urlString,
            title: TextRules.nonBlank(title),
            rawMetadata: .object([capturedViaKey: .string(capturedViaValue)]))
    }

    /// A ``SharedItem`` as the capture that goes in the inbox.
    ///
    /// A link becomes a MEDIA-LESS capture — `kind` = `link`, a `LinkPayload` holding
    /// the URL, and no payload file. The title and description stay nil: the host
    /// fills them at drain time from og-tags (092 · S4b, tier 1), and a share sheet
    /// has nothing better to offer than what the sharing app already handed over.
    ///
    /// An image becomes a byte-backed capture — no `kind`, no `payload`, and
    /// crucially `CaptureRequest.image` LEFT NIL: the base64 field is the HTTP
    /// producer's path (092 · S2 · D-d), and the bytes here travel to the `.bin`
    /// sidecar instead.
    public static func draft(
        for item: SharedItem, collectionID: UUID? = nil
    ) -> ShareCaptureDraft {
        switch item {
        case let .link(url, title):
            return ShareCaptureDraft(
                request: CaptureRequest(
                    provenance: provenance(urlString: url, title: title),
                    collectionId: collectionID,
                    kind: AssetKind.link.rawValue,
                    payload: AssetPayload(link: LinkPayload(url: url))),
                payload: nil)
        case let .image(bytes, sourceURL, title):
            return ShareCaptureDraft(
                request: CaptureRequest(
                    provenance: provenance(urlString: sourceURL, title: title),
                    collectionId: collectionID),
                payload: bytes)

        case let .page(capture, bytes):
            // The provenance is the DOM's either way — that is the whole point of tier 2,
            // and it is the half that survives when the picture does not.
            //
            // With bytes: a byte-backed capture, identical in shape to a photo share, so
            // the drain, the archive and the Mac need nothing new for it (092 · S6c).
            // Without: the same link capture tier 1 makes, carrying provenance tier 1
            // could not have known — the author, the post's own URL, the tweet id.
            guard let bytes else {
                let url = capture.provenance.originalURL
                return ShareCaptureDraft(
                    request: CaptureRequest(
                        provenance: capture.provenance,
                        collectionId: collectionID,
                        kind: url == nil ? nil : AssetKind.link.rawValue,
                        payload: url.map { AssetPayload(link: LinkPayload(url: $0)) }),
                    payload: nil)
            }
            return ShareCaptureDraft(
                request: CaptureRequest(
                    provenance: capture.provenance, collectionId: collectionID),
                payload: bytes)
        }
    }

    /// The URLs to try for a page's media, best first.
    ///
    /// Two at most, and the second exists because the first is a REWRITE: `/originals/`
    /// can 404 on Pinterest and `name=orig` can be refused, while the size the page
    /// actually rendered is known to load. A caller that gets nothing from either has a
    /// text-only post or a fetch that failed, and both mean a link capture.
    ///
    /// Filtered to http(s) here rather than at the fetch, because a `javascript:` or
    /// `data:` src reaching a URLSession is a decision, not an accident — and this is the
    /// side of the boundary that tests can see.
    ///
    /// **This filter is not the wall** (098 · finding 2). It is a scheme check over a
    /// string, and it was the ONLY thing standing between a page-chosen URL and a
    /// `URLSession` until P5. What each candidate then has to pass is
    /// ``fetchableURL(for:through:)`` — the same ``SSRFGuard`` the Mac's fetches use — which
    /// re-checks the scheme itself, because a security boundary that trusts its caller to
    /// have filtered is not one.
    public static func mediaCandidates(for capture: PageCapture) -> [String] {
        [capture.mediaURL, capture.mediaURLFallback]
            .compactMap { $0 }
            .filter { isWebScheme(URLComponents(string: $0)?.scheme) }
    }
}
