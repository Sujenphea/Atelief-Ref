//
//  SwitcherNavigationTests.swift
//  AtelierRefsTests
//
//  099 · P5 — what happens when ⌘K commits, and the two claims that only look like
//  implementation details until they are wrong.
//
//  **1. The overlay pops FIRST.** The panel opens on top of the full-window
//  item-detail overlay and on top of a Space board — that is the requirement, not a
//  bonus — so a destination committed from either has to clear `presentedItemID`
//  BEFORE the route changes. The other order leaves the overlay standing over a pane
//  that has already moved. `overlayPopsBeforeTheRouteChanges` asserts the SEQUENCE
//  by observing the selection's own publisher, which fires in `willSet`: whatever
//  `presentedItemID` reads as inside that sink happened first.
//
//  **2. ⌘K reaches every surface.** Mechanically that is one fact — the row is
//  `.global`, i.e. a menu key equivalent, which `NSMenu` matches before any first
//  responder. The Space canvas's `keyDown` and the detail page's key catcher both
//  read BARE keys and would never forward a chord they do not know, so a scoped
//  binding would have worked everywhere except the two places the phase names.
//

import AppKit
import AtelierCore
import Combine
import Foundation
import SwiftUI
import Testing
@testable import AtelierRefs

@MainActor
@Suite("⌘K: what it commits, and where it can be pressed", .timeLimit(.minutes(1)))
struct SwitcherNavigationTests {

