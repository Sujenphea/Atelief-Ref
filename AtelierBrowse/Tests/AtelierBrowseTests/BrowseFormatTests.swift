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

    @Test("the item's own name wins over the source's title")
    func title() {
        #expect(BrowseFormat.title(name: "Mine", sourceTitle: "Theirs") == "Mine")
        #expect(BrowseFormat.title(name: nil, sourceTitle: "Theirs") == "Theirs")
        #expect(BrowseFormat.title(name: " ", sourceTitle: "Theirs") == "Theirs")
        #expect(BrowseFormat.title(name: nil, sourceTitle: nil) == nil)
    }
}
