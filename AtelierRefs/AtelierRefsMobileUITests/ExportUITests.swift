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

        // The system share sheet. Its own view has no stable public identity, so this
        // polls every anchor it could have at once rather than spending a whole timeout on
        // the first one — which is how this went flaky: `collectionViews` for 20s and then
        // `Copy` for 5 gives the SECOND anchor five seconds on a simulator where the first
        // never appears. And the budget is generous on purpose: presenting the sheet means
        // discovering every share extension installed, which on a cold or loaded simulator
        // is tens of seconds. A slow machine must not read as a broken app.
        XCTAssertTrue(
            waitForShareSheet(in: app, timeout: 90),
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
            send.waitForExistence(timeout: 30),
            "the export control vanished after a send — the captures were consumed")
        XCTAssertTrue(
            send.label.contains("\(pending)"),
            "the waiting count changed after an export: \(send.label)")
    }

    /// Whether a share sheet is up, by any of the marks one leaves.
    ///
    /// Three anchors because the sheet is not the app's view and its internals are not a
    /// contract: the activity grid, a Copy activity, and — the one that holds whatever
    /// Apple does inside it — the app's own control disappearing behind a modal
    /// presentation while the app is still running. Any one of them means the tap
    /// produced a sheet.
    private func waitForShareSheet(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let send = app.buttons["export.send"]
        let up = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if app.collectionViews.firstMatch.exists { return true }
                if app.buttons["Copy"].exists { return true }
                guard app.state == .runningForeground else { return false }
                return send.exists ? !send.isHittable : true
            },
            object: nil)
        return XCTWaiter().wait(for: [up], timeout: timeout) == .completed
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
