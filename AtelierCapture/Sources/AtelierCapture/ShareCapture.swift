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
    /// A web URL — a media-less `link` capture. The Mac resolves og-tags at drain
    /// time through the existing `PageResolver`, so nothing is fetched here.
    case link(url: String, title: String? = nil)
    /// Image bytes — on disk or, when a provider offered no file representation, in
    /// memory — with the page or media URL they came from when the share carried one
    /// (a photo shared out of Photos carries none).
    case image(bytes: PayloadSource, sourceURL: String? = nil, title: String? = nil)
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

    /// A title worth recording, or nil — the one place emptiness is decided.
    ///
    /// A sharing app that supplies `""`, or a line of spaces, has supplied no title;
    /// storing one would put a blank string where the Mac expects either a title or
    /// nothing. Trimming rather than merely testing, because a title arriving with a
    /// trailing newline is the same title.
    static func normalizedTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
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
    ///   • **An empty title is no title**, per ``normalizedTitle(_:)``.
    ///   • **Neither one means nil**, which the caller renders as a lost capture. The
    ///     extension's activation rule should make it unreachable, which is exactly why
    ///     it is decided somewhere a test can reach.
    public static func sharedItem(
        image: PayloadSource?, urlString: String?, title: String? = nil
    ) -> SharedItem? {
        let webURL = webURLString(urlString)
        let title = normalizedTitle(title)
        if let image {
            return .image(bytes: image, sourceURL: webURL, title: title)
        }
        if let webURL {
            return .link(url: webURL, title: title)
        }
        return nil
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
            title: normalizedTitle(title),
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
        }
    }
}
