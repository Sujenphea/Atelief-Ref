//
//  PageExtractorTests.swift
//  AtelierCaptureTests
//
//  092 · S4b tier 2 — reading a page Safari preprocessed.
//
//  These are the tests the browser extension's `extractors.test.js` is, ported to the
//  shape the phone has: no right-clicked element, no video frame, one media URL. The
//  fixtures are hand-composed rather than captured, for the reason that file gives — a
//  fixture trimmed to exercise one rule says which rule broke, where a real page snapshot
//  says only "something changed".
//
//  The rules worth stating, because each is a bug that has actually happened somewhere:
//
//  · A tweet's photo comes from the FOCAL article, never from a reply.
//  · A text-only tweet stays image-less rather than adopting X's generic card.
//  · A pin's image is the BIGGEST pinimg on the page, not the first.
//  · An SPA's live URL beats its canonical, which is routinely stale.
//

import Foundation
import Testing

@testable import AtelierCapture

@Suite("PageExtractor: a preprocessed page becomes provenance (092 S4b tier 2)")
struct PageExtractorTests {

    // MARK: - Twitter

    @Test("A photo tweet yields the focal photo at original resolution")
    func twitterPhoto() throws {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/1234567890?s=20",
            title: "Ada on X",
            metas: ["og:description": "a thing I made"],
            media: [
                .init(kind: .image, src: "https://pbs.twimg.com/profile_images/1/a.jpg",
                      width: 48, height: 48, articleIndex: 0),
                .init(kind: .image, src: "https://pbs.twimg.com/media/AAA?format=jpg&name=medium",
                      width: 1200, height: 900, articleIndex: 0),
            ]))

        #expect(capture.provenance.platform == "twitter")
        // The query is dropped and the status URL is the identity.
        #expect(capture.provenance.originalURL == "https://x.com/ada/status/1234567890")
        #expect(capture.provenance.authorHandle == "@ada")
        #expect(capture.provenance.title == "a thing I made")
        // `name=medium` → `name=orig`; the rendered size stays as the fallback.
        #expect(capture.mediaURL?.contains("name=orig") == true)
        #expect(capture.mediaURLFallback?.contains("name=medium") == true)
        #expect(rawMetadata(capture)["tweetId"] == "1234567890")
    }

    /// The scoping rule, stated as the failure it prevents: the focal tweet has no photo,
    /// a REPLY does, and the capture must not take it.
    @Test("A text-only tweet does not borrow a reply's photo")
    func twitterTextOnlyIgnoresReplies() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/99",
            metas: ["og:image": "https://pbs.twimg.com/card_img/generic.jpg"],
            media: [
                .init(kind: .image, src: "https://pbs.twimg.com/profile_images/2/b.jpg",
                      width: 48, height: 48, articleIndex: 0),
                .init(kind: .image, src: "https://pbs.twimg.com/media/REPLY?name=small",
                      width: 800, height: 600, articleIndex: 1),
            ])
        )

        // Image-less, and specifically NOT X's generic summary-card image.
        #expect(capture.mediaURL == nil)
        #expect(capture.provenance.platform == "twitter")
    }

    /// …and the other half of that rule: with no article structure there is nothing to
    /// scope to, so `og:image` is allowed to stand in rather than yielding nothing.
    @Test("With no article structure, og:image stands in")
    func twitterFallsBackWithoutArticles() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://twitter.com/ada/status/99",
            metas: ["og:image": "https://pbs.twimg.com/card_img/generic.jpg"]))

        #expect(capture.mediaURL == "https://pbs.twimg.com/card_img/generic.jpg")
    }

    /// The bug 098 · finding 12 named: the first path segment of ANY X URL became the
    /// author, so sharing the feed recorded `@home`. A handle exists only on a status
    /// page; everything else is a page with no post and no author.
    @Test(
        "A non-status X page yields no handle and no tweet id",
        arguments: [
            "https://x.com/home",
            "https://x.com/i/bookmarks",
            "https://x.com/explore",
            "https://x.com/ada",
            "https://x.com/ada/with_replies",
            "https://x.com/search?q=stairs",
            "https://x.com/",
        ])
    func twitterNonStatusPageHasNoHandle(url: String) {
        let capture = PageExtractor.capture(from: PageHarvest(url: url, title: "X"))

        #expect(capture.provenance.platform == "twitter")
        #expect(capture.provenance.authorHandle == nil, "\(url)")
        #expect(rawMetadata(capture)["tweetId"] == nil, "\(url)")
    }

    /// `i` is X's reserved namespace, not an account: `/i/status/<id>` is a real
    /// permalink shape (notifications link to it) and carries a tweet id but no author.
    @Test("An /i/status/ permalink keeps its tweet id and yields no handle")
    func twitterReservedNamespaceIsNotAHandle() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/i/status/4242"))

        #expect(capture.provenance.authorHandle == nil)
        #expect(rawMetadata(capture)["tweetId"] == "4242")
    }

    /// The other direction of the same rule: a feed URL with a status canonical is a
    /// status page, and the handle comes from the candidate that is one.
    @Test("A status canonical behind a feed URL still yields the handle")
    func twitterHandleFromCanonicalStatus() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/home", canonical: "https://x.com/ada/status/77"))

        #expect(capture.provenance.originalURL == "https://x.com/ada/status/77")
        #expect(capture.provenance.authorHandle == "@ada")
        #expect(rawMetadata(capture)["tweetId"] == "77")
    }

    @Test("A video tweet yields its poster, since there is no still on the server")
    func twitterVideoPoster() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/7",
            media: [
                .init(kind: .videoPoster,
                      src: "https://pbs.twimg.com/ext_tw_video_thumb/7/img/x.jpg",
                      width: 1280, height: 720, articleIndex: 0)
            ]))

        #expect(capture.mediaURL == "https://pbs.twimg.com/ext_tw_video_thumb/7/img/x.jpg")
    }

    // MARK: - Pinterest

    @Test("A pin yields the largest pinimg image, at /originals/")
    func pinterestLargest() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://www.pinterest.com/pin/8675309/",
            metas: ["og:site_name": "Pinterest", "og:title": "A concrete stair"],
            media: [
                .init(kind: .image, src: "https://i.pinimg.com/236x/thumb.jpg",
                      width: 236, height: 236),
                .init(kind: .image, src: "https://i.pinimg.com/736x/hero.jpg",
                      width: 736, height: 1100),
                .init(kind: .image, src: "https://s.pinimg.com/logo.png",
                      width: 2000, height: 2000),
            ]))

        #expect(capture.provenance.platform == "pinterest")
        #expect(capture.provenance.originalURL == "https://www.pinterest.com/pin/8675309/")
        #expect(capture.provenance.authorName == "Pinterest")
        #expect(capture.provenance.title == "A concrete stair")
        // The biggest i.pinimg — and NOT the enormous s.pinimg share logo, which the host
        // pattern excludes.
        #expect(capture.mediaURL == "https://i.pinimg.com/originals/hero.jpg")
        #expect(capture.mediaURLFallback == "https://i.pinimg.com/736x/hero.jpg")
        #expect(rawMetadata(capture)["pinId"] == "8675309")
    }

    /// The rule stated in `largestMedia`'s own comment: `max(by:)` returns the LAST
    /// maximal element, and a page whose images all report 0×0 (lazy-loaded, never laid
    /// out) would then yield its footer logo. Ties go to DOM order.
    @Test("largestMedia breaks a tie by DOM order, not by last-wins")
    func largestMediaTieGoesToDOMOrder() {
        let unlaidOut = PageHarvest(media: [
            .init(kind: .image, src: "https://i.pinimg.com/736x/first.jpg"),
            .init(kind: .image, src: "https://i.pinimg.com/736x/second.jpg"),
            .init(kind: .image, src: "https://i.pinimg.com/736x/footer-logo.jpg"),
        ])
        #expect(PageExtractor.largestMedia(unlaidOut, matching: "i.pinimg.com")?.src
            == "https://i.pinimg.com/736x/first.jpg")

        let equal = PageHarvest(media: [
            .init(kind: .image, src: "https://i.pinimg.com/736x/a.jpg", width: 500, height: 500),
            .init(kind: .image, src: "https://i.pinimg.com/736x/b.jpg", width: 500, height: 500),
        ])
        #expect(PageExtractor.largestMedia(equal, matching: "i.pinimg.com")?.src
            == "https://i.pinimg.com/736x/a.jpg")

        // And a strictly larger later image still wins — the tie rule is not first-wins.
        let later = PageHarvest(media: [
            .init(kind: .image, src: "https://i.pinimg.com/736x/small.jpg", width: 100, height: 100),
            .init(kind: .image, src: "https://i.pinimg.com/736x/big.jpg", width: 101, height: 100),
        ])
        #expect(PageExtractor.largestMedia(later, matching: "i.pinimg.com")?.src
            == "https://i.pinimg.com/736x/big.jpg")
    }

    // MARK: - Instagram

    @Test("A post yields its handle from og:title and its largest CDN image")
    func instagramPost() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://www.instagram.com/p/ABC123/",
            metas: [
                "og:title": "Ada Lovelace (@ada.builds) on Instagram: “a stair”",
                "og:description": "a stair",
            ],
            media: [
                .init(kind: .image, src: "https://scontent.cdninstagram.com/v/small.jpg",
                      width: 320, height: 320),
                .init(kind: .image, src: "https://scontent.cdninstagram.com/v/big.jpg",
                      width: 1080, height: 1350),
            ]))

        #expect(capture.provenance.platform == "instagram")
        #expect(capture.provenance.authorHandle == "@ada.builds")
        #expect(capture.provenance.title == "a stair")
        #expect(capture.mediaURL == "https://scontent.cdninstagram.com/v/big.jpg")
        #expect(rawMetadata(capture)["shortcode"] == "ABC123")
    }

    // MARK: - The generic page

    /// The inversion worth pinning: on an ordinary article the curated share image beats
    /// the biggest thing in the DOM, which is as likely to be a banner as the subject.
    @Test("A generic page prefers og:image over the largest DOM image")
    func webPrefersOgImage() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://example.com/an-article",
            title: "Fallback title",
            metas: ["og:image": "https://example.com/share.jpg", "og:site_name": "Example"],
            media: [
                .init(kind: .image, src: "https://example.com/banner.jpg",
                      width: 3000, height: 400)
            ]))

        #expect(capture.provenance.platform == "web")
        #expect(capture.provenance.authorName == "Example")
        #expect(capture.mediaURL == "https://example.com/share.jpg")
    }

    @Test("With no og:image the largest DOM image is taken, and the host names the site")
    func webFallsBackToDOM() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://blog.example.com/post",
            title: "A post",
            media: [
                .init(kind: .image, src: "https://blog.example.com/small.jpg",
                      width: 100, height: 100),
                .init(kind: .image, src: "https://blog.example.com/hero.jpg",
                      width: 1600, height: 900),
            ]))

        #expect(capture.provenance.authorName == "blog.example.com")
        #expect(capture.provenance.title == "A post")
        #expect(capture.mediaURL == "https://blog.example.com/hero.jpg")
    }

    // MARK: - Rules that cross every platform

    /// The single most load-bearing rule the browser extension learned from real pages:
    /// an SPA's `<link canonical>` is frequently stale or points at the site root, and
    /// `location.href` is kept correct by `pushState`.
    @Test("The live URL beats a stale canonical")
    func liveURLWins() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://x.com/ada/status/42",
            canonical: "https://x.com/home"))

        #expect(capture.provenance.originalURL == "https://x.com/ada/status/42")
    }

    /// Every share from the phone says so, tier 1 and tier 2 alike — the act is a fact
    /// about the capture, and `platform` is the site.
    @Test("Every tier-2 capture carries the ios_share stamp beside its site id")
    func capturedViaIsAlwaysPresent() {
        for url in [
            "https://x.com/ada/status/1", "https://www.pinterest.com/pin/2/",
            "https://www.instagram.com/p/A/", "https://example.com/x",
        ] {
            let capture = PageExtractor.capture(from: PageHarvest(url: url))
            #expect(
                rawMetadata(capture)[ShareCapture.capturedViaKey]
                    == ShareCapture.capturedViaValue,
                "\(url) lost the capturedVia stamp")
        }
    }

    /// A tweet is 280 characters and an `og:description` can be far longer; the Mac draws
    /// this on one line under a tile.
    @Test("A paragraph-length description is truncated to a title")
    func longTitleIsTruncated() throws {
        let long = String(repeating: "a", count: 400)
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://example.com/x", metas: ["og:title": long]))

        let title = try #require(capture.provenance.title)
        #expect(title.count == PageExtractor.maximumTitleLength + 1)   // + the ellipsis
        #expect(title.hasSuffix("…"))
    }

    /// The count is in Characters, not scalars: `String.count` and `prefix` are
    /// grapheme-aware, so a flag (two scalars) is one character and the cut never lands
    /// inside one. Pinned with a grapheme-heavy title exactly at and one over the limit,
    /// because the ASCII case above cannot tell the two countings apart.
    @Test("Truncation counts graphemes: a title of flags is cut between flags")
    func truncationIsGraphemeAware() throws {
        let flag = "🇬🇧"
        let atLimit = String(repeating: flag, count: PageExtractor.maximumTitleLength)
        let over = atLimit + flag

        let kept = PageExtractor.capture(from: PageHarvest(
            url: "https://example.com/x", metas: ["og:title": atLimit]))
        #expect(kept.provenance.title == atLimit)

        let cut = PageExtractor.capture(from: PageHarvest(
            url: "https://example.com/x", metas: ["og:title": over]))
        let title = try #require(cut.provenance.title)
        #expect(title == atLimit + "…")
        #expect(title.count == PageExtractor.maximumTitleLength + 1)
        // Every scalar pair survived intact — no orphaned regional indicator.
        #expect(title.dropLast().unicodeScalars.count
            == PageExtractor.maximumTitleLength * 2)
    }

    @Test("A blank title is no title")
    func blankTitleIsDropped() {
        let capture = PageExtractor.capture(from: PageHarvest(
            url: "https://example.com/x", metas: ["og:title": "   "]))

        #expect(capture.provenance.title == nil)
    }

    // MARK: - Helpers

    private func rawMetadata(_ capture: PageCapture) -> [String: String] {
        guard case let .object(fields)? = capture.provenance.rawMetadata else { return [:] }
        return fields.compactMapValues { value in
            if case let .string(string) = value { return string }
            return nil
        }
    }
}

