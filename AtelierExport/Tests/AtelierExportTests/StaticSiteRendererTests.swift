// AtelierExport — static-site template tests (014 · S3)
//
// The template is pinned by GOLDEN FILES (`Fixtures/*.html`): the rendered page
// for a fixed gallery must match byte for byte, so any template edit fails
// loudly and shows up as a readable HTML diff. Regenerate deliberately, never
// by copying whatever the code now emits — see `regenerateGoldens` below.
//
// The self-containment invariants (no <script>, no absolute URLs) are asserted
// separately from the goldens, because those are the properties that make the
// folder work on a plane with the Wi-Fi off; a golden file would let them rot
// silently as long as both sides changed together.

import Foundation
import Testing
@testable import AtelierExport

@Suite("Static site: index.html")
struct StaticSiteRendererTests {

    // MARK: - Fixture

    /// One gallery exercising every media case, both caption fields, an item
    /// with no dimensions, and a filename/caption full of characters that must
    /// survive two different escaping grammars.
    static func fixture(captions: Bool, sources: Bool) -> SiteGallery {
        SiteGallery(
            title: "Kitchen & \"Bath\" <2026>",
            items: [
                SiteItem(
                    media: .image(file: "Sunset study-ab12cd34.jpg",
                                  pixelWidth: 1600, pixelHeight: 1067),
                    caption: "Sunset study",
                    sourceURL: "https://www.example.com/photos/1"),
                SiteItem(
                    media: .video(posterFile: "Rooftop clip-99887766.jpg",
                                  pixelWidth: 1920, pixelHeight: 1080),
                    caption: "Rooftop clip",
                    sourceURL: "https://vimeo.com/12345"),
                SiteItem(
                    media: .color(hex: "#C8402F"),
                    caption: "Signal red"),
                SiteItem(
                    media: .image(file: "a&b #2 100% naïve-deadbeef.png",
                                  pixelWidth: 800, pixelHeight: 800),
                    caption: "Tricky <name> & \"quotes\"",
                    sourceURL: "https://x.com/dieter/status/1?s=20"),
                SiteItem(
                    media: .image(file: "no-dims-00112233.webp",
                                  pixelWidth: nil, pixelHeight: nil)),
            ],
            columns: 3,
            includeCaptions: captions,
            includeSources: sources)
    }

    /// Set to `true`, run the suite once, set back to `false`. Deliberate, and
    /// visible in a diff — the point of a golden is that updating it is a choice.
    static let regenerateGoldens = false

    static func goldenURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(
            forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    }

