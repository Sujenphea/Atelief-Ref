//
//  SelectionCellDeltaTests.swift
//  AtelierRefsTests
//
//  036 §4 A2 — the pure logic behind the AppKit grid's LAYER-ONLY selection
//  reconciliation. `selectionCellDelta` decides which cells changed between two
//  selections (symmetric difference of ids ∪ lead moves) and whether the
//  grid-global "selecting" mode flipped; `selectionReconcileTargets` narrows that
//  to the cells the coordinator actually repaints (visible only, or ALL visible on
//  a mode flip). Together they ARE the "touch only the changed cells" guarantee —
//  the multi-select smoothness win — so they are pinned here rather than in a live
//  collection view (which cannot be exercised headlessly).
//
//  Also covers the NSEvent → action glue the coordinator layers on top of the
//  already-tested `gridPressRouting`/`gridClickAction`/`GridNavigation` tables:
//  the modifier read, the delete-key predicate, and the key → `GridKeyCommand` map.
//

import AppKit
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

@Suite("Selection cell delta (036 A2)")
struct SelectionCellDeltaTests {

    // Stable, readable ids: index i → UUID(...00i).
    private static let ids: [UUID] = (0..<8).map {
        UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")!
    }
    private func id(_ i: Int) -> UUID { Self.ids[i] }
    private func sel(_ ids: [Int], lead: Int? = nil) -> GridSelection {
        GridSelection(ids: Set(ids.map(id)), lead: lead.map(id))
    }

    // MARK: symmetric difference

    @Test("added and removed ids are both in the changed set")
    func symmetricDifference() {
        let delta = selectionCellDelta(from: sel([0, 1]), to: sel([1, 2]))
        #expect(delta.changed == [id(0), id(2)])
    }

    @Test("an unchanged selection changes nothing")
    func noChange() {
        let delta = selectionCellDelta(from: sel([0, 1], lead: 1), to: sel([0, 1], lead: 1))
        #expect(delta.changed.isEmpty)
        #expect(delta.modeFlipped == false)
    }

    // MARK: lead moves — the classic omitted case

    @Test("a lead move with identical ids changes exactly the old and new cursor")
    func leadMoveWithIdenticalIDs() {
        let delta = selectionCellDelta(from: sel([0, 1, 2], lead: 0), to: sel([0, 1, 2], lead: 2))
        // Neither cell's membership changed, but the cursor ring moved from 0 to 2.
        #expect(delta.changed == [id(0), id(2)])
        #expect(delta.modeFlipped == false)
    }

    @Test("gaining a lead from nil adds only the new cursor")
    func leadFromNil() {
        let delta = selectionCellDelta(from: sel([0, 1]), to: sel([0, 1], lead: 1))
        #expect(delta.changed == [id(1)])
    }

    @Test("losing a lead to nil removes only the old cursor")
    func leadToNil() {
        let delta = selectionCellDelta(from: sel([0, 1], lead: 0), to: sel([0, 1]))
        #expect(delta.changed == [id(0)])
    }

    @Test("a membership change AND a lead move union both")
    func membershipAndLeadMove() {
        let delta = selectionCellDelta(from: sel([0, 1], lead: 1), to: sel([1, 2], lead: 2))
        // ids diff {0,2}, lead move {1,2} → union {0,1,2}.
        #expect(delta.changed == [id(0), id(1), id(2)])
    }

    // MARK: mode flip — BOTH directions

    @Test("first select (empty → non-empty) flips the mode")
    func modeFlipOnFirstSelect() {
        let delta = selectionCellDelta(from: sel([]), to: sel([2], lead: 2))
        #expect(delta.modeFlipped)
    }

    @Test("last deselect (non-empty → empty) flips the mode")
    func modeFlipOnLastDeselect() {
        let delta = selectionCellDelta(from: sel([2], lead: 2), to: sel([]))
        #expect(delta.modeFlipped)
    }

    @Test("selecting a second item does NOT flip the mode (already selecting)")
    func noModeFlipWhenAlreadySelecting() {
        let delta = selectionCellDelta(from: sel([0], lead: 0), to: sel([0, 1], lead: 1))
        #expect(delta.modeFlipped == false)
    }

    // MARK: reconcile targets — visible-only, mode flip → all visible

    @Test("targets are the changed cells intersected with the visible set")
    func targetsAreVisibleChanged() {
        let delta = selectionCellDelta(from: sel([0, 1]), to: sel([1, 2, 5]))
        // Changed {0,2,5}; only {0,2} are on screen (5 scrolled off).
        let visible: Set<UUID> = [id(0), id(1), id(2), id(3)]
        let targets = selectionReconcileTargets(delta: delta, visibleIDs: visible)
        #expect(targets == [id(0), id(2)])
    }

    @Test("a changed cell that is off screen is NOT touched (repaints on scroll-in)")
    func offscreenChangeExcluded() {
        let delta = selectionCellDelta(from: sel([0]), to: sel([0, 7], lead: 7))
        let visible: Set<UUID> = [id(0), id(1), id(2)]
        let targets = selectionReconcileTargets(delta: delta, visibleIDs: visible)
        // id(7) changed but is off screen → excluded; nothing else visible changed.
        #expect(targets.isEmpty)
    }