@Suite("PageHarvest: classifying what the script saw")
struct PageHarvestTests {

    @Test("The first meta wins; a duplicate is a template disagreeing with its content")
    func firstMetaWins() {
        let harvest = PageHarvest.build(from: RawPageSignals(
            url: "https://example.com",
            metas: [
                .init(key: "og:title", content: "The real one"),
                .init(key: "og:title", content: "The template's"),
            ]))

        #expect(harvest.metas["og:title"] == "The real one")
    }

    @Test("An empty meta, a keyless meta and a data: image are all skipped")
    func skips() {
        let harvest = PageHarvest.build(from: RawPageSignals(
            url: "https://example.com",
            metas: [
                .init(key: "og:title", content: ""),
                .init(key: nil, content: "orphan"),
                .init(key: "og:site_name", content: "Example"),
            ],
            images: [
                .init(src: "data:image/png;base64,AAAA", width: 10, height: 10),
                .init(src: "", width: 10, height: 10),
                .init(src: "https://example.com/a.jpg", width: 10, height: 10),
            ]))

        #expect(harvest.metas == ["og:site_name": "Example"])
        #expect(harvest.media.map(\.src) == ["https://example.com/a.jpg"])
    }

    @Test("A video contributes its poster and its real source, never a blob: URL")
    func videoMedia() {
        let harvest = PageHarvest.build(from: RawPageSignals(
            url: "https://example.com",
            videos: [
                .init(poster: "https://example.com/poster.jpg",
                      src: "blob:https://example.com/1", width: 1280, height: 720),
                .init(poster: nil, src: "https://example.com/clip.mp4"),
            ]))

        #expect(harvest.media.map(\.kind) == [.videoPoster, .videoSource])
        #expect(harvest.media[0].src == "https://example.com/poster.jpg")
        #expect(harvest.media[1].src == "https://example.com/clip.mp4")
    }

