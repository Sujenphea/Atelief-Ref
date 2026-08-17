//
//  Tier2ShareUITests.swift
//  AtelierRefsMobileUITests
//
//  092 · S4b tier 2 — the one span nothing else can reach.
//
//  `PageExtractorTests` proves what a harvested page becomes, and `ios-preprocessor.test.js`
//  proves the script's caps and its article indexing against a stubbed DOM. Between them
//  sits the thing neither can touch: **Safari actually running the script inside a real
//  page and handing the result to the extension.** That needs Safari, a page, and a share
//  sheet, so it needs a UI test — and it is the only test in this suite that drives another
//  app.
//
//  Which makes it the most fragile test here, and it is written accordingly: every step
//  attaches a screenshot on the way past, the share sheet is found by several anchors
//  rather than one, and the assertion is a COUNT the app already displays rather than
//  anything reached into.
//
//  **What it asserts, and what it deliberately does not.** It asserts that a share from
//  Safari lands one more capture in the inbox than was there before — which is only true
//  if the activation rule offered Atelier for a web page, the preprocessing file ran, the
//  results decoded, the extractor produced a capture and the writer committed it. It does
//  NOT assert which tier produced it: the app shows a count, not a provenance, and adding
//  a debug surface for that would be a permanent thing built for one test. Reading the
//  record off the container proves the rest, and 421 records that reading.
//
//  It also runs against the DEFAULT library root, not the `-library-root` fixture: the
//  share extension is a separate process and never sees the app's launch arguments, so it
//  writes where `LibraryLocation.defaultRoot()` says. A test that seeded a throwaway root
//  would be counting a different inbox than the one being written to.
//

import XCTest

