//
//  AtelierRefsUITests.swift
//  AtelierRefsUITests
//
//  Load-bearing XCUITest smoke suite (production readiness G11). Keeps coverage
//  few and high-value: launch, top-bar navigation (the NavigationStack shell that
//  replaced the old 3-tab TabView), and that the shell is interactive.
//

import XCTest

final class AtelierRefsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch with a deterministic root (skip last-collection restore).
    @MainActor
    private func launchFreshShell() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-fresh-nav"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    /// Launch and navigate the top-bar shell: the app-level Spaces / Sweeps
    /// affordances replaced the old Canvas / Library / Sweeps tabs and are
    /// reachable from every screen. Opening Spaces pushes the Spaces list.
    @MainActor
    func testLaunchAndNavigateShell() throws {
        let app = launchFreshShell()

        // The app-level toolbar affordances (former tabs) are present.
        let spaces = app.buttons["Spaces"].firstMatch
        let sweeps = app.buttons["Sweeps"].firstMatch
        XCTAssertTrue(spaces.waitForExistence(timeout: 5), "Spaces toolbar entry missing")
        XCTAssertTrue(sweeps.exists, "Sweeps toolbar entry missing")

        // Opening Spaces pushes the Spaces list (its own New Space affordance).
        spaces.click()
        let newSpace = app.buttons["New Space"].firstMatch
        XCTAssertTrue(
            newSpace.waitForExistence(timeout: 5),
            "Expected the Spaces list (New Space) after opening Spaces")

        // Shell still alive after navigation.
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    /// The Collections gallery (the shell's root, replacing the folder sidebar)
    /// shows the protected Unsorted collection after bootstrap.
    @MainActor
    func testGalleryShowsUnsortedCollection() throws {
        let app = launchFreshShell()

        // The Unsorted cover card is always present after bootstrap. It surfaces
        // as a button labelled by its title (with a static-text fallback).
        let unsortedButton = app.buttons["Unsorted"].firstMatch
        let unsortedText = app.staticTexts["Unsorted"].firstMatch
        XCTAssertTrue(
            unsortedButton.waitForExistence(timeout: 8) || unsortedText.exists,
            "Expected the Unsorted collection card on the gallery after bootstrap")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
