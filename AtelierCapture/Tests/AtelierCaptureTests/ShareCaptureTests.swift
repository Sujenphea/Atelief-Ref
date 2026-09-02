// AtelierCapture tests — the share extension's decisions, made where they can be
// tested (092 · S4b-ii).
//
// The extension target has no test host and this slice did not invent one. That is
// only defensible if the extension contains no decisions, so these tests are the
// other half of that bargain: the host→``Platform`` table, the `capturedVia` stamp,
// and the whole ``SharedItem`` → ``CaptureRequest`` construction are asserted here,
// on macOS, with no device and no simulator.
//
// The two that matter most are negative. `evilx.com` must not be twitter — the match
// is `hostIs`, and a `contains` would have made every lookalike domain a false
// positive that lands in the library as real provenance. And an image capture must
// leave `CaptureRequest.image` nil: the moment that field gets filled on this path,
// the sidecar is carrying the bytes twice and the extension is holding a base64
// string of a 4000px photo, which is the failure 092 · S2 was designed around.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore

@Suite("ShareCapture (092 S4b-ii)")
struct ShareCaptureTests {

    // MARK: - Host → Platform

    @Test(
        "every mapped host resolves to its platform, on the bare domain and a subdomain",
        arguments: [
            ("https://x.com/user/status/1", Platform.twitter),
            ("https://mobile.twitter.com/user/status/1", Platform.twitter),
            ("https://t.co/abcdef", Platform.twitter),
            ("https://pbs.twimg.com/media/Ab1.jpg", Platform.twitter),
            ("https://www.pinterest.com/pin/12345/", Platform.pinterest),
            ("https://www.pinterest.co.uk/pin/12345/", Platform.pinterest),
            ("https://pin.it/2xYz", Platform.pinterest),
            ("https://i.pinimg.com/originals/aa/bb.jpg", Platform.pinterest),
            ("https://www.instagram.com/p/Cxyz/", Platform.instagram),
            ("https://scontent-lhr8-1.cdninstagram.com/v/t51.jpg", Platform.instagram),
            ("https://scontent.fbcdn.net/v/t51.jpg", Platform.instagram),
            ("https://cosmos.so/e/123456", Platform.cosmos),
            ("https://www.rednote.com/explore/abc", Platform.rednote),
            ("https://www.xiaohongshu.com/explore/abc", Platform.rednote),
            ("https://sns-web-i10.rednotecdn.com/1/s/key", Platform.rednote),
        ])
    func mappedHosts(urlString: String, expected: Platform) {
        #expect(ShareCapture.platform(forURLString: urlString) == expected)
    }

    @Test(
        "anything unrecognized is .web — including lookalikes a substring match would take",
        arguments: [
            "https://example.com/a/b",
            "https://news.ycombinator.com/item?id=1",
            // The hostIs contract: a suffix match must be on a LABEL boundary.
            "https://evilx.com/",
            "https://notpinterest.com/pin/1",
            "https://x.com.example.net/phish",
            "https://cosmos.so.example.net/",
            // A lookalike SUFFIX: the listed domain with more after it (457).
            "https://x.co/",
            "https://x.comm/",
            "https://pinterest.com.au/pin/1",
            "https://sub.x.com.evil.net/",
            // Userinfo: the listed host before an `@` is not the host (457).
            "https://x.com@evil.com/",
            "https://x.com:443@evil.net/",
            // An IDN host is its punycode, which is not a listed domain (457).
            "https://xn--80ak6aa92e.com/",
            "https://пример.рф/a",
            // A percent-encoded dot decodes into a lookalike suffix, not into x.com.
            "https://x.com%2Eevil.net/",
        ])
    func unmappedHostsAreWeb(urlString: String) {
        #expect(ShareCapture.platform(forURLString: urlString) == .web)
    }

    /// The other side of the userinfo case: the HOST is what is read, so credentials in
    /// front of a real x.com do not hide it.
    @Test("userinfo in front of a mapped host does not unmap it")
    func userinfoBeforeMappedHost() {
        #expect(ShareCapture.platform(forURLString: "https://user:pw@x.com/ada/status/1") == .twitter)
    }

