// AtelierBrowse tests — the detail screen's wording.
//
// The two that earn a test rather than a glance: the saved date must NOT follow the
// device locale (041 fixes the format, and a phone is far likelier than a Mac to be
// set to one this code has never seen), and every `Platform` case must have a label,
// since five of the nine differ from their raw value.

import Foundation
import Testing

import AtelierCore
@testable import AtelierBrowse

@Suite("BrowseFormat")
struct BrowseFormatTests {

    @Test("the saved date is dd/MM/yyyy, zero-padded")
    func savedDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        #expect(BrowseFormat.savedDate(date, calendar: calendar) == "07/03/2026")
    }

    @Test("the saved date ignores the device locale")
    func savedDateIsLocaleIndependent() {
        // A US phone must not render 03/07/2026 for the same instant a UK one renders
        // 07/03/2026 — the format is the Figma's, not the region's.
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7
        var us = Calendar(identifier: .gregorian)
        us.locale = Locale(identifier: "en_US")
        var jp = Calendar(identifier: .gregorian)
        jp.locale = Locale(identifier: "ja_JP")
        let date = us.date(from: components)!
        #expect(BrowseFormat.savedDate(date, calendar: us)
            == BrowseFormat.savedDate(date, calendar: jp))
    }

    @Test("every platform has the app's own label, not its raw value")
    func platformLabels() {
        #expect(BrowseFormat.platform(.twitter) == "Twitter / X")
        #expect(BrowseFormat.platform(.rednote) == "rednote")
        #expect(BrowseFormat.platform(.localPaste) == "Pasted")
        #expect(BrowseFormat.platform(.localDrag) == "Dragged in")
        #expect(BrowseFormat.platform(.clipboard) == "Clipboard")
        // Exhaustive, so a tenth platform cannot ship with an empty row.
        for platform in Platform.allCases {
            #expect(!BrowseFormat.platform(platform).isEmpty)
        }
    }

    @Test("dimensions are omitted entirely for a media-less kind")
    func dimensions() {
        #expect(BrowseFormat.dimensions(width: 1668, height: 2500) == "1668px x 2500px")
        #expect(BrowseFormat.dimensions(width: nil, height: 2500) == nil)
        #expect(BrowseFormat.dimensions(width: 1668, height: nil) == nil)
    }

    @Test("author combines what is there and disappears when nothing is")
    func author() {
        #expect(BrowseFormat.author(name: "Ada", handle: "@ada") == "Ada (@ada)")
        #expect(BrowseFormat.author(name: "Ada", handle: nil) == "Ada")
        #expect(BrowseFormat.author(name: nil, handle: "@ada") == "@ada")
        #expect(BrowseFormat.author(name: nil, handle: nil) == nil)
        // A blank string is absence, not a value — otherwise the row renders empty.
        #expect(BrowseFormat.author(name: "   ", handle: "@ada") == "@ada")
        #expect(BrowseFormat.author(name: "  ", handle: "") == nil)
    }

    @Test("a newline is trimmed like any other whitespace — the drift 098 · finding 6 found")
    func authorTrimsNewlines() {
        // This function and the Mac's `SourceSection.author` (`ItemDetailView.swift:1762`)
        // were the same rule spelled twice, and had already drifted: this one trims
        // `.whitespacesAndNewlines` through `TextRules.nonBlank`, the Mac's trimmed
        // `.whitespaces`. So `"Ada\n"` was `"Ada"` on the phone and `"Ada\n"` — a name
        // followed by a blank line inside a `Text` — on the Mac, from one database row.
        // A page extractor producing a wrapped byline is all it takes.
        //
        // P4 deleted the Mac's copy and pointed it here, so the stricter rule is now the
        // only rule. These cases are what "stricter" means.
        #expect(BrowseFormat.author(name: "Ada\n", handle: nil) == "Ada")
        #expect(BrowseFormat.author(name: "\nAda", handle: "@ada\n") == "Ada (@ada)")
        #expect(BrowseFormat.author(name: "\n", handle: "@ada") == "@ada")
        #expect(BrowseFormat.author(name: "\n", handle: "\r\n") == nil)
        // A newline INSIDE a value is not whitespace at an edge and is left alone: it is
        // data, and silently rewriting it would be a different function.
        #expect(BrowseFormat.author(name: "Ada\nLovelace", handle: nil) == "Ada\nLovelace")
    }

    // MARK: - A bare link (098 · "also found")

    @Test("a link with a title keeps it, host or no host")
    func linkTitleWins() {
        // The unchanged case, and the one that must not regress: a link the Mac enriched
        // before it synced back has a real title and the host is irrelevant.
        #expect(BrowseFormat.linkTitle("A Field Guide", url: "https://www.example.com/x")
            == "A Field Guide")
        #expect(BrowseFormat.linkTitle("A Field Guide", url: "not a url") == "A Field Guide")
        // A blank title is absence, not a value — otherwise the tile draws an empty label.
        #expect(BrowseFormat.linkTitle("   ", url: "https://example.com/x") == "example.com")
    }

    @Test("a bare link shows the site, not the URL")
    func bareLinkShowsItsHost() {
        // Every tier-1 link share on the phone is this case: nothing enriches one, so the
        // tile used to draw the whole URL — query string and all — at column width.
        #expect(BrowseFormat.linkTitle(nil, url: "https://example.com/a/b") == "example.com")
        #expect(BrowseFormat.linkTitle(nil, url: "https://www.example.com/a/b")
            == "example.com")
        #expect(BrowseFormat.linkTitle(
            nil, url: "http://sub.example.co.uk/x?utm_source=y&utm_campaign=z")
            == "sub.example.co.uk")
    }

    @Test("www. is dropped and only as a leading label")
    func wwwIsDroppedOnlyAtTheFront() {
        #expect(BrowseFormat.hostName(of: "https://www.example.com") == "example.com")
        // Not a substring match: a host that merely CONTAINS the letters keeps them.
        #expect(BrowseFormat.hostName(of: "https://wwwexample.com") == "wwwexample.com")
        #expect(BrowseFormat.hostName(of: "https://a.www.example.com") == "a.www.example.com")
    }

    @Test("the host is lower-cased, so one site is one label")
    func hostIsLowerCased() {
        #expect(BrowseFormat.hostName(of: "https://WWW.Example.COM/") == "example.com")
    }

    @Test("userinfo never reaches the label")
    func userinfoIsStripped() {
        // `https://example.com@evil.test/` is the classic: the part before the `@` is
        // userinfo and the host is `evil.test`. A label that showed the whole authority
        // would name the wrong site.
        #expect(BrowseFormat.hostName(of: "https://user:pw@example.com/p") == "example.com")
        #expect(BrowseFormat.hostName(of: "https://example.com@evil.test/") == "evil.test")
    }

    @Test("an internationalised host renders as punycode, not as its lookalike")
    func idnRendersAsASCII() {
        // The Unicode spelling is prettier and it is a homograph surface — a tile is
        // exactly where a lookalike domain would want to be drawn as the site it imitates.
        // Both spellings of one host therefore answer the same ASCII string.
        #expect(BrowseFormat.hostName(of: "https://例え.jp/x") == "xn--r8jz45g.jp")
        #expect(BrowseFormat.hostName(of: "https://xn--r8jz45g.jp/x") == "xn--r8jz45g.jp")
        #expect(BrowseFormat.hostName(of: "https://user@例え.jp/x") == "xn--r8jz45g.jp")
    }

    @Test("a string with no host falls back to itself, unchanged")
    func nonURLsFallBack() {
        // Better a raw string than an empty tile: whatever is stored is at least what the
        // user shared.
        #expect(BrowseFormat.linkTitle(nil, url: "not a url") == "not a url")
        #expect(BrowseFormat.linkTitle(nil, url: "example.com/x") == "example.com/x")
        #expect(BrowseFormat.linkTitle(nil, url: "mailto:someone@example.com")
            == "mailto:someone@example.com")
        #expect(BrowseFormat.linkTitle(nil, url: "https://") == "https://")
        #expect(BrowseFormat.linkTitle(nil, url: "") == "")
    }

    @Test("hostName answers nil rather than an empty label")
    func hostNameEdges() {
        #expect(BrowseFormat.hostName(of: nil) == nil)
        #expect(BrowseFormat.hostName(of: "   ") == nil)
        #expect(BrowseFormat.hostName(of: "not a url") == nil)
        #expect(BrowseFormat.hostName(of: "mailto:a@b.com") == nil)
        // A host that is only the label being dropped leaves nothing to show.
        #expect(BrowseFormat.hostName(of: "https://www./x") == nil)
    }

    @Test("a non-web scheme with a host still names its host")
    func otherSchemesKeepTheirHost() {
        // Nothing on this phone stores one — a link asset's URL is a web URL by
        // construction — but the rule is "whatever has a host names it", not a scheme
        // allow-list, and it is worth saying which of the two this is.
        #expect(BrowseFormat.hostName(of: "ftp://files.example.com/x") == "files.example.com")
    }

    @Test("the item's own name wins over the source's title")
    func title() {
        #expect(BrowseFormat.title(name: "Mine", sourceTitle: "Theirs") == "Mine")
        #expect(BrowseFormat.title(name: nil, sourceTitle: "Theirs") == "Theirs")
        #expect(BrowseFormat.title(name: " ", sourceTitle: "Theirs") == "Theirs")
        #expect(BrowseFormat.title(name: nil, sourceTitle: nil) == nil)
    }

    // MARK: - What a screen calls an item (098 · P6)

    @Test("the display title takes the name, then the source title")
    func displayTitleTakesTheNames() {
        #expect(
            BrowseFormat.displayTitle(
                for: Self.image(name: "Mine"), source: Self.source(title: "Theirs")) == "Mine")
        #expect(
            BrowseFormat.displayTitle(
                for: Self.image(), source: Self.source(title: "Theirs")) == "Theirs")
    }

    @Test("a nameless picture falls back to its platform, never to nothing")
    func displayTitleFallsBackToPlatform() {
        // The old rule ended here and the item detail spelled it as `title ?? ""`, so an
        // unnamed capture pushed a screen with a BLANK navigation bar.
        #expect(
            BrowseFormat.displayTitle(for: Self.image(), source: Self.source(platform: .pinterest))
                == "Pinterest")
        #expect(
            BrowseFormat.displayTitle(for: Self.image(), source: Self.source(platform: .localDrag))
                == "Dragged in")
    }

    @Test("a bare link names its site, which is what its own tile already drew")
    func displayTitleOfABareLink() {
        // Every tier-1 link share on this phone is nameless and titleless — nothing
        // enriches one (098 · "also found") — so this is the ordinary case, not an edge.
        // The tile drew the host and announced "Web"; now both say the same thing.
        #expect(
            BrowseFormat.displayTitle(
                for: Self.link(url: "https://www.example.com/a/b?utm=1"),
                source: Self.source(platform: .web)) == "example.com")
    }

    @Test("a link whose payload carries a title uses it, not the host")
    func displayTitleOfATitledLink() {
        #expect(
            BrowseFormat.displayTitle(
                for: Self.link(url: "https://example.com/x", title: "A concrete stair"),
                source: Self.source(platform: .web)) == "A concrete stair")
    }

    @Test("a text post names its author, then falls back to the platform")
    func displayTitleOfAPost() {
        #expect(
            BrowseFormat.displayTitle(
                for: Self.tweet(authorName: "Ada", authorHandle: "@ada"),
                source: Self.source(platform: .twitter)) == "Ada (@ada)")
        #expect(
            BrowseFormat.displayTitle(
                for: Self.tweet(), source: Self.source(platform: .twitter)) == "Twitter / X")
    }

    @Test("the display title is never empty, for any content and any platform")
    func displayTitleIsNeverEmpty() {
        // The property the two call sites actually depend on: a navigation bar and a
        // VoiceOver label both need a string, and neither has anywhere to put a `nil`.
        let assets = [
            Self.image(), Self.link(url: ""), Self.link(url: "not a url"), Self.tweet(),
            Self.color(),
        ]
        for asset in assets {
            for platform in Platform.allCases {
                let title = BrowseFormat.displayTitle(
                    for: asset, source: Self.source(platform: platform))
                #expect(!title.isEmpty, "\(platform) / \(asset.kind) has no title")
            }
        }
    }

    // MARK: - Which collections an item is in (098 · P6)

    @Test("collections are joined in the read's order, not re-sorted")
    func collectionNamesKeepTheirOrder() {
        let names = ["Unsorted", "Textures", "Concrete"]
        #expect(
            BrowseFormat.collectionNames(names.map(Self.collection))
                == "Unsorted, Textures, Concrete")
    }

    @Test("one collection is one name with no separator")
    func oneCollection() {
        #expect(BrowseFormat.collectionNames([Self.collection("Posters")]) == "Posters")
    }

    @Test("no collections is nil, so the row is omitted rather than drawn empty")
    func noCollections() {
        #expect(BrowseFormat.collectionNames([]) == nil)
        // A collection whose name is blank contributes nothing, and a list of only those
        // is the same as no list — the same `nonBlank` rule every other field here uses.
        #expect(BrowseFormat.collectionNames([Self.collection("  ")]) == nil)
        #expect(
            BrowseFormat.collectionNames([Self.collection(" "), Self.collection("Type")])
                == "Type")
    }

    // MARK: - Fixtures

    private static func source(
        platform: Platform = .web, title: String? = nil
    ) -> Source {
        Source(id: UUID(), platform: platform, title: title, capturedAt: Date())
    }

    /// Built through `AssetPayload.jsonString()` rather than from hand-written JSON, so
    /// these fixtures cannot encode a shape the app never stores.
    private static func asset(
        kind: AssetKind, name: String? = nil, payload: AssetPayload? = nil,
        blobHash: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash, mimeType: nil, width: nil,
            height: nil, fileSize: nil, downloadState: .downloaded, createdAt: Date(),
            name: name, sourceId: UUID(), payload: payload?.jsonString())
    }

    private static func image(name: String? = nil) -> Asset {
        asset(kind: .image, name: name, blobHash: String(repeating: "a", count: 64))
    }

    private static func color() -> Asset {
        asset(kind: .color, payload: AssetPayload(color: ColorPayload(hex: "#B4472A")))
    }

    private static func link(url: String, title: String? = nil) -> Asset {
        asset(kind: .link, payload: AssetPayload(link: LinkPayload(url: url, title: title)))
    }

    private static func tweet(authorName: String? = nil, authorHandle: String? = nil) -> Asset {
        asset(
            kind: .tweet,
            payload: AssetPayload(
                tweet: TweetPayload(
                    tweetID: "1", authorHandle: authorHandle, authorName: authorName)))
    }

    private static func collection(_ name: String) -> Collection {
        Collection(id: UUID(), name: name, createdAt: Date(), updatedAt: Date())
    }
}