final class Tier2ShareUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// **This test cannot pass until tier 2 is switched on, and tier 2 is off.**
    ///
    /// `NSExtensionActivationSupportsWebPageWithMaxCount` and
    /// `NSExtensionJavaScriptPreprocessingFile` are commented out of the extension's
    /// Info.plist — see there for why, at length. The short version: with the keys on,
    /// Safari sends the page item INSTEAD of a URL, this simulator never produces the
    /// script's results (`NSItemProviderErrorDomain -1000` over a dead connection to the
    /// web content process), and the two together made a share that used to become a link
    /// capture into a lost one.
    ///
    /// So it is skipped rather than deleted, and skipped rather than left red: a red test
    /// nobody can fix is noise, and a deleted one takes the Safari driving, the fixture
    /// server and the share-sheet anchors with it — all of which cost real runs to learn
    /// (Safari has no `ShareButton` on iOS 26; the sheet row is labelled by the HOST APP).
    /// Turn the keys on, delete the `XCTSkip`, and this is the device check tier 2 owes.
    func testASafariShareLandsACaptureInTheInbox() throws {
        throw XCTSkip(
            "tier 2 is off in the extension's Info.plist — see 421 and the plist's own "
                + "comment; turn both keys on to run this against a device")
    }

    func deviceOnly_testASafariShareLandsACaptureInTheInbox() throws {
        let server = try PageFixtureServer(html: Self.fixtureHTML(port:), image: Self.jpeg())
        try server.start()
        defer { server.stop() }

        let before = pendingCount()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCTAssertTrue(
            safari.wait(for: .runningForeground, timeout: 30), "Safari did not come up")

        openPage(server.pageURL, in: safari)
        shareToAtelier(from: safari)

        // Back to the app: the export control counts what is waiting, and the receipt the
        // extension showed is not something this process can see.
        let after = pendingCount()
        XCTAssertEqual(
            after, before + 1,
            "a share from Safari did not reach the inbox (was \(before), now \(after))")
    }

    // MARK: - Safari

    private func openPage(_ url: String, in safari: XCUIApplication) {
        // The address field is a text field in the toolbar; its identifier has moved
        // between releases, so it is found by either of the two it has had.
        let field = safari.textFields["Address"].exists
            ? safari.textFields["Address"]
            : safari.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no address field in Safari")
        field.tap()
        // A second tap target appears once the field is focused on some layouts; typing
        // into the focused field works either way.
        safari.typeText(url + "\n")

        // The page's own text is what "loaded" means here — the toolbar is up before the
        // page is, so waiting on a button would pass on a blank tab.
        XCTAssertTrue(
            safari.staticTexts["A page for the share sheet to read."]
                .waitForExistence(timeout: 60),
            "Safari never rendered the fixture page")
        attach(safari, named: "tier2-page-loaded")
    }

    /// Open the share sheet and pick Atelier out of it.
    ///
    /// **Share is inside More on iOS 26's compact Safari.** The toolbar is
    /// `BackButton` · `PageFormatMenuButton` · the address field · `ReloadButton` ·
    /// `MoreMenuButton`, and there is no `ShareButton` at all — a fact this test learned
    /// by dumping Safari's accessibility tree, and the reason it tries the direct button
    /// first and then the menu rather than assuming either.
    private func shareToAtelier(from safari: XCUIApplication) {
        let direct = safari.buttons["ShareButton"]
        if direct.exists {
            direct.tap()
        } else {
            let more = safari.buttons["MoreMenuButton"]
            XCTAssertTrue(
                more.waitForExistence(timeout: 30),
                "Safari offered neither a share button nor a More menu")
            more.tap()
            attach(safari, named: "tier2-more-menu")
            let share = safari.buttons["Share…"].exists
                ? safari.buttons["Share…"] : safari.buttons["Share"]
            XCTAssertTrue(
                share.waitForExistence(timeout: 30), "no Share item in Safari's More menu")
            share.tap()
        }

        // **The row is labelled by the HOST APP, not the extension.** The share sheet shows
        // "AtelierRefsMobile" even though the extension's own display name is
        // "AtelierRefsShare" — checked against the sheet itself, because guessing the
        // other way is what the first run of this test did.
        let atelier = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'AtelierRefs'")).firstMatch
        if !atelier.waitForExistence(timeout: 30) {
            attach(safari, named: "tier2-share-sheet-without-atelier")
            // Not a hard failure yet: scrolling the app row is what a person would do.
            safari.collectionViews.firstMatch.swipeLeft()
        }
        attach(safari, named: "tier2-share-sheet")
        XCTAssertTrue(
            atelier.waitForExistence(timeout: 15),
            "Atelier was not offered in Safari's share sheet")
        atelier.tap()

        // The extension writes the record and shows its receipt for ~0.95s, then dismisses
        // itself. Waiting for the sheet to go is waiting for the write to have happened.
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !atelier.exists }, object: nil)
        _ = XCTWaiter().wait(for: [gone], timeout: 60)
        attach(safari, named: "tier2-after-share")
    }

    // MARK: - The app's count

    /// What the export control says, or 0 when it is not there (an empty inbox hides it).
    ///
    /// The app is launched WITHOUT the fixture seeder, against the real library root — see
    /// the file header. Terminated afterwards so the next read is a fresh count rather
    /// than a cached view.
    private func pendingCount() -> Int {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let send = app.buttons["export.send"]
        guard send.waitForExistence(timeout: 30) else { return 0 }
        let digits = send.label.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // MARK: - Fixtures

    /// A page shaped like the thing tier 2 is for: Open Graph tags a generic extractor
    /// reads, and an image big enough to survive the script's icon floor.
    ///
    /// Deliberately NOT dressed up as a tweet. Faking x.com from `127.0.0.1` would test
    /// the extractor's dispatch, which `PageExtractorTests` already does against a hundred
    /// harvests in microseconds; what only this test can prove is that a real Safari, on a
    /// real page, produces a snapshot the pipeline accepts.
    private static func fixtureHTML(port: UInt16) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <title>A concrete stair</title>
        <meta property="og:title" content="A concrete stair">
        <meta property="og:site_name" content="Atelier Fixture">
        <meta property="og:image" content="\(PageFixtureServer.imageURL(port: port))">
        <link rel="canonical" href="http://127.0.0.1:\(port)/page.html">
        </head><body>
        <article>
          <p>A page for the share sheet to read.</p>
          <img src="\(PageFixtureServer.imageURL(port: port))" width="600" height="400">
        </article>
        </body></html>
        """
    }

    /// A real JPEG, 600×400 — over the script's 100px floor on both sides.
    private static func jpeg() -> Data {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) {
            context in
            UIColor(hue: 0.08, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