    /// The decode path the extension actually uses — a plist dictionary, as it arrives
    /// across the XPC boundary from Safari.
    @Test("A results dictionary decodes into a harvest")
    func decodesResults() throws {
        let results: [String: Any] = [
            "url": "https://x.com/ada/status/1",
            "title": "Ada on X",
            "metas": [["key": "og:description", "content": "hello"]],
            "images": [
                ["src": "https://pbs.twimg.com/media/A?name=small", "width": 900,
                 "height": 600, "articleIndex": 0]
            ],
        ]

        let harvest = try #require(PageHarvest.harvest(fromResults: results))

        #expect(harvest.url == "https://x.com/ada/status/1")
        #expect(harvest.metas["og:description"] == "hello")
        #expect(harvest.media.first?.articleIndex == 0)
    }

    /// `cleanURL` strips the query and the fragment — that is its job. It must not strip
    /// the ORIGIN, and a port is part of the origin. `base.js` builds the same string from
    /// `url.origin`, which includes a non-default port; rebuilding it from scheme and host
    /// alone silently rewrote `http://host:8080/p` as a different page. Caught by a tier-2
    /// capture off a loopback fixture, which is the only place in this project a
    /// non-default port occurs — and exactly why it went unnoticed.
    @Test("A non-default port survives cleaning; the query and fragment do not")
    func keepsThePortAndDropsTheQuery() {
        #expect(
            PageExtractor.cleanURL("http://127.0.0.1:53421/page.html?utm_source=x#frag")
                == "http://127.0.0.1:53421/page.html")
        #expect(
            PageExtractor.cleanURL("https://example.com/a?b=c") == "https://example.com/a")
        // The default ports are not written back out: they are already implied, and a URL
        // that gained ":443" would stop matching the one the browser extension recorded.
        #expect(PageExtractor.cleanURL("https://example.com:443/a") == "https://example.com/a")
    }

    /// The rewrite's job is the ORIGINAL, and it was quietly not getting it.
    @Test("Rewriting to name=orig also leaves webp behind, which orig cannot serve")
    func origImpliesJPEG() {
        #expect(
            PageExtractor.toOrigName(
                "https://pbs.twimg.com/media/F2K7?format=webp&name=small")
                == "https://pbs.twimg.com/media/F2K7?format=jpg&name=orig")
        // A format that already serves orig is left alone — this is one incompatibility,
        // not a policy of rewriting formats.
        #expect(
            PageExtractor.toOrigName("https://pbs.twimg.com/media/F2K7?format=png&name=900x900")
                == "https://pbs.twimg.com/media/F2K7?format=png&name=orig")
        // No `name` at all is not a sized URL, so nothing is rewritten — including format.
        #expect(
            PageExtractor.toOrigName("https://pbs.twimg.com/media/F2K7?format=webp")
                == "https://pbs.twimg.com/media/F2K7?format=webp")
    }

    @Test("Anything that is not a page snapshot is nil, not an empty harvest")
    func refusesNonSnapshots() {
        #expect(PageHarvest.harvest(fromResults: nil) == nil)
        #expect(PageHarvest.harvest(fromResults: "a string") == nil)
        // No URL: a script that failed early, and everything downstream keys off it.
        #expect(PageHarvest.harvest(fromResults: ["title": "no url here"]) == nil)
    }

    /// 098 · P5 gave `PagePreprocessor.js` four more caps — `videos`, `metas`, every
    /// string's LENGTH, and `data:` — and each of them produces the same thing on this side
    /// of the boundary: an ABSENT key. That is what the JS's "never emit null, omit the
    /// key" rule has always produced, so the decode path was already built for it; this
    /// asserts it rather than assuming it, because a cap that fired on a real page and
    /// yielded a nil harvest would be a lost capture and not a shortened one.
    @Test("A snapshot the caps stripped to almost nothing is still a page")
    func toleratesATruncatedHarvest() throws {
        // Every optional field gone: the title was too long, so was the canonical, every
        // meta's content was, and every image was a `data:` URL the script dropped.
        let bare = try #require(
            PageHarvest.harvest(fromResults: ["url": "https://example.com/post/1"]))
        #expect(bare.url == "https://example.com/post/1")
        #expect(bare.title == nil)
        #expect(bare.canonical == nil)
        #expect(bare.metas.isEmpty)
        #expect(bare.media.isEmpty)
        // And it still classifies: a page with nothing but a URL is a `.web` capture whose
        // provenance is that URL, which is the tier-1 outcome tier 2 degrades to.
        let capture = PageExtractor.capture(from: bare)
        #expect(capture.provenance.originalURL == "https://example.com/post/1")
        #expect(capture.mediaURL == nil)

        // A meta whose content was dropped, and an image whose alt was — the key is absent
        // on each, and neither takes anything else with it.
        let partial = try #require(PageHarvest.harvest(fromResults: [
            "url": "https://example.com/post/2",
            "metas": [["key": "og:description"], ["key": "og:title", "content": "kept"]],
            "images": [["src": "https://example.com/a.jpg", "width": 900, "height": 600]],
            "videos": [["poster": "https://example.com/p.jpg"]],
        ]))
        #expect(partial.metas == ["og:title": "kept"])
        #expect(partial.media.map(\.src)
            == ["https://example.com/a.jpg", "https://example.com/p.jpg"])
        #expect(partial.media[0].alt == nil)
        #expect(partial.media[0].articleIndex == nil)
        // A video that lost its dimensions with its source still reports zeroes, not nil —
        // `Media.area` is arithmetic and a missing dimension must not become a crash.
        #expect(partial.media[1].width == 0)
        #expect(partial.media[1].height == 0)
    }
}