    private func makeRecents(_ label: String) throws -> SwitcherRecents {
        let defaults = try #require(
            UserDefaults(suiteName: "switcher-nav-\(label)-\(UUID().uuidString)"))
        let recents = SwitcherRecents(defaults: defaults)
        recents.activate(libraryID: "L")
        return recents
    }

    // MARK: - The commit sequence

    @Test("the detail overlay pops BEFORE the route changes")
    func overlayPopsBeforeTheRouteChanges() throws {
        let nav = NavModel(initialPath: [], initialSelection: .home)
        let recents = try makeRecents("order")
        let target = SidebarItem.space(UUID())
        nav.presentedItemID = UUID()
        nav.showSwitcher = true

        // `@Published` fires in `willSet`, so inside this sink the selection is
        // still the OLD one — and whatever `presentedItemID` reads as here is what
        // it was set to before the selection moved.
        var overlayAtSelectionChange: [UUID?] = []
        let token = nav.$sidebarSelection
            .dropFirst()
            .sink { _ in overlayAtSelectionChange.append(nav.presentedItemID) }
        defer { token.cancel() }

        nav.commitSwitcher(target, recents: recents)

        #expect(overlayAtSelectionChange == [nil], "the route moved with the overlay still up")
        #expect(nav.sidebarSelection == target)
        #expect(nav.presentedItemID == nil)
    }

    @Test("committing the destination you are ALREADY on still pops the overlay")
    func recommittingTheOpenDestinationStillPopsTheOverlay() throws {
        let nav = NavModel(initialPath: [], initialSelection: .home)
        let recents = try makeRecents("same")
        nav.presentedItemID = UUID()

        // The shape a "get me out of this picture" ⌘K takes: the user is deep in the
        // overlay and switches to the pane they were already on. Nothing about the
        // ROUTE changes, so an implementation that only cleaned up on a real
        // navigation would leave the overlay standing.
        nav.commitSwitcher(.home, recents: recents)
        #expect(nav.sidebarSelection == .home)
        #expect(nav.presentedItemID == nil)
    }

    @Test("committing from a Space board lands on the destination and resets the path")
    func commitFromASpaceBoard() throws {
        let nav = NavModel(
            initialPath: [.collection(UUID())], initialSelection: .space(UUID()))
        let recents = try makeRecents("board")
        let target = SidebarItem.savedSearch(UUID())

        nav.commitSwitcher(target, recents: recents)
        #expect(nav.sidebarSelection == target)
        // A sidebar selection is a root; the within-collection drill-down goes with
        // it (`selectSidebar`'s existing rule, inherited rather than re-implemented).
        #expect(nav.path.isEmpty)
    }

    @Test("committing closes the panel and records the visit")
    func commitClosesThePanelAndRecordsTheVisit() throws {
        let nav = NavModel(initialPath: [], initialSelection: .home)
        let recents = try makeRecents("record")
        let target = SidebarItem.collection(UUID())
        nav.showSwitcher = true

        nav.commitSwitcher(target, recents: recents)
        #expect(!nav.showSwitcher)
        #expect(recents.destinations == [target])

        // …and the second visit reorders rather than duplicating, so the MRU the
        // NEXT ⌘K ranks with is the one this one just wrote.
        nav.commitSwitcher(.home, recents: recents)
        nav.commitSwitcher(target, recents: recents)
        #expect(recents.destinations == [target, .home])
    }

    // MARK: - The binding

    @Test("⌘K is in the key map, is global, and collides with nothing")
    func commandKIsGlobalAndUncontested() {
        let shortcut = KeyMap.all.first { $0.title == "Go to…" }
        #expect(shortcut != nil, "the key map has no row for the quick switcher")
        #expect(shortcut?.keys == [.character("k")])
        #expect(shortcut?.modifiers == [.command])
        // `.global` is what makes the requirement true: a menu key equivalent is
        // matched before the first responder, so the chord reaches the panel from
        // inside the item-detail overlay and from a Space board.
        #expect(shortcut?.scope == .global)
        #expect(shortcut?.status == .bound)

        let chord = Chord(key: .character("k"), modifiers: [.command])
        let claimants = (KeyMap.all + KeyMap.planned).filter { $0.chords.contains(chord) }
        #expect(claimants.count == 1, "⌘K is claimed by \(claimants.map(\.title))")
    }

    @Test("no surface binds a bare K that ⌘K could be confused with")
    func bareKIsNotBoundEither() {
        // Not a collision (⌘K and K are different chords) but worth stating: the
        // board and the grid read bare letters, and a bare `K` appearing later would
        // be the moment to re-read `GoToCommand`'s note about menu-first matching.
        let bare = Chord(key: .character("k"), modifiers: [])
        #expect(!KeyMap.all.contains { $0.chords.contains(bare) })
    }

    // MARK: - The panel's window

    @Test("the host window gets its first responder back when the panel closes")
    func theHostWindowGetsItsResponderBack() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(responder)
        #expect(window.makeFirstResponder(responder))

        let controller = SwitcherPanelController()
        controller.present(over: window, rootView: AnyView(Color.clear.frame(width: 400, height: 200)))
        #expect(controller.isPresented)

        // Drop the host's responder while the panel is up. This is what actually
        // happens — SwiftUI focus moves into the panel's field — and it is what makes
        // this assertion mean something: without the hand-back the window is left
        // with no responder at all, which is the "shell alive but deaf" state this
        // discipline exists to prevent.
        window.makeFirstResponder(nil)

        controller.dismiss()
        #expect(!controller.isPresented)
        #expect(window.firstResponder === responder)
        window.orderOut(nil)
    }

    @Test("present is a no-op while one is up, and dismiss is idempotent")
    func presentAndDismissAreIdempotent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = SwitcherPanelController()
        let content = AnyView(Color.clear.frame(width: 400, height: 200))

        controller.dismiss()  // before anything was ever shown
        #expect(!controller.isPresented)

        controller.present(over: window, rootView: content)
        let first = controller.panel
        controller.present(over: window, rootView: content)
        #expect(controller.panel === first, "a second present replaced the panel")

        controller.dismiss()
        controller.dismiss()
        #expect(!controller.isPresented)
        window.orderOut(nil)
    }

    @Test("the panel is centred under the host's top edge")
    func panelGeometryIsAnchoredToTheTop() {
        let host = NSRect(x: 100, y: 200, width: 1000, height: 700)
        let size = NSSize(width: 560, height: 360)
        let origin = SwitcherPanelController.origin(forPanelSize: size, over: host)

        // Horizontally centred…
        #expect(origin.x == (host.midX - 280).rounded())
        // …and hung from the TOP edge, which in AppKit's upward y axis means the
        // origin moves DOWN as the panel grows. A panel anchored by its bottom would
        // climb off its inset the first time the result list changed height.
        #expect(origin.y == (host.maxY - SwitcherLayout.topInset - size.height).rounded())
    }

    @Test("the panel narrows on a small window but never below its minimum")
    func panelWidthClampsToTheHost() {
        #expect(SwitcherPanelController.width(forHostWidth: 1400) == SwitcherLayout.width)
        // A window barely wider than the panel keeps a margin on each side.
        #expect(
            SwitcherPanelController.width(forHostWidth: 600)
                == 600 - 2 * SwitcherLayout.sideMargin)
        // …and a window narrower than the floor gets the floor rather than a
        // negative width.
        #expect(SwitcherPanelController.width(forHostWidth: 200) == SwitcherLayout.minimumWidth)
    }
}

/// A view that will take first responder — the smallest thing that can stand in for
/// "whatever had the keyboard before the panel opened".
private final class FirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