    /// Foundation IDNA-maps a fullwidth `ｘ.com` to `x.com` before the host is read —
    /// which is what every browser does with it, so it IS x.com and the mapping is
    /// pinned rather than argued with. A visually confusable host that does NOT map
    /// (Cyrillic `х`) stays punycode and stays `.web`, in the case above.
    @Test("an IDN host that maps to a listed domain is that domain")
    func idnMappingToMappedHost() {
        #expect(ShareCapture.platform(forURLString: "https://ｘ.com/ada/status/1") == .twitter)
    }

    @Test("a scheme-less host still resolves — canonicalURL supplies https://")
    func schemeLessHost() {
        #expect(ShareCapture.platform(forURLString: "x.com/user/status/1") == .twitter)
        #expect(ShareCapture.platform(forURLString: "www.pinterest.com/pin/1") == .pinterest)
    }

    @Test("the host is matched case-insensitively")
    func hostCaseIsIrrelevant() {
        #expect(ShareCapture.platform(forURLString: "HTTPS://X.COM/User/Status/1") == .twitter)
    }

    @Test(
        "a malformed, non-web or absent URL is .web rather than a guess",
        arguments: [
            "",
            "   ",
            "not a url at all",
            "mailto:someone@x.com",
            "file:///Users/someone/photo.jpg",
            "javascript:alert(1)",
            "https://",
        ])
    func malformedURLsAreWeb(urlString: String) {
        #expect(ShareCapture.platform(forURLString: urlString) == .web)
    }

    @Test("a nil URL — an image shared out of Photos — is .web")
    func absentURLIsWeb() {
        #expect(ShareCapture.platform(forURLString: nil) == .web)
    }

    // MARK: - The web-URL filter (406, issue 11)
    //
    // This filter used to live in `ShareViewController.loadWebURL`, where nothing could
    // reach it. It is the reason a photo shared out of Files does not acquire a
    // `file:///private/var/mobile/Containers/…` as its provenance: `public.file-url`
    // conforms to `public.url`, so the attachment arrives on the same code path a web
    // URL does.

    @Test(
        "an http(s) URL survives the filter verbatim",
        arguments: [
            "https://www.pinterest.com/pin/12345/",
            "http://example.com/a",
            "HTTPS://X.COM/User/Status/1",
            "https://x.com/user/status/1?utm_source=share#top",
        ])
    func webURLsSurvive(urlString: String) {
        #expect(ShareCapture.webURLString(urlString) == urlString)
    }

    @Test(
        "anything that is not a web URL is dropped rather than stored as provenance",
        arguments: [
            // The one this filter exists for: an image shared out of Files.
            "file:///private/var/mobile/Containers/Data/tmp/photo.jpg",
            "file:///Users/someone/photo.jpg",
            "mailto:someone@x.com",
            "javascript:alert(1)",
            "data:image/png;base64,AAAA",
            "ftp://example.com/a.jpg",
            // No scheme at all. A `URL` out of an item provider always has one, so this
            // is the shape a malformed or hand-built string takes.
            "example.com/a",
            "/private/var/tmp/photo.jpg",
            "",
            "   ",
            "not a url at all",
            "ht tp://example.com",
        ])
    func nonWebURLsAreDropped(urlString: String) {
        #expect(ShareCapture.webURLString(urlString) == nil)
    }

    @Test("no URL at all is no URL — an image shared out of Photos")
    func absentURLIsDropped() {
        #expect(ShareCapture.webURLString(nil) == nil)
    }

    // MARK: - What a share amounts to (406, issue 11)
    //
    // `harvest`'s four decisions, lifted out of the extension where no test could reach
    // them. The controller now loads three optionals and asks this.

    @Test("image bytes win over a URL, and the URL becomes the image's sourceURL")
    func imageWinsOverURL() throws {
        let bytes = CaptureFixtures.png()
        let item = try #require(
            ShareCapture.sharedItem(
                image: .data(bytes), urlString: "https://x.com/user/status/1",
                title: "A post"))