/// The Swift half of the cross-language rewrite contract (096 review 1A).
///
/// `PageExtractor.toOrigName` / `.toOriginals` are hand-written mirrors of
/// `extension/src/extractors/base.js`, because the share extension cannot run JavaScript
/// and the phone has to reach the same URL the browser would.
///
/// **That mirror has already drifted once, in the branch this test was written in.**
/// `format=webp` and `name=orig` are incompatible — twimg 404s the pair — and the fix landed
/// HERE first, on the phone that hit it, then had to be carried back to `base.js` by hand
/// afterwards. One bug, found once, fixed twice, with nothing in either suite to say the
/// second fix was owed.
///
/// `host-table.js`'s drift check already gates the host → platform half of this mirror, on
/// the argument that a domain meaning `twitter` in one producer cannot mean `web` in the
/// other. The rewrite rules are the same kind of claim and had no such gate; the fixture is
/// the gate, read by both suites, and it is the same device `capture-contract.json` uses for
/// the request shape.
///
/// Change a rule in one language and this fails until the other agrees. That is the whole
/// point — the file it reads is under `extension/`, so neither side owns it.
@Suite("The media-URL rewrite contract, shared with the browser extension")
struct MediaRewriteContractTests {

    struct Contract: Decodable {
        struct Entry: Decodable {
            let `case`: String
            let input: String
            let expected: String
        }
        let toOrigName: [Entry]
        let toOriginals: [Entry]
    }

