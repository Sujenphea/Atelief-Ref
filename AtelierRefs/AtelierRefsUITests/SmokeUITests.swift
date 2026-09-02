//
//  SmokeUITests.swift
//  AtelierRefsUITests
//
//  099 · P2 (decision 10A) — the first UI test that has ever run on macOS in this repo.
//
//  **What this target is for, and what it is NOT for.** Three claims about the Mac app
//  were true only by inspection: that it launches at all against a library on disk, that
//  ⌘, still opens a Settings window, and that the sidebar draws the collections in the
//  order `BrowseCollectionTree` computes. The first two are statements about a PROCESS
//  and a WINDOW SERVER, which no `swift test` can make; the third has a unit test for the
//  ordering (`CollectionTargetsTests`) and nothing at all for the rendering of it, which
//  is the gap between "the array is right" and "the sidebar is right".
//
//  It is deliberately not a second home for logic tests. A UI test is the slowest and
//  flakiest kind there is, and the reason to accept that cost is that a launch and a
//  keystroke cannot be simulated any other way; anything that CAN be a `swift test`
//  belongs there. That is also why there are no layout assertions here: nothing below
//  reads a frame, a colour or a size. 099 · P5 and P6 add the ⌘K and palette flows.
//
//  **The library under test is written by the app itself at launch** — see
//  `AtelierRefs/Debug/FixtureLibrary.swift` — because this process has its own container
//  and cannot write into the app's, and because the app has no verb that would let a UI
//  test build a library through the interface in less time than the test would take.
//
//  **Signing.** `verify.sh` runs the rest of the app's stages with
//  `CODE_SIGNING_ALLOWED=NO`, and this bundle cannot: the XCTest runner's executable is
//  assembled by `lipo` and an unsigned arm64 binary is killed by the kernel before it
//  establishes its connection ("Test crashed with signal kill before establishing
//  connection"). The UI stage signs ad-hoc instead — see `scripts/verify.sh`.
//

import XCTest

