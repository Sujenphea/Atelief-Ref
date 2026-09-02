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
}