    /// Four levels up from this file is the repo root — the same `#filePath` walk
    /// `CaptureDecoderTests.loadContract()` uses, and it stays correct only as long as both
    /// suites sit at the same depth. They do.
    static func loadContract() throws -> Contract {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent(
            "extension/test/fixtures/media-rewrite-contract.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    @Test("toOrigName agrees with base.js on every case in the shared fixture")
    func origNameMatchesContract() throws {
        let contract = try Self.loadContract()
        #expect(!contract.toOrigName.isEmpty, "the contract has toOrigName cases")
        for entry in contract.toOrigName {
            #expect(
                PageExtractor.toOrigName(entry.input) == entry.expected,
                "\(entry.case) — input \(entry.input)")
        }
    }

    @Test("toOriginals agrees with base.js on every case in the shared fixture")
    func originalsMatchesContract() throws {
        let contract = try Self.loadContract()
        #expect(!contract.toOriginals.isEmpty, "the contract has toOriginals cases")
        for entry in contract.toOriginals {
            #expect(
                PageExtractor.toOriginals(entry.input) == entry.expected,
                "\(entry.case) — input \(entry.input)")
        }
    }
}

// MARK: - The live page replay (096 review 12B)

/// The other half of `extension/test/page-signals.test.js`, over the same file.
///
/// **Why a live page at all, when the suite above is deliberately hand-composed.** The
/// fixtures in `PageExtractorTests` are trimmed to exercise one rule each, and that is
/// what makes a failure say WHICH rule broke. What they cannot say is whether the rule
/// still fires on a page X served today: a live feed is 100+ images — avatars, card art,
/// tracking pixels — in an order nobody composing a fixture would write down, and
/// `largestMedia`, the article-index scoping and the `name=orig` rewrite are all decisions
/// taken against exactly that. `extension/test/fixtures/README.md` states the defect
/// plainly about Instagram, whose composed fixture carries 11–13 keys per media where the
/// live API sends 108–128: *"Running the canary over it proved only that our own reduction
/// still parsed."*
///
/// **Why only the post pages.** `PageExtractor.capture(from:)` takes no context and
/// dispatches on the page's own URL, because tier 2 is a share sheet and a share sheet has
/// no right-clicked link to pass. Tier 3's JS extractors DO take a `linkUrl` — on a feed
/// they are told which of forty posts was centred. So on a feed dump the two languages are
/// answering different questions and must disagree: Swift would report `x.com/home`, which
/// is not a post at all. Asserting agreement there would report drift where none exists,
/// which is the fastest way to teach someone to ignore this file. Post pages are where the
/// two converge, and `pageKind` in the fixture is what says which is which.
///
/// This is `drift-check.js`'s mirror guard (404) applied to page SHAPE rather than to host
/// tables.
@Suite("Live page signals: the Swift reader sees what the JS reader saw (096 12B)")
struct LivePageSignalsTests {

