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
//  attaches a screenshot on the way past, and the share sheet is found by several anchors
//  rather than one.
//
//  **What it asserts.** First that a share from Safari lands one more capture in the inbox
//  than was there before — true only if the activation rule offered Atelier for a web page,
//  the preprocessing file ran, the results decoded, the extractor produced a capture and the
//  writer committed it. Then the RECORD that landed: its `originalURL`, its `og:site_name`,
//  its `capturedVia` stamp, and that it has a payload.
//
//  **The second half is why this is a test of tier 2 rather than of the share sheet**
//  (096 review 11A). The count alone is true whenever a capture landed, and stays true when
//  tier 2 has silently degraded to tier 1 — a preprocessing script that threw, a plist
//  boundary that broke the way 422 describes, a media fetch that failed. All three produce
//  a capture, increment the count, and mean the feature under test did not work. 422 is not
//  hypothetical: it shipped switched off for four days on a wrong belief, and this test as
//  originally written would not have caught it.
//
//  This reads the record off the App Group container directly, which is why the target
//  carries an entitlements file and a one-key Info.plist. The alternative was a debug-only
//  provenance surface in the app — a permanent thing built for one test — and this header
//  used to argue for the count on exactly that ground. The entitlement is the smaller cost:
//  it sits on a target that never ships, and it needs nothing added to the product.
//
//  It also runs against the DEFAULT library root, not the `-library-root` fixture: the
//  share extension is a separate process and never sees the app's launch arguments, so it
//  writes where `LibraryLocation.defaultRoot()` says. A test that seeded a throwaway root
//  would be counting a different inbox than the one being written to.
//

import AtelierCapture
import AtelierCore
import XCTest