        #expect(item == .image(
            bytes: .data(bytes), sourceURL: "https://x.com/user/status/1", title: "A post"))
        // …and it is genuinely a byte-backed capture, not a link that kept its bytes.
        let draft = ShareCapture.draft(for: item)
        #expect(draft.payload == .data(bytes))
        #expect(draft.request.kind == nil)
        #expect(draft.request.provenance.platform == "twitter")
        #expect(draft.request.provenance.originalURL == "https://x.com/user/status/1")
    }

    @Test("a file source wins over a URL exactly as bytes do — the two paths decide alike")
    func fileImageWinsOverURL() throws {
        let url = URL(fileURLWithPath: "/private/var/tmp/shared.heic")
        #expect(
            ShareCapture.sharedItem(
                image: .fileURL(url), urlString: "https://cosmos.so/e/1")
                == .image(bytes: .fileURL(url), sourceURL: "https://cosmos.so/e/1"))
    }

    @Test("a URL with no image becomes a link")
    func urlAloneBecomesALink() {
        #expect(
            ShareCapture.sharedItem(image: nil, urlString: "https://cosmos.so/e/1")
                == .link(url: "https://cosmos.so/e/1"))
    }

    @Test("a file:// URL is not provenance, on either branch")
    func fileURLsAreNotProvenance() {
        let shared = "file:///private/var/mobile/Containers/Data/tmp/photo.jpg"
        // With an image: the capture survives, without a bogus originalURL.
        #expect(
            ShareCapture.sharedItem(image: .data(CaptureFixtures.png()), urlString: shared)
                == .image(bytes: .data(CaptureFixtures.png()), sourceURL: nil))
        // Without one: there is nothing left to capture, which is the honest answer.
        #expect(ShareCapture.sharedItem(image: nil, urlString: shared) == nil)
    }

    @Test("neither image nor web URL is nil — the lost-capture card, decided where it is testable")
    func nothingCapturableIsNil() {
        #expect(ShareCapture.sharedItem(image: nil, urlString: nil, title: nil) == nil)
        #expect(ShareCapture.sharedItem(image: nil, urlString: nil, title: "A page") == nil)
        #expect(ShareCapture.sharedItem(image: nil, urlString: "mailto:a@x.com") == nil)
    }

    @Test("a title rides onto whichever item results, and an empty one is no title")
    func titleNormalization() {
        #expect(
            ShareCapture.sharedItem(image: nil, urlString: "https://example.com/a", title: "A page")
                == .link(url: "https://example.com/a", title: "A page"))
        #expect(
            ShareCapture.sharedItem(
                image: .data(CaptureFixtures.png()), urlString: nil, title: "A photo")
                == .image(bytes: .data(CaptureFixtures.png()), sourceURL: nil, title: "A photo"))

        // Empty, whitespace-only, and surrounded by whitespace: the first two are no
        // title at all, the third is the same title without the noise.
        for blank in ["", "   ", "\n\t "] {
            #expect(
                ShareCapture.sharedItem(image: nil, urlString: "https://example.com/a", title: blank)
                    == .link(url: "https://example.com/a", title: nil))
        }
        #expect(
            ShareCapture.sharedItem(
                image: nil, urlString: "https://example.com/a", title: "  A page\n")
                == .link(url: "https://example.com/a", title: "A page"))
    }

    // MARK: - The capturedVia stamp

    @Test("every share stamps rawMetadata.capturedVia = ios_share, URL or no URL")
    func capturedViaStamp() {
        let stamp = JSONValue.object(["capturedVia": .string("ios_share")])

        let link = ShareCapture.draft(for: .link(url: "https://x.com/user/status/1"))
        #expect(link.request.provenance.rawMetadata == stamp)

        let image = ShareCapture.draft(for: .image(bytes: .data(CaptureFixtures.png())))
        #expect(image.request.provenance.rawMetadata == stamp)

        // The constants are the contract the Mac reads back; assert the strings, not
        // just that the two agree with each other.
        #expect(ShareCapture.capturedViaKey == "capturedVia")
        #expect(ShareCapture.capturedViaValue == "ios_share")
    }

    @Test("no Platform case was added for sharing — the act is metadata, the site is platform")
    func sharingIsNotAPlatform() {
        let draft = ShareCapture.draft(for: .link(url: "https://example.com/a"))
        #expect(draft.request.provenance.platform == "web")
        #expect(!Platform.allCases.contains { $0.rawValue.contains("share") })
    }

    // MARK: - SharedItem → CaptureRequest

    @Test("a shared URL becomes a media-less link capture with no payload file")
    func linkDraft() throws {
        let url = "https://www.pinterest.com/pin/12345/"
        let draft = ShareCapture.draft(for: .link(url: url))

        #expect(draft.payload == nil)
        #expect(draft.request.kind == "link")
        #expect(draft.request.payload?.link?.url == url)
        #expect(draft.request.image == nil)
        #expect(draft.request.provenance.platform == "pinterest")
        #expect(draft.request.provenance.originalURL == url)
        // The title/description stay unresolved: the Mac fills them from og-tags at
        // drain time (092 · S4b, tier 1). The extension fetches nothing.
        #expect(draft.request.payload?.link?.title == nil)
        #expect(draft.request.payload?.link?.description == nil)
    }

    @Test("the URL is stored verbatim — the ingest funnel is the canonicalization authority")
    func linkURLIsNotCanonicalizedHere() {
        let raw = "https://x.com/user/status/1?utm_source=share#top"
        let draft = ShareCapture.draft(for: .link(url: raw))
        #expect(draft.request.payload?.link?.url == raw)
        #expect(draft.request.provenance.originalURL == raw)
        // …and the canonical form the host will derive is genuinely different, so
        // this test is asserting a choice rather than a coincidence.
        #expect(LinkPayload.canonicalURL(raw) != raw)
    }

    @Test("a shared image becomes byte-backed with the base64 image field left nil")
    func imageDraft() {
        let bytes = CaptureFixtures.png()
        let draft = ShareCapture.draft(
            for: .image(bytes: .data(bytes), sourceURL: "https://pbs.twimg.com/media/Ab1.jpg"))

        #expect(draft.payload == .data(bytes))
        #expect(draft.request.image == nil)
        #expect(draft.request.kind == nil)
        #expect(draft.request.payload == nil)
        #expect(draft.request.provenance.platform == "twitter")
    }

    @Test("an image with no source URL still captures, as .web with no originalURL")
    func imageWithoutSourceURL() {
        let draft = ShareCapture.draft(for: .image(bytes: .data(CaptureFixtures.png())))
        #expect(draft.request.provenance.platform == "web")
        #expect(draft.request.provenance.originalURL == nil)
        #expect(draft.payload != nil)
    }

    @Test("a title the sharing app supplied rides along; an empty one does not")
    func titlePassThrough() {
        let titled = ShareCapture.draft(
            for: .link(url: "https://example.com/a", title: "A page"))
        #expect(titled.request.provenance.title == "A page")

        let untitled = ShareCapture.draft(for: .link(url: "https://example.com/a", title: ""))
        #expect(untitled.request.provenance.title == nil)
    }

    @Test("a target collection is carried through when one is supplied, absent otherwise")
    func collectionTarget() {
        let id = UUID()
        #expect(
            ShareCapture.draft(
                for: .link(url: "https://example.com/a"), collectionID: id)
                .request.collectionId == id)
        #expect(
            ShareCapture.draft(for: .link(url: "https://example.com/a"))
                .request.collectionId == nil)
    }

    // MARK: - The seam actually holds

    @Test("both drafts survive the funnel the host will run them through")
    func draftsDecode() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // The media-less path: no sidecar, so the drain uses `decodeInput`.
        let link = ShareCapture.draft(for: .link(url: "https://cosmos.so/e/1"))
        guard case .content(let decodedLink) = try CaptureDecoder.decodeInput(
            link.request, now: now) else {
            Issue.record("a shared link should decode as a media-less content capture")
            return
        }
        #expect(decodedLink.draft.kind == .link)
        #expect(decodedLink.provenance.platform == .cosmos)
        #expect(
            decodedLink.provenance.rawMetadata
                == .object(["capturedVia": .string("ios_share")]))

        // The byte-backed path: a sidecar exists, so the drain uses `decodeFileInput`.
        let image = ShareCapture.draft(
            for: .image(bytes: .data(CaptureFixtures.png()), sourceURL: "https://x.com/i/1"))
        guard case .bytes(let decodedImage) = try CaptureDecoder.decodeFileInput(
            image.request, now: now) else {
            Issue.record("a shared image should decode as a byte-backed capture")
            return
        }
        #expect(decodedImage.provenance.platform == .twitter)
    }

    @Test("a draft written by InboxWriter lands as the two files the drain expects")
    func draftRoundTripsThroughTheWriter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareCaptureTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = InboxLayout(libraryRoot: root)
        let writer = InboxWriter(libraryRoot: root)

        let link = ShareCapture.draft(for: .link(url: "https://x.com/user/status/1"))
        let linkRecord = try writer.write(link.request, payload: link.payload)
        #expect(linkRecord.payloadFile == nil)
        #expect(layout.isComplete(linkRecord))

        let bytes = CaptureFixtures.png()
        let image = ShareCapture.draft(for: .image(bytes: .data(bytes)))
        let imageRecord = try writer.write(image.request, payload: image.payload)
        #expect(imageRecord.payloadFile == "\(imageRecord.id.uuidString).bin")
        #expect(layout.isComplete(imageRecord))
        #expect(try Data(contentsOf: #require(layout.payloadURL(for: imageRecord))) == bytes)

        #expect(try layout.pendingRecordURLs().count == 2)
    }

    // MARK: - Tier 2 (092 · S4b)

    /// With bytes, a preprocessed page is a capture the rest of the program already
    /// knows: the SAME shape a photo share produces, so the drain, the archive and the
    /// Mac need nothing new for it. The only difference is that the provenance is richer
    /// than any share sheet could have supplied.
    @Test("a fetched page capture is an ordinary byte-backed capture, richly labelled")
    func pageWithBytesIsAByteCapture() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/5",
            metas: ["og:description": "a stair"],
            media: [.init(kind: .image, src: "https://pbs.twimg.com/media/A?name=small",
                          width: 900, height: 900, articleIndex: 0)]))

        let draft = ShareCapture.draft(for: .page(capture, bytes: .data(Data("x".utf8))))

        #expect(draft.payload != nil)
        // A byte capture carries no `kind` and no payload — the bytes ARE the content.
        #expect(draft.request.kind == nil)
        #expect(draft.request.payload == nil)
        // …and the base64 field stays nil, as on every inbox capture (092 · S2 · D-d).
        #expect(draft.request.image == nil)
        #expect(draft.request.provenance.platform == "twitter")
        #expect(draft.request.provenance.authorHandle == "@ada")
        #expect(draft.request.provenance.title == "a stair")
    }

    /// **The degradation that makes fetching safe to attempt.** A text-only post, a
    /// media URL that 404s and a phone with no signal all arrive here, and all three
    /// produce the tier-1 capture — carrying provenance tier 1 could not have known.
    @Test("a page capture with no bytes degrades to a link that kept its provenance")
    func pageWithoutBytesDegradesToALink() throws {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/5?s=20",
            metas: ["og:description": "a thought"]))

        let draft = ShareCapture.draft(for: .page(capture))

        #expect(draft.payload == nil)
        #expect(draft.request.kind == AssetKind.link.rawValue)
        #expect(draft.request.payload?.link?.url == "https://x.com/ada/status/5")
        // The half tier 1 never had.
        #expect(draft.request.provenance.authorHandle == "@ada")
        #expect(draft.request.provenance.title == "a thought")
        #expect(draft.request.provenance.platform == "twitter")
    }

    /// The fetch order, and the filter on it. A `javascript:` src reaching a URLSession
    /// would be a decision rather than an accident, so it is refused on this side of the
    /// boundary where a test can see it.
    @Test("media candidates are best-first, http(s) only")
    func mediaCandidatesAreFiltered() {
        let both = PageCapture(
            provenance: ProvenanceDTO(platform: "pinterest"),
            mediaURL: "https://i.pinimg.com/originals/a.jpg",
            mediaURLFallback: "https://i.pinimg.com/736x/a.jpg")
        #expect(ShareCapture.mediaCandidates(for: both) == [
            "https://i.pinimg.com/originals/a.jpg", "https://i.pinimg.com/736x/a.jpg",
        ])

        let hostile = PageCapture(
            provenance: ProvenanceDTO(platform: "web"),
            mediaURL: "javascript:alert(1)",
            mediaURLFallback: "data:image/png;base64,AAAA")
        #expect(ShareCapture.mediaCandidates(for: hostile).isEmpty)

        #expect(ShareCapture.mediaCandidates(
            for: PageCapture(provenance: ProvenanceDTO(platform: "web"))).isEmpty)
    }

    // MARK: - The tier-2 precedence rules

    /// These four cover the three rules that lived in `ShareViewController.harvest` until
    /// this suite could reach them. Each one is a sentence that file used to assert only by
    /// executing, in a process with no test host.

    /// Rule 1, and the half of it that is easy to miss: a page does not merely WIN, it
    /// discards. The shared URL and the sharing app's title are dropped on the floor —
    /// which is right, because the DOM knows the author and the canonical permalink and an
    /// `attributedTitle` knows neither, but it is a real loss and it should be pinned.
    @Test("a page snapshot beats the shared URL and title outright")
    func pageBeatsTierOne() {
        let capture = PageCapture(
            provenance: ProvenanceDTO(
                platform: "twitter", originalURL: "https://x.com/a/status/1", title: "from the DOM"),
            mediaURL: "https://pbs.twimg.com/media/a.jpg?name=orig")

        let resolution = ShareCapture.resolution(
            image: nil,
            urlString: "https://x.com/home",
            title: "from the share sheet",
            page: capture)

        #expect(resolution == .needsMedia(capture))
    }

    /// Rule 2. Long-pressing an image in Safari shares THAT image; re-fetching the largest
    /// thing on the page would hand back a different picture. So arrived bytes short-circuit
    /// the fetch entirely — `.resolved`, not `.needsMedia` — while the provenance still
    /// comes from the DOM.
    @Test("bytes that arrived with the share beat the media URL the extractor found")
    func arrivedBytesBeatTheFetch() {
        let capture = PageCapture(
            provenance: ProvenanceDTO(platform: "twitter", originalURL: "https://x.com/a/status/1"),
            mediaURL: "https://pbs.twimg.com/media/other.jpg?name=orig")
        let bytes = PayloadSource.data(Data([0xFF, 0xD8, 0xFF]))

        #expect(
            ShareCapture.resolution(
                image: bytes, urlString: "https://x.com/a/status/1", page: capture)
                == .resolved(.page(capture, bytes: bytes)))
    }

    /// Rule 3: with no page, nothing changes. The tier-1 answer is exactly
    /// `sharedItem`'s, which is what keeps this function a router rather than a second
    /// implementation of rules that already have one.
    @Test("no page snapshot is tier 1, unchanged")
    func noPageIsTierOne() {
        let bytes = PayloadSource.data(Data([0x89, 0x50]))

        #expect(
            ShareCapture.resolution(image: bytes, urlString: "https://x.com/a/status/1")
                == .resolved(
                    ShareCapture.sharedItem(
                        image: bytes, urlString: "https://x.com/a/status/1")!))

        #expect(
            ShareCapture.resolution(image: nil, urlString: "https://cosmos.so/e/1", title: " ")
                == .resolved(.link(url: "https://cosmos.so/e/1", title: nil)))
    }

    /// The case the activation rule should make unreachable, decided somewhere a test can
    /// reach it. A `file://` is not provenance, so a share carrying only one amounts to
    /// nothing — and `.nothing` is what lets the caller tell "no capture" apart from "a
    /// capture with no picture", which is the distinction the over-cap rethrow turns on.
    @Test("no page, no bytes and no web URL is nothing")
    func nothingCapturable() {
        #expect(ShareCapture.resolution(image: nil, urlString: nil) == .nothing)
        #expect(
            ShareCapture.resolution(image: nil, urlString: "file:///tmp/a.jpg") == .nothing)
    }
}
