// AtelierRefsMobileUITests — the taps nothing else can make.
//
// **What this target is for.** Everything about the companion that can be decided from
// values is already tested under `swift test` in `AtelierBrowse` and `AtelierCore` — the
// ordering, the tree, the masonry decomposition, the cover fallback. What was left over
// after 409/411 was a short list of claims that need a finger: that the navigation TITLE
// is a control, that a parent row expands to its children, that choosing a collection
// retitles the grid, and that a tile pushes its detail. Those were verified by argument
// and by two screenshots taken with the sheet forced open. This is the target that makes
// them assertions instead.
//
// It is deliberately NOT a second home for logic tests. A UI test is the slowest and
// flakiest kind there is, and the reason to accept that cost is that a tap cannot be
// simulated any other way; anything that CAN be a `swift test` belongs there.
//
// The library under test is written by the app itself at launch — see `FixtureLibrary` —
// because this process cannot write into the app's container and browse has no verb that
// would let the UI make content.

import XCTest

final class SwitcherUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - The title is the switcher (093 § 2)

    func testTitleTapPresentsTheCollectionTree() {
        let app = launch()
        XCTAssertTrue(
            app.buttons["U1"].waitForExistence(timeout: 20), "the seeded grid never appeared")

        switcherButton(app).tap()

        XCTAssertTrue(
            app.navigationBars["Collections"].waitForExistence(timeout: 5),
            "tapping the title did not present the tree")
        for name in ["Unsorted", "Textures", "Posters", "Type", "Swatches"] {
            XCTAssertTrue(app.buttons[name].exists, "the tree is missing \(name)")
        }
        // The pictures themselves are not assertable — a thumbnail has no accessibility
        // identity, and giving one to a decorative image would put a VoiceOver stop on
        // something that says nothing the row's name does not. So the cover-vs-folder
        // distinction is carried by this attachment, for a human, on purpose.
        attach(app, named: "switcher-rows")
    }

    // MARK: - Nesting

    func testParentRowExpandsToItsChildren() {
        let app = launch()
        switcherButton(app).tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.buttons["Concrete"].exists, "the tree starts collapsed")

        // The disclosure control is the outline's, not ours: it sits OUTSIDE the row
        // button's frame, at the trailing edge, and has no identity of its own to query.
        // A normalized coordinate is the honest way to hit it — and it is what a finger
        // does — so this taps the trailing 7% of the row rather than pretending to find
        // a named element.
        let row = app.cells.containing(.button, identifier: "Textures").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["Concrete"].waitForExistence(timeout: 5),
            "Textures did not expand to its children")
        XCTAssertTrue(app.buttons["Fabric"].exists, "the empty child is missing")
        // The one image nobody had yet: a nested row WITH a picture beside one without,
        // which is where an indentation that a 36pt square has eaten would show.
        attach(app, named: "switcher-nested-rows")
    }

    // MARK: - Choosing a collection

    func testChoosingACollectionRetitlesTheGrid() {
        let app = launch()
        switcherButton(app).tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5))

        // `.firstMatch`: an outline row publishes the cell AND the button inside it under
        // the same label, so the bare query is ambiguous and tapping it throws. The first
        // match is the row, and its centre is the row's own control rather than the
        // disclosure chevron at the trailing edge.
        app.buttons["Textures"].firstMatch.tap()

        // The navigation bar's IDENTIFIER is the collection name, which is the one place
        // the title is unambiguous — a static text "Textures" also exists inside the
        // sheet's row, so asserting on that would pass while the sheet was still up.
        XCTAssertTrue(
            app.navigationBars["Textures"].waitForExistence(timeout: 5),
            "the grid kept the old collection's title")
        XCTAssertTrue(
            app.buttons["T1"].waitForExistence(timeout: 5),
            "the grid did not reload onto the chosen collection's items")
        XCTAssertFalse(
            app.buttons["U1"].exists, "the previous collection's items are still on screen")
    }

    // MARK: - Item detail

    func testTileOpensTheItemDetail() {
        let app = launch()
        // A tile is a Button labelled by its provenance title (`GridTile.swift:88`), so
        // this taps a KNOWN picture rather than whichever one happens to be first.
        let tile = app.buttons["U1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no seeded tile to tap")
        tile.tap()

        // The three 041 sections, below the media and in the Mac's order (093 § 2).
        // "Details" is conditional by design — it holds the Mac's editable surface and is
        // omitted when there is nothing in it (`ItemDetailScreen.swift:109`) — so the
        // fixture gives this one item a note, which is what makes asking for all three
        // sections a fair question.
        for section in ["Data", "Source", "Details"] {
            XCTAssertTrue(
                app.staticTexts[section].waitForExistence(timeout: 5),
                "the detail screen is missing its \(section) section")
        }

        // The nine facts 098 · P6 completes the screen with. The two that were missing are
        // asserted by name; the rest are the labels 041 fixes.
        for label in ["Saved", "Dimensions", "Platform", "Author", "Collection", "Note"] {
            XCTAssertTrue(
                app.staticTexts[label].exists, "the detail screen has no \(label) row")
        }
        XCTAssertTrue(
            app.staticTexts["Unsorted"].exists,
            "the Collection row does not name the collection the item is in")

        // **The navigation bar has a title.** It was `title ?? ""`, so an item with neither
        // a name nor a source title pushed a screen with a bare bar; the fixture's captures
        // all carry a provenance title, so this asserts the ordinary case rather than the
        // fallback — which `BrowseFormatTests` covers over every kind and platform.
        XCTAssertTrue(
            app.navigationBars["U1"].waitForExistence(timeout: 5),
            "the detail screen has no title")

        attach(app, named: "item-detail")
    }

    // MARK: - The screens with nothing on them (093 § 7, 098 · P6)

    func testAnEmptyCollectionSaysWhichNothingItIs() {
        let app = launch()
        switcherButton(app).tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5))

        // "Type" is seeded with no items and no children (`FixtureLibrary.Names.type`).
        app.buttons["Type"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Type"].waitForExistence(timeout: 5))

        let notice = app.staticTexts["notice.empty"]
        XCTAssertTrue(
            notice.waitForExistence(timeout: 5), "an empty collection drew no sentence")
        // The sentence is the COLLECTION's, not Unsorted's. Before 098 · P6 every empty grid
        // said "Anything you share arrives in Unsorted", which in a collection reached off
        // the switcher answers a question about somewhere else.
        XCTAssertTrue(
            app.staticTexts["This collection is empty"].exists,
            "the empty collection is wearing another collection's sentence")
        XCTAssertFalse(
            app.staticTexts["Nothing here yet"].exists, "the old one-size sentence is back")
        attach(app, named: "empty-collection")
    }

    // MARK: - Fixtures

    /// Launch against a THROWAWAY library the app seeds for us. The root is a relative
    /// override, which `LibraryLocation` resolves inside the app's own container — an
    /// absolute path would not be writable from a sandboxed app.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-library-root", "uitest-fixture", "-seed-fixture-library"]
        app.launch()
        return app
    }

    private func switcherButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["Switch collection"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the title is not a control")
        return button
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