final class Tier2ShareUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// **The one span nothing else can reach, and it only exists on a device.**
    ///
    /// Tier 2's keys are on in the extension's Info.plist. Everything else about it is
    /// covered by faster tests; this is the only one that puts a real Safari on a real
    /// page and asks whether the snapshot survives the trip into the extension.
    ///
    /// It drives another app, so it is written for that: every step attaches a
    /// screenshot, the share sheet is found by several anchors rather than one, and the
    /// assertion is a COUNT the app already displays rather than anything reached into.
    /// Two anchors here cost real runs to learn — Safari has no `ShareButton` on iOS 26,
    /// and the sheet's row is labelled by the HOST APP, not the extension.
    @MainActor
    func testASafariShareLandsACaptureInTheInbox() throws {
        let server = try PageFixtureServer(html: Self.fixtureHTML(port:), image: Self.jpeg())
        try server.start()
        defer { server.stop() }

        let before = pendingCount()
        let recordsBefore = Set(try inboxRecords().map(\.id))

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

        // **And then the record itself, which is what makes this a test of TIER 2** (096
        // review 11A). The count above is true whenever a capture landed — and it stays
        // true when the preprocessing script threw, when the plist boundary broke the way
        // 422 describes, or when the media fetch failed. Every one of those produces a
        // capture, increments the count, and means the feature under test did not work.
        //
        // The record is what separates them, and it is a file in the App Group container
        // this target now has an entitlement for. Nothing was added to the app to make this
        // readable: the extension already writes it, `InboxLayout` already composes the
        // path, and `InboxRecord.makeDecoder()` is already the one decoder any reader of
        // the inbox must use — this reads the same bytes the Mac's drain will.
        let landed = try inboxRecords().filter { !recordsBefore.contains($0.id) }
        XCTAssertEqual(landed.count, 1, "expected exactly one new record")
        guard let record = landed.first else { return }

        let provenance = record.request.provenance

        // A plain sanity check, and deliberately NOT the tier discriminator: the fixture is
        // served from 127.0.0.1, so `web` is what BOTH tiers would record. Faking x.com off
        // localhost would test the extractor's dispatch, which `PageExtractorTests` already
        // does against a hundred harvests in microseconds.
        XCTAssertEqual(provenance.platform, "web")

        // The page's own URL. `originalURL` is what 18A dedup keys on, so a capture that
        // arrives with the wrong one forks an asset instead of colliding with the existing
        // one — the failure that presents as duplicates months later rather than as an error.
        XCTAssertEqual(
            provenance.originalURL, server.pageURL,
            "the record's originalURL is not the page that was shared")

        // **The first thing only tier 2 can produce.** `authorName` comes from the page's
        // `og:site_name`, which lives in the DOM and reaches the extractor only through the
        // preprocessing script. Tier 1 has no way to know it — a share sheet hands over a
        // URL and a title and nothing else — so this is nil on every degrade path: a script
        // that threw, a plist boundary that broke the way 422 describes, an item that would
        // not load.
        //
        // The page's TITLE deliberately is not used for this. Safari supplies the document
        // title as the share item's `attributedTitle`, so a tier-1 degrade of this very page
        // would still carry it, and an assertion that passes on the failure it is meant to
        // catch is worse than none.
        XCTAssertEqual(
            provenance.authorName, Self.fixtureSiteName,
            "no og:site_name on the record, so the DOM snapshot never reached the extractor "
            + "— this is the tier-2 degrade the count assertion cannot see")

        // The stamp saying a phone did this, on every share regardless of tier. Read by
        // pattern match: `rawMetadata` is a `JSONValue`, which is a tree and not a
        // dictionary, and the object case is the only one a provenance stamp is ever in.
        if case .object(let metadata)? = provenance.rawMetadata {
            XCTAssertEqual(
                metadata[ShareCapture.capturedViaKey],
                .string(ShareCapture.capturedViaValue),
                "the capture is not stamped as an iOS share")
        } else {
            XCTFail("rawMetadata is not an object, so it carries no capturedVia stamp")
        }

        // And the picture. The fixture page renders one image well above the preprocessor's
        // icon floor, so tier 2 must have chosen it and the extension must have fetched it.
        // A media-less record here means the extractor picked nothing or the fetch failed —
        // the third of `payload=none`'s three indistinguishable causes, made distinguishable.
        XCTAssertNotNil(
            record.payloadFile,
            "the record has no payload, so the media the page rendered was never fetched")
    }

    // MARK: - The inbox this share was supposed to land in

    /// Every committed record in the shared inbox, decoded with the inbox's own decoder.
    ///
    /// **Read-only, and it reads the DEFAULT root** — the share extension is a separate
    /// process and never sees this target's launch arguments, so it writes where
    /// `LibraryLocation.defaultRoot()` says. A test that seeded a throwaway root with
    /// `-library-root` would be counting a different inbox than the one being written to,
    /// which is the trap the header above already records for `pendingCount()`.
    ///
    /// `LibraryLocation` resolves the App Group from THIS bundle's
    /// `AtelierAppGroupIdentifier`, which is why the target carries an Info.plist for one
    /// key and an entitlements file for one capability. Both are fed from
    /// `$(ATELIER_APP_GROUP)`, so the container this runner is granted and the one it asks
    /// for cannot disagree.
    private func inboxRecords() throws -> [InboxRecord] {
        let layout = InboxLayout(libraryRoot: try LibraryLocation.defaultRoot())
        let decoder = InboxRecord.makeDecoder()
        // An absent inbox is an empty inbox, not a failure — nothing has ever been shared
        // on a fresh simulator, and that is the normal state of the `before` reading.
        return (try? layout.pendingRecordURLs())?.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(InboxRecord.self, from: data)
        } ?? []
    }

    // MARK: - Safari

    @MainActor
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
    @MainActor
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
    /// `@MainActor` because `XCUIElement.label` is, and this reads one. The class is not
    /// annotated instead: `XCTestCase.setUp()` is nonisolated, and a main-actor class
    /// cannot override it.
    ///
    /// The app is launched WITHOUT the fixture seeder, against the real library root — see
    /// the file header. Terminated afterwards so the next read is a fresh count rather
    /// than a cached view.
    @MainActor
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
    /// The page's `og:site_name`, and the one signal in this fixture that ONLY the DOM
    /// snapshot can carry into a record. Named here so the assertion and the HTML below
    /// cannot drift apart — the whole test turns on them being the same string.
    static let fixtureSiteName = "Atelier Fixture"

    private static func fixtureHTML(port: UInt16) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <title>A concrete stair</title>
        <meta property="og:title" content="A concrete stair">
        <meta property="og:site_name" content="\(fixtureSiteName)">
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

    /// `@MainActor` for `screenshot()`, which is — see ``pendingCount()``.
    @MainActor
    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
