import Testing
@testable import CanvasRenderer

/// The pure Spaces-board selection reducer (049 · D6). Exhaustive because it is
/// the feature's brain and costs nothing to test (a value type, no window, no
/// async) — the `GridSelectionTests` bar applied to the leaner board reducer.
@Suite("Canvas selection reducer")
struct CanvasSelectionTests {

    // MARK: - applying(_:)

    @Test("selectOnly replaces the whole selection with one tile")
    func selectOnlyReplaces() {
        let s = CanvasSelection(ids: [1, 2, 3])
        #expect(s.applying(.selectOnly(9)).ids == [9])
    }

    @Test("selectOnly on an empty selection selects the one tile")
    func selectOnlyFromEmpty() {
        #expect(CanvasSelection().applying(.selectOnly(4)).ids == [4])
    }

    @Test("toggle adds an absent tile and removes a present one")
    func toggleSymmetric() {
        let s = CanvasSelection(ids: [1, 2])
        #expect(s.applying(.toggle(3)).ids == [1, 2, 3])   // absent → added
        #expect(s.applying(.toggle(2)).ids == [1])          // present → removed
    }

    @Test("toggling the last selected tile collapses to empty (mode exits)")
    func toggleToEmpty() {
        let s = CanvasSelection(ids: [7])
        let next = s.applying(.toggle(7))
        #expect(next.ids.isEmpty)
        #expect(next.isSelecting == false)
    }

    @Test("add is additive — it never removes existing picks")
    func addIsAdditive() {
        let s = CanvasSelection(ids: [1, 2])
        #expect(s.applying(.add(3)).ids == [1, 2, 3])
        // Adding an already-present id is a no-op (a board ⇧ never toggles off).
        #expect(s.applying(.add(2)).ids == [1, 2])
    }

    @Test("marquee unions the hit set with the captured base")
    func marqueeUnionWithBase() {
        let s = CanvasSelection(ids: [5, 6]) // current selection is irrelevant; base drives it
        // Plain marquee: empty base → exactly the hits.
        #expect(s.applying(.marquee(hits: [1, 2], base: [])).ids == [1, 2])
        // ⇧-additive marquee: prior selection captured as base is preserved.
        #expect(s.applying(.marquee(hits: [3], base: [5, 6])).ids == [3, 5, 6])
    }

    @Test("an empty marquee box with a base yields exactly the base")
    func emptyMarqueeKeepsBase() {
        let s = CanvasSelection(ids: [9])
        #expect(s.applying(.marquee(hits: [], base: [5, 6])).ids == [5, 6])
        #expect(s.applying(.marquee(hits: [], base: [])).ids.isEmpty)
    }

    @Test("clear empties the selection")
    func clearEmpties() {
        let s = CanvasSelection(ids: [1, 2, 3])
        let next = s.applying(.clear)
        #expect(next.ids.isEmpty)
        #expect(next.isEmpty)
    }

    @Test("applying is pure — the receiver is unchanged")
    func applyingIsPure() {
        let s = CanvasSelection(ids: [1, 2])
        _ = s.applying(.selectOnly(9))
        _ = s.applying(.clear)
        #expect(s.ids == [1, 2]) // untouched
    }

    // MARK: - pruned(to:)

    @Test("pruned drops ids no longer present after a reload")
    func prunedIntersects() {
        let s = CanvasSelection(ids: [1, 2, 3, 4])
        #expect(s.pruned(to: [2, 4, 5]).ids == [2, 4]) // 1,3 gone; 5 not selected
    }

    @Test("pruned to an empty present set clears the selection")
    func prunedToEmpty() {
        #expect(CanvasSelection(ids: [1, 2]).pruned(to: []).ids.isEmpty)
    }

    @Test("pruned with all ids present is a no-op")
    func prunedNoOp() {
        let s = CanvasSelection(ids: [1, 2, 3])
        #expect(s.pruned(to: [1, 2, 3, 4]).ids == [1, 2, 3])
    }

    // MARK: - canvasClickAction (modifier routing)

    @Test("plain click selects only")
    func clickPlain() {
        #expect(canvasClickAction(tileID: 3, shift: false) == .selectOnly(3))
    }

