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

        dismissShareSheet(app)

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

    // MARK: - The offer the share sheet leaves behind (096 · 3B)

    func testClearingAfterASendRemovesTheControl() {
        let app = launch()
        let send = app.buttons["export.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()
        XCTAssertTrue(waitForShareSheet(in: app, timeout: 90), "sending produced no share sheet")
        dismissShareSheet(app)

        // **The offer.** Nothing on the phone ever left the inbox before 096 · 3B, so every
        // export re-sent every capture ever made. `UIActivityViewController`'s completion
        // cannot tell a successful AirDrop from a cancelled one and the Mac says nothing
        // back (091 · D4), so the only party who knows is asked — once, here.
        let clear = app.buttons["export.clear"]
        XCTAssertTrue(
            clear.waitForExistence(timeout: 30),
            "dismissing the share sheet did not offer to retire what was sent")
        attach(app, named: "export-sent-offer")
        clear.tap()

        // Clear retires the ids that reached the manifest — all three of them — so the
        // pending set empties and the control withdraws, which is the resting state 093 § 2
        // designed. This is the ONE thing in the app that makes the count go down, and
        // nothing else in the suite drives it.
        XCTAssertTrue(
            waitForDisappearance(of: send, timeout: 30),
            "the captures were retired and the send control is still there")
        XCTAssertTrue(
            waitForDisappearance(of: clear, timeout: 10),
            "the offer stayed up after it was answered")
    }

    func testKeepingAfterASendLeavesTheCountAlone() {
        let app = launch()
        let send = app.buttons["export.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()
        XCTAssertTrue(waitForShareSheet(in: app, timeout: 90), "sending produced no share sheet")
        dismissShareSheet(app)

        let keep = app.buttons["export.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 30), "no offer to answer")
        keep.tap()

        // **Keep is the safe answer and it must cost nothing.** The captures stay pending
        // and go out again next time; a re-import collapses on blob hash (091 · D4). The
        // count is the assertion, not the control's presence: a Keep that quietly retired
        // one record would leave the control up and only the number would say so.
        XCTAssertTrue(
            waitForDisappearance(of: keep, timeout: 10), "the offer stayed up after Keep")
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the send control went away")
        XCTAssertTrue(
            send.label.contains("\(pending)"),
            "Keep changed the waiting count: \(send.label)")
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

    /// Out of the system share sheet without sending anywhere — the archive is written
    /// either way, and the offer is what this file is about.
    ///
    /// Shared by the two cases below and the one above, which each learned it separately.
    private func dismissShareSheet(_ app: XCUIApplication) {
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    /// Wait for an element to go away. `waitForExistence` has no negative form, and
    /// `!exists` read once is a race against an animation.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
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