final class SmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch

    /// The app opens a main window against the seeded library, and Home names the
    /// collection the fixture created.
    ///
    /// This is the assertion that everything under it depends on: the seeder ran, the
    /// override root resolved inside the sandbox, the database opened and migrated, the
    /// folder list published, and the shell rendered. A failure anywhere in that chain
    /// lands here first, which is why this flow asserts a NAMED card rather than "some
    /// cards" — an empty gallery and a gallery of the wrong library both look like a
    /// count, and neither looks like `Fixture.textures`.
    @MainActor
    func testLaunchShowsTheSeededCollectionOnHome() {
        let app = launch()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 60),
            "the app opened no window")

        let card = app.buttons[Fixture.homeCard(Fixture.textures)]
        XCTAssertTrue(
            card.waitForExistence(timeout: 60),
            "Home never showed a card for “\(Fixture.textures)” — the seeded library "
                + "did not reach the gallery")
        attach(app, named: "launch-home")
    }

    // MARK: - ⌘,

    /// ⌘, opens the Settings scene as its own window.
    ///
    /// Three steps, and the last is the one that matters. A window COUNT alone would
    /// pass if ⌘, opened a second MAIN window; a title match would pin a string macOS
    /// composes ("AtelierRefs Dev Settings") out of the display name and a localised
    /// word. So the flow remembers the launch window's identifier, finds the window that
    /// is not it, and asks THAT window for a control only the Settings scene draws.
    ///
    /// (`windows.containing(.staticText, identifier:)` would say this in one line and
    /// does not match here, though the element is plainly in the window's subtree —
    /// hence the explicit walk.)
    @MainActor
    func testCommandCommaOpensASettingsWindow() {
        let app = launch()
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 60), "the app opened no window")
        // Wait for the library rather than only the window: ⌘, sent into a shell that is
        // still bootstrapping is a keystroke with nowhere to go.
        XCTAssertTrue(
            app.buttons[Fixture.homeCard(Fixture.textures)].waitForExistence(timeout: 60),
            "the seeded library never appeared")
        let mainIdentifier = main.identifier

        // **Frontmost, then type.** A key event goes to whatever app is active, not to
        // whatever `XCUIApplication` a test is holding, and a cold first launch in a
        // batch can finish behind the runner. Both times this flow failed, ⌘, was typed
        // at nothing. `bringToFront` awaits `.runningForeground` — the state change
        // itself, so a signal and not a settling delay; there is no sleep here.
        bringToFront(app)
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(
            app.staticTexts[Fixture.settingsCaptureEndpoint].waitForExistence(timeout: 30),
            "⌘, drew nothing that only the Settings scene has")
        let opened = app.windows.allElementsBoundByIndex
            .filter { $0.identifier != mainIdentifier }
        XCTAssertEqual(
            opened.count, 1,
            "⌘, left \(opened.count) windows besides the one the app launched with")
        XCTAssertTrue(
            opened[0].staticTexts[Fixture.settingsCaptureEndpoint].exists,
            "the window ⌘, opened is not the Settings scene")
        attach(app, named: "settings-window")
    }

    // MARK: - The sidebar's order

    /// The sidebar lists the seeded collections in `BrowseCollectionTree` order, and the
    /// nested one appears under its parent when the parent is disclosed.
    ///
    /// The order is not arbitrary and not the alphabet: Unsorted is PINNED first
    /// (`BrowseCollectionTree.roots`), and the rest sort by the `sortIndex`
    /// `createCollection` appends with — so the fixture's creation order, Textures then
    /// Posters, is what the sidebar has to read. An alphabetical sidebar would put
    /// Posters first and pass every existing unit test.
    ///
    /// The disclosure click is the one piece of interaction in this suite. It is here
    /// because a nested collection is not merely invisible while collapsed — it is not
    /// in the accessibility hierarchy at all — so "one of the three is nested" is only a
    /// claim a test can make after expanding.
    @MainActor
    func testSidebarListsTheSeededCollectionsInOrder() {
        let app = launch()
        XCTAssertTrue(
            app.staticTexts[Fixture.sidebarRow(Fixture.textures)].waitForExistence(timeout: 60),
            "the sidebar never listed the seeded collections")

        XCTAssertEqual(
            sidebarCollectionNames(app),
            [Fixture.unsorted, Fixture.textures, Fixture.posters],
            "the collapsed sidebar is not in tree order")

        let disclosure = app.buttons[Fixture.sidebarDisclosure(Fixture.textures)]
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 10),
            "the parent collection has no disclosure control")
        // Frontmost first, for a reason particular to AppKit: a click into an INACTIVE
        // window is consumed by activating it unless the view under the pointer accepts
        // the first mouse, and `NSButton` does not while `NSTableView` does. So a click
        // on an unfocused sidebar selects the row and never presses the chevron — which
        // is exactly what a failing run's hierarchy showed (row selected, glyph still
        // "Expand"). Again a precondition, not a delay — and `bringToFront` WAITS for
        // the activation rather than requesting it, because the bare `activate()` this
        // line first carried let the click race the window server and failed the gate.
        bringToFront(app)
        // Hittable, not merely present. `activate()` returning and the window being key
        // are not the same instant, and a chevron that exists in the hierarchy can still
        // be behind an inactive window's activation click. This is the assertion the
        // first version of this flow was missing: it activated, clicked, and trusted.
        XCTAssertTrue(
            waitForHittable(disclosure, timeout: 15),
            "the disclosure control never became clickable")
        disclosure.click()

        let nested = app.staticTexts[Fixture.sidebarRow(Fixture.concrete)]
        XCTAssertTrue(
            nested.waitForExistence(timeout: 15),
            "disclosing “\(Fixture.textures)” did not reveal “\(Fixture.concrete)”")
        XCTAssertEqual(
            sidebarCollectionNames(app),
            [Fixture.unsorted, Fixture.textures, Fixture.concrete, Fixture.posters],
            "the nested collection is not under its parent")
        attach(app, named: "sidebar-expanded")
    }

    // MARK: - Fixtures

    /// The seeded library's names, and the identifiers the app puts on the elements that
    /// show them.
    ///
    /// **A deliberate second spelling.** The app's own copies are
    /// `FixtureLibrary.Names` and `AccessibilityID` (`AtelierRefs/`), and this bundle is
    /// a separate module running against the built app rather than a `@testable import`,
    /// so it cannot see either. Both sides are small and both name the other; that is
    /// the same seam 098 accepted on the phone.
    private enum Fixture {
        static let unsorted = "Unsorted"
        static let textures = "Textures"
        static let concrete = "Concrete"
        static let posters = "Posters"

        /// `AccessibilityID.sidebarCollectionRowPrefix`.
        static let sidebarRowPrefix = "sidebar.collection."
        /// `AccessibilityID.settingsCaptureEndpoint`.
        static let settingsCaptureEndpoint = "settings.capture.endpoint"

        /// `AccessibilityID.homeCollectionCard(_:)`.
        static func homeCard(_ name: String) -> String { "home.collection.\(name)" }
        /// `AccessibilityID.sidebarCollectionRow(_:)`.
        static func sidebarRow(_ name: String) -> String { sidebarRowPrefix + name }
        /// `AccessibilityID.sidebarCollectionDisclosure(_:)`.
        static func sidebarDisclosure(_ name: String) -> String {
            sidebarRow(name) + ".disclosure"
        }
    }

    /// Every collections-tree row, in the order the sidebar draws them.
    ///
    /// Reads the IDENTIFIER rather than the element's value: the row's label is an
    /// `NSTextField`, whose accessibility value is its string, and matching the string
    /// would find the Home card with the same name too. The prefix predicate is what
    /// scopes the query to the collections tree — the Spaces list is the same widget.
    @MainActor
    private func sidebarCollectionNames(_ app: XCUIApplication) -> [String] {
        app.staticTexts
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@", Fixture.sidebarRowPrefix))
            .allElementsBoundByIndex
            .map { String($0.identifier.dropFirst(Fixture.sidebarRowPrefix.count)) }
    }

    /// Launch against a THROWAWAY library the app seeds for us.
    ///
    /// The root arrives as `ATELIER_LIBRARY_ROOT` rather than `-library-root` because
    /// 099 · 8A left the argument arm DEBUG-only and the environment arm unconditional,
    /// and `LibraryLocation`'s doc comment names this target as the reason. It is a
    /// RELATIVE value, so it resolves under the sandboxed app's own Application Support
    /// container; an absolute path is not writable from there.
    ///
    /// `-AtelierDidCompleteOnboarding YES` goes FIRST and that ordering is load-bearing.
    /// `UserDefaults` parses launch arguments as `-key value` pairs into the argument
    /// domain, which outranks the persisted one — so this suppresses the first-run
    /// onboarding sheet without the app knowing a test exists. But a bare flag before it
    /// would swallow it as a VALUE (`-seed-fixture-library` would be read as the key and
    /// `-AtelierDidCompleteOnboarding` as its string), and the sheet would cover every
    /// flow below. Bare flags last — **both** of them, and the second one is why this
    /// paragraph is worth re-reading before adding a third.
    ///
    /// `-skip-capture-endpoint` (099 · 22A, `AtelierRefs/Debug/CaptureEndpointFlag.swift`)
    /// is the newer of the two. Nothing in this suite asserts anything about the browser
    /// extension — a window, a Settings scene and a sidebar order is the whole of it — but
    /// starting the endpoint reads the capture token out of the LOGIN keychain, whose ACL
    /// is bound to the reading binary's code signature. This stage signs ad-hoc and must
    /// (see the header), so every rebuild is a new cdhash, macOS raises a `SecurityAgent`
    /// prompt, and an unattended `xcodebuild` never answers it: all three flows failed
    /// with "process main thread busy for 30.0s" until this flag existed. 22A also took
    /// that read off the main actor, so the app can no longer HANG on it — but the prompt
    /// still appears, and a flow waiting on a dialog nobody will click still times out.
    /// The Settings row this suite asserts (`settings.capture.endpoint`) renders whether
    /// or not the endpoint is running; only its foreground style depends on that, so the
    /// flag costs this suite no coverage.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtelierDidCompleteOnboarding", "YES",
            "-seed-fixture-library",
            "-skip-capture-endpoint",
        ]
        app.launchEnvironment["ATELIER_LIBRARY_ROOT"] = "uitest-fixture"
        app.launch()
        return app
    }

    /// Bring the app to the front and **wait until it is actually there**.
    ///
    /// `activate()` is a request, not a transition: it returns before the window server
    /// has made the app frontmost. Both flows that touch the running app were written
    /// with a bare `activate()` and both flaked on the gate — ⌘, typed at whatever was
    /// in front, and a sidebar click consumed by the activation it was supposed to
    /// follow. Waiting on `.runningForeground` is the state change itself, so this is a
    /// signal and not a settling delay; there is still no `sleep` in this file.
    @MainActor
    private func bringToFront(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "the app never came to the foreground")
    }

    /// Poll `isHittable` — the one XCUITest predicate with no `waitForExistence` of its
    /// own. An element can exist, and be the right element, and still not take a click
    /// because something is over it or its window is not key.
    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            _ = element.waitForExistence(timeout: 0.2)
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