    @Test("⇧-click TOGGLES — one modifier does both halves of multi-select (065b)")
    func clickShiftToggles() {
        // ⇧ used to be purely additive with ⌘ carrying the toggle. Folding them onto ⇧
        // keeps both behaviours and frees ⌘ for drag-out; a board has no order for
        // "additive" to have meant anything more than "toggle" anyway.
        #expect(canvasClickAction(tileID: 3, shift: true) == .toggle(3))
    }

    // MARK: - canvasPressRouting (down-edge vs deferred click)

    @Test("plain press on an UNSELECTED tile selects it on the down edge")
    func pressUnselectedActsOnDown() {
        let r = canvasPressRouting(tileID: 5, isSelected: false, shift: false)
        #expect(r.pressAction == .selectOnly(5))
        #expect(r.clickAction == nil)
    }

    @Test("plain press on a SELECTED tile defers — nothing on down, collapse on click")
    func pressSelectedDefers() {
        let r = canvasPressRouting(tileID: 5, isSelected: true, shift: false)
        // Deferred so a drag keeps and carries the whole selection…
        #expect(r.pressAction == nil)
        // …and a plain click (no drag) collapses to that one tile on up.
        #expect(r.clickAction == .selectOnly(5))
    }

    @Test("⇧ press toggles on the down edge regardless of selected state")
    func pressShiftOnDown() {
        #expect(canvasPressRouting(tileID: 5, isSelected: false, shift: true)
            == CanvasPressRouting(pressAction: .toggle(5), clickAction: nil))
        #expect(canvasPressRouting(tileID: 5, isSelected: true, shift: true)
            == CanvasPressRouting(pressAction: .toggle(5), clickAction: nil))
    }

    @Test("a ⌘ press routes as a PLAIN press — ⌘ no longer touches the selection (065b)")
    func commandPressIsPlain() {
        // The routing takes no `command` any more, so this states the consequence: ⌘ is
        // the drag-out modifier, and a modifier that mutated the selection on the press
        // edge would deselect the very tile the drag is about to carry.
        //
        // What falls out is exactly what a drag-out wants: grab an unselected tile and
        // it becomes the selection; grab a selected one and the whole selection goes.
        #expect(canvasPressRouting(tileID: 5, isSelected: false, shift: false).pressAction
            == .selectOnly(5))
        #expect(canvasPressRouting(tileID: 5, isSelected: true, shift: false).pressAction == nil)
    }

    // MARK: - canvasDragCarry (the Finder-scope carry predicate)

    @Test("carry a selected tile → the whole selection")
    func carrySelectedIsWholeSelection() {
        #expect(canvasDragCarry(grabbed: 2, selection: [1, 2, 3]) == [1, 2, 3])
    }

    @Test("carry an unselected tile → just that tile")
    func carryUnselectedIsOne() {
        #expect(canvasDragCarry(grabbed: 9, selection: [1, 2, 3]) == [9])
    }

    @Test("carry with an empty selection → just the grabbed tile")
    func carryEmptySelection() {
        #expect(canvasDragCarry(grabbed: 4, selection: []) == [4])
    }

    // MARK: - Finder-scope drag carry (press routing → carry, the real flow)

    @Test("a drag on a selected tile keeps the whole selection to carry it")
    func dragSelectedCarriesAll() {
        // Press on a selected tile defers (no down-edge change), so at drag-begin
        // the selection still holds every id — the carry set is the whole thing.
        var sel = CanvasSelection(ids: [1, 2, 3])
        let r = canvasPressRouting(tileID: 2, isSelected: true, shift: false)
        if let a = r.pressAction { sel = sel.applying(a) } // nil → unchanged
        #expect(sel.ids == [1, 2, 3])
        #expect(canvasDragCarry(grabbed: 2, selection: sel.ids) == [1, 2, 3])
    }

    @Test("a drag on an unselected tile selects then carries only it")
    func dragUnselectedCarriesOne() {
        var sel = CanvasSelection(ids: [1, 2, 3])
        let r = canvasPressRouting(tileID: 9, isSelected: false, shift: false)
        if let a = r.pressAction { sel = sel.applying(a) } // selectOnly(9)
        #expect(sel.ids == [9])
        #expect(canvasDragCarry(grabbed: 9, selection: sel.ids) == [9])
    }
}