    static func check(_ html: String, against name: String) throws {
        if regenerateGoldens {
            // Only reachable when a developer flips the flag above; writes into
            // the SOURCE tree, not the build bundle.
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).html")
            try html.write(to: source, atomically: true, encoding: .utf8)
            Issue.record("Golden '\(name)' regenerated — flip regenerateGoldens back to false.")
            return
        }
        let expected = try String(contentsOf: try goldenURL(name), encoding: .utf8)
        #expect(html == expected, "index.html drifted from Fixtures/\(name).html")
    }

    // MARK: - Golden files

    @Test("Captions and source links on match the golden page")
    func goldenWithProvenance() throws {
        try Self.check(
            StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true)),
            against: "gallery-captions-sources")
    }

    @Test("Captions and source links off match the golden page")
    func goldenBare() throws {
        try Self.check(
            StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: false)),
            against: "gallery-bare")
    }

    // MARK: - Self-containment

    @Test("The page carries no script of any kind")
    func noScripts() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true))
        #expect(!html.lowercased().contains("<script"))
        #expect(!html.lowercased().contains("javascript:"))
        #expect(!html.lowercased().contains(" onload="))
        #expect(!html.lowercased().contains(" onclick="))
    }

    @Test("Every asset reference is a relative path into assets/")
    func onlyRelativeAssetURLs() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true))
        // No stylesheet, font or image is fetched from anywhere.
        #expect(!html.contains("<link "))
        #expect(!html.contains("@import"))
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("url(http"))
        #expect(html.contains("src=\"assets/"))
    }

    @Test("A source link is the ONLY absolute URL, and only when provenance is on")
    func provenanceIsTheOnlyOutboundLink() {
        let withSources = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true))
        #expect(withSources.contains("href=\"https://vimeo.com/12345\""))

        let without = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: false))
        #expect(!without.contains("href=\"http"))
        #expect(!without.contains("vimeo.com"))
        #expect(!without.contains("example.com"))
    }

    // MARK: - Captions / provenance switches

    @Test("Captions off removes the words, including from alt text")
    func captionsOff() {
        let on = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: false))
        #expect(on.contains("<span class=\"title\">Sunset study</span>"))
        #expect(on.contains("alt=\"Sunset study\""))

        let off = StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: false))
        #expect(!off.contains("Sunset study"))
        #expect(!off.contains("<figcaption>"))
        #expect(off.contains("alt=\"Reference\""))
    }

    @Test("Sources on with captions off still renders the link alone")
    func sourcesWithoutCaptions() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: true))
        #expect(html.contains("<figcaption>"))
        #expect(!html.contains("<span class=\"title\">"))
        #expect(html.contains(">example.com<"))
    }

    @Test("A source link shows its host, www dropped, not the whole URL")
    func hostLabels() {
        #expect(StaticSiteRenderer.sourceLabel("https://www.example.com/a/b") == "example.com")
        #expect(StaticSiteRenderer.sourceLabel("https://x.com/p?q=1") == "x.com")
        // Something that isn't a URL is shown verbatim rather than dropped.
        #expect(StaticSiteRenderer.sourceLabel("scanned from a book") == "scanned from a book")
    }

    // MARK: - Video honesty

    @Test("A video renders as a poster image plus a play glyph, and says so")
    func videoPoster() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true))
        #expect(html.contains("src=\"assets/Rooftop%20clip-99887766.jpg\""))
        #expect(html.contains("<svg class=\"play\""))
        #expect(html.contains("Video refs are shown as poster frames"))
        // No <video>, no video file reference.
        #expect(!html.contains("<video"))
        #expect(!html.contains(".mp4"))
    }

    @Test("With no video, the poster note is absent")
    func noVideoNote() {
        let gallery = SiteGallery(
            title: "Stills",
            items: [SiteItem(media: .image(file: "a-1.jpg", pixelWidth: 2, pixelHeight: 1))])
        let html = StaticSiteRenderer.indexHTML(gallery)
        #expect(!html.contains("poster frames"))
        #expect(!html.contains("<svg class=\"play\""))
    }

    // MARK: - Escaping

    @Test("Text is HTML-escaped in content and in attributes")
    func escaping() {
        #expect(StaticSiteRenderer.escape("a & b < c > \"d\" 'e'")
            == "a &amp; b &lt; c &gt; &quot;d&quot; &#39;e&#39;")
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: true, sources: true))
        #expect(html.contains("<title>Kitchen &amp; &quot;Bath&quot; &lt;2026&gt;</title>"))
        #expect(html.contains("Tricky &lt;name&gt; &amp; &quot;quotes&quot;"))
        // The raw angle bracket from the caption must not survive anywhere.
        #expect(!html.contains("<name>"))
    }

    @Test("A filename is percent-encoded THEN HTML-escaped")
    func assetHrefEncoding() {
        // Space → %20, # → %23, % → %25; & is legal in a path so it survives
        // percent-encoding and is then escaped for the attribute.
        #expect(StaticSiteRenderer.assetHref("a&b #2 100%.png")
            == "assets/a&amp;b%20%232%20100%25.png")
        #expect(StaticSiteRenderer.assetHref("naïve café 🎨-ab12cd34.png")
            == "assets/na%C3%AFve%20caf%C3%A9%20%F0%9F%8E%A8-ab12cd34.png")
    }

    // MARK: - Structure

    @Test("Cells are grouped into columns round-robin")
    func columns() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: false))
        #expect(html.components(separatedBy: "<div class=\"col\">").count - 1 == 3)
        #expect(html.components(separatedBy: "<figure>").count - 1 == 5)
    }

    @Test("Intrinsic dimensions ride along when known, and are omitted when not")
    func dimensions() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: false))
        #expect(html.contains("width=\"1600\" height=\"1067\""))
        #expect(html.contains("src=\"assets/no-dims-00112233.webp\" alt=\"Reference\" loading="))
    }

    @Test("A colour ref is painted by CSS and costs no file")
    func colorSwatch() {
        let html = StaticSiteRenderer.indexHTML(Self.fixture(captions: false, sources: false))
        #expect(html.contains("<div class=\"swatch\" style=\"background:#C8402F\"></div>"))
        #expect(html.components(separatedBy: "<img ").count - 1 == 4)  // 5 items, 1 colour
    }

    @Test("An empty gallery still renders a valid page rather than a broken shell")
    func emptyGallery() {
        // The action is disabled with nothing to export, so this is the
        // belt-and-braces path (and what a fully-skipped export produces).
        let html = StaticSiteRenderer.indexHTML(SiteGallery(title: "Nothing", items: []))
        #expect(html.contains("<p>No refs.</p>"))
        #expect(html.contains("0 refs"))
        #expect(html.hasSuffix("</html>\n"))
    }

    @Test("The ref count is singular for one")
    func singularCount() {
        let html = StaticSiteRenderer.indexHTML(SiteGallery(
            title: "One", items: [SiteItem(media: .color(hex: "#000000"))]))
        #expect(html.contains(">1 ref<"))
    }

    @Test("Rendering is a pure function — the same input twice is byte-identical")
    func deterministic() {
        let gallery = Self.fixture(captions: true, sources: true)
        #expect(StaticSiteRenderer.indexHTML(gallery) == StaticSiteRenderer.indexHTML(gallery))
    }
}
