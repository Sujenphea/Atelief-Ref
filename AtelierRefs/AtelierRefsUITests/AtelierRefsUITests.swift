//
//  AtelierRefsUITests.swift
//  AtelierRefsUITests
//
//  Load-bearing XCUITest smoke suite (production readiness G11). Keeps coverage
//  few and high-value: launch, tab switching, and that the shell is interactive.
//

import XCTest

final class AtelierRefsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch the app and switch Canvas → Library → Sweeps → Canvas.
    @MainActor
    func testLaunchAndSwitchTabs() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // macOS TabView exposes tabs as radio buttons / buttons in the tab bar.
        let canvas = app.radioButtons["Canvas"].firstMatch
        let library = app.radioButtons["Library"].firstMatch
        let sweeps = app.radioButtons["Sweeps"].firstMatch

        // Fallback for environments that surface tabs as buttons.
        let canvasControl = canvas.exists ? canvas : app.buttons["Canvas"].firstMatch
        let libraryControl = library.exists ? library : app.buttons["Library"].firstMatch
        let sweepsControl = sweeps.exists ? sweeps : app.buttons["Sweeps"].firstMatch

        XCTAssertTrue(canvasControl.waitForExistence(timeout: 5), "Canvas tab missing")
        XCTAssertTrue(libraryControl.exists, "Library tab missing")
        XCTAssertTrue(sweepsControl.exists, "Sweeps tab missing")

        libraryControl.click()
        sweepsControl.click()
        canvasControl.click()

        // Shell still alive after tab churn.
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    /// Library tab shows the folder chrome (sidebar / Unsorted).
    @MainActor
    func testLibraryShowsFolderChrome() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let library = app.radioButtons["Library"].firstMatch.exists
            ? app.radioButtons["Library"].firstMatch
            : app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.click()

        // Protected default folder is always present after bootstrap.
        let unsorted = app.staticTexts["Unsorted"].firstMatch
        XCTAssertTrue(
            unsorted.waitForExistence(timeout: 8),
            "Expected Unsorted folder in the Library sidebar after bootstrap")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