    @Test("a mode flip repaints EVERY visible cell, not just the changed one")
    func modeFlipRepaintsAllVisible() {
        let delta = selectionCellDelta(from: sel([]), to: sel([1], lead: 1))
        let visible: Set<UUID> = [id(0), id(1), id(2), id(3)]
        let targets = selectionReconcileTargets(delta: delta, visibleIDs: visible)
        #expect(targets == visible)
    }
}

// MARK: - NSEvent → routing glue

@Suite("Grid mouse + key routing glue (036 A2)")
struct GridInputRoutingTests {

    // MARK: mouse modifiers → the pure routing tables

    @Test("modifier flags read into (shift, command); other modifiers ignored")
    func mouseModifiers() {
        #expect(gridMouseModifiers(from: []) == (false, false))
        #expect(gridMouseModifiers(from: [.shift]) == (true, false))
        #expect(gridMouseModifiers(from: [.command]) == (false, true))
        #expect(gridMouseModifiers(from: [.shift, .command]) == (true, true))
        // Option / control are not part of the cell click contract.
        #expect(gridMouseModifiers(from: [.option]) == (false, false))
        #expect(gridMouseModifiers(from: [.control, .shift]) == (true, false))
    }

    @Test("the read booleans drive gridPressRouting / gridClickAction as on the SwiftUI path")
    func modifiersFeedTheTables() {
        let target = UUID()
        // ⇧-click while idle: down-edge shiftClick, consumes the release.
        let (shift, command) = gridMouseModifiers(from: [.shift])
        let routing = gridPressRouting(
            imageID: target, isSelecting: false, isSelected: false,
            shift: shift, command: command)
        #expect(routing == GridPressRouting(pressAction: .shiftClick(target), consumesRelease: true))
        // A plain click resolves to .tapImage via the same table the SwiftUI cell uses.
        let (s2, c2) = gridMouseModifiers(from: [])
        #expect(gridClickAction(imageID: target, shift: s2, command: c2) == .tapImage(target))
    }

    // MARK: delete key predicate

    @Test("backspace and forward-delete are delete keys; letters are not")
    func deleteKey() {
        #expect(gridIsDeleteKey(characters: "\u{7f}"))                       // Backspace (DEL)
        #expect(gridIsDeleteKey(characters: String(UnicodeScalar(NSDeleteFunctionKey)!)))
        #expect(gridIsDeleteKey(characters: "x") == false)
        #expect(gridIsDeleteKey(characters: "") == false)
    }

    // MARK: key → GridKeyCommand map

    @Test("arrows map to cursor moves; ⇧ extends")
    func arrows() {
        func k(_ scalar: Int, _ mods: NSEvent.ModifierFlags = []) -> GridKeyCommand? {
            gridKeyCommand(characters: String(UnicodeScalar(scalar)!), modifiers: mods)
        }
        #expect(k(NSUpArrowFunctionKey) == .arrow(.up, extend: false))
        #expect(k(NSDownArrowFunctionKey) == .arrow(.down, extend: false))
        #expect(k(NSLeftArrowFunctionKey) == .arrow(.left, extend: false))
        #expect(k(NSRightArrowFunctionKey) == .arrow(.right, extend: false))
        #expect(k(NSUpArrowFunctionKey, [.shift]) == .arrow(.up, extend: true))
        // ⌘-arrows are not the grid's binding — left for performKeyEquivalent / super.
        #expect(k(NSLeftArrowFunctionKey, [.command]) == nil)
    }

    @Test("return / escape / space map without a modifier, and not under ⌘")
    func returnEscapeSpace() {
        #expect(gridKeyCommand(characters: "\r", modifiers: []) == .openLead)
        #expect(gridKeyCommand(characters: "\u{1b}", modifiers: []) == .escape)
        #expect(gridKeyCommand(characters: " ", modifiers: []) == .quickLook)
        #expect(gridKeyCommand(characters: "\r", modifiers: [.command]) == nil)
        #expect(gridKeyCommand(characters: " ", modifiers: [.command]) == nil)
    }

    @Test("x toggles the cursor only with NO modifiers (never eats ⌘X or ⇧X)")
    func toggleLead() {
        #expect(gridKeyCommand(characters: "x", modifiers: []) == .toggleLead)
        #expect(gridKeyCommand(characters: "x", modifiers: [.command]) == nil)
        #expect(gridKeyCommand(characters: "x", modifiers: [.shift]) == nil)
        #expect(gridKeyCommand(characters: "x", modifiers: [.control]) == nil)
    }

    @Test("⌘A selects all; the letter alone does nothing")
    func selectAll() {
        #expect(gridKeyCommand(characters: "a", modifiers: [.command]) == .selectAll)
        #expect(gridKeyCommand(characters: "a", modifiers: []) == nil)
    }

    @Test("⌘+ / ⌘= zoom in; ⌘− zooms out; without ⌘ they do nothing")
    func densityKeys() {
        #expect(gridKeyCommand(characters: "=", modifiers: [.command]) == .zoomIn)
        #expect(gridKeyCommand(characters: "+", modifiers: [.command]) == .zoomIn)
        #expect(gridKeyCommand(characters: "-", modifiers: [.command]) == .zoomOut)
        #expect(gridKeyCommand(characters: "=", modifiers: []) == nil)
        #expect(gridKeyCommand(characters: "-", modifiers: []) == nil)
    }
}
