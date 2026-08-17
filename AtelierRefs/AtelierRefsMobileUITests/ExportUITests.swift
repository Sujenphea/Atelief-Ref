//
//  ExportUITests.swift
//  AtelierRefsMobileUITests
//
//  092 · S6b — the one control that sends.
//
//  What `InboxArchive`'s own suite cannot reach: that the control appears only when there
//  is something to send, that it says how much, that tapping it produces a share sheet, and
//  that the captures are STILL THERE afterwards. That last one is the point of the design —
//  nothing is deleted on the promise that a transport succeeded — and it is invisible to a
//  unit test because it is a statement about what the user sees next.
//

import XCTest

final class ExportUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The fixture leaves this many captures waiting (`FixtureLibrary.pendingCaptures`).
    private let pending = 3

    func testTheControlSaysHowManyCapturesAreWaiting() {
        let app = launch()
        let send = app.buttons["export.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "the export control never appeared")
        XCTAssertTrue(
            send.label.contains("\(pending)"),
            "the control does not say how many are waiting: \(send.label)")
    }

    func testSendingPresentsAShareSheetAndKeepsTheCaptures() {
        let app = launch()
        let send = app.buttons["export.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()

        // The system share sheet. Its own view has no stable public identity, so this looks
        // for the one thing every configuration of it has: a Copy activity.
        let sheet = app.collectionViews.firstMatch
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 20) || app.buttons["Copy"].waitForExistence(timeout: 5),
            "sending produced no share sheet")
        attach(app, named: "export-share-sheet")

        // Out of the sheet without sending anywhere — the archive is written either way.
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else {
            app.swipeDown(velocity: .fast)
        }

        // **The captures are still waiting.** An export copies; it does not consume. A user
        // who cancels the share sheet, or AirDrops to a Mac that is asleep, has lost
        // nothing — and a second import of the same archive collapses on blob hash.
        XCTAssertTrue(
            send.waitForExistence(timeout: 10),
            "the export control vanished after a send — the captures were consumed")
        XCTAssertTrue(
            send.label.contains("\(pending)"),
            "the waiting count changed after an export: \(send.label)")
    }

    // MARK: - Fixtures

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-library-root", "uitest-fixture", "-seed-fixture-library"]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
