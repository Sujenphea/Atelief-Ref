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
        ])
    func unmappedHostsAreWeb(urlString: String) {
        #expect(ShareCapture.platform(forURLString: urlString) == .web)
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

    // MARK: - The capturedVia stamp

    @Test("every share stamps rawMetadata.capturedVia = ios_share, URL or no URL")
    func capturedViaStamp() {
        let stamp = JSONValue.object(["capturedVia": .string("ios_share")])

        let link = ShareCapture.draft(for: .link(url: "https://x.com/user/status/1"))
        #expect(link.request.provenance.rawMetadata == stamp)

        let image = ShareCapture.draft(for: .image(bytes: CaptureFixtures.png()))
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
            for: .image(bytes: bytes, sourceURL: "https://pbs.twimg.com/media/Ab1.jpg"))

        #expect(draft.payload == bytes)
        #expect(draft.request.image == nil)
        #expect(draft.request.kind == nil)
        #expect(draft.request.payload == nil)
        #expect(draft.request.provenance.platform == "twitter")
    }

    @Test("an image with no source URL still captures, as .web with no originalURL")
    func imageWithoutSourceURL() {
        let draft = ShareCapture.draft(for: .image(bytes: CaptureFixtures.png()))
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
            for: .image(bytes: CaptureFixtures.png(), sourceURL: "https://x.com/i/1"))
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
        let image = ShareCapture.draft(for: .image(bytes: bytes))
        let imageRecord = try writer.write(image.request, payload: image.payload)
        #expect(imageRecord.payloadFile == "\(imageRecord.id.uuidString).bin")
        #expect(layout.isComplete(imageRecord))
        #expect(try Data(contentsOf: #require(layout.payloadURL(for: imageRecord))) == bytes)

        #expect(try layout.pendingRecordURLs().count == 2)
    }
}