    struct Entry: Decodable {
        struct Expected: Decodable {
            let platform: String?
            let originalURL: String?
            let authorHandle: String?
            let authorName: String?
            let title: String?
            let mediaUrl: String?
            let mediaUrlFallback: String?
        }
        let host: String
        let pageUrl: String
        let pageKind: String
        let linkUrl: String?
        let expected: Expected
        let raw: RawPageSignals
    }

    /// Same `#filePath` walk as `MediaRewriteContractTests.loadContract()` — four levels
    /// up is the repo root, and it stays correct only as long as both suites sit at the
    /// same depth. They do.
    static var fixtureURL: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("extension/test/fixtures/page-signals-live.json")
    }

    static var fixtureExists: Bool {
        FileManager.default.fileExists(atPath: fixtureURL.path)
    }

    static func load() throws -> [String: Entry] {
        try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fixtureURL))
    }

    /// Disabled rather than passing vacuously: a skipped test names itself and its reason
    /// in the run output, where a test that quietly returns on a missing file reads as
    /// green forever. `focal-post.test.js` skips with a sentence for the same reason.
    @Test(
        "a real post page yields the provenance the JS reader produced",
        .enabled(
            if: LivePageSignalsTests.fixtureExists,
            "no live page-signal fixture yet — capture it during 096 § T0 with the probe's \"Dump signals\" button"))
    func livePostPagesAgree() throws {
        let entries = try Self.load().values.filter { $0.pageKind == "post" }
        try #require(!entries.isEmpty, """
            the fixture has no post-page entries — only a post page can be compared \
            across the two languages (see this suite's header)
            """)

        for entry in entries {
            let capture = PageExtractor.capture(from: PageHarvest.build(from: entry.raw))
            let where_ = "\(entry.host) — \(entry.pageUrl)"

            #expect(capture.provenance.platform == entry.expected.platform, "\(where_): platform")
            #expect(capture.provenance.originalURL == entry.expected.originalURL, "\(where_): originalURL")
            #expect(capture.provenance.authorHandle == entry.expected.authorHandle, "\(where_): authorHandle")
            #expect(capture.provenance.authorName == entry.expected.authorName, "\(where_): authorName")
            #expect(capture.provenance.title == entry.expected.title, "\(where_): title")
            #expect(capture.mediaURL == entry.expected.mediaUrl, "\(where_): mediaUrl")
            #expect(capture.mediaURLFallback == entry.expected.mediaUrlFallback, "\(where_): mediaUrlFallback")
        }
    }

    /// The feed pages are not compared, but they are not ignored either: a feed dump the
    /// Swift decoder cannot even READ is a fixture that will surprise someone later, and
    /// `RawPageSignals` decoding is the half of the contract that holds for both kinds.
    @Test(
        "every captured page decodes as RawPageSignals, feed or post",
        .enabled(
            if: LivePageSignalsTests.fixtureExists,
            "no live page-signal fixture yet — capture it during 096 § T0"))
    func everyPageDecodes() throws {
        let bag = try Self.load()
        #expect(!bag.isEmpty)
        for (key, entry) in bag {
            #expect(entry.raw.url != nil, "\(key): the snapshot names the page it came from")
            #expect(entry.pageKind == "post" || entry.pageKind == "feed", "\(key): pageKind")
            // A page with no images at all is a dump taken before the feed loaded — real
            // enough to store, useless as a fixture, and silent unless said out loud.
            #expect((entry.raw.images?.count ?? 0) > 0, "\(key): the page had images when dumped")
        }
    }
}
