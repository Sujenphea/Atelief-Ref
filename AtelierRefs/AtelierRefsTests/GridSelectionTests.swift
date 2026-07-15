//
//  GridSelectionTests.swift
//  AtelierRefsTests
//
//  009 · N2 — exhaustive matrix over the pure selection reducer. Asserts BOTH the
//  next selection AND the emitted effect for every (click kind × modifier) ×
//  (idle / selecting × target selected / unselected) state, the ⇧-range across a
//  moving anchor, ⌘A / Esc, the deselect-last mode exit, ⇧-arrow at grid edges,
//  and reload pruning. The mode-dependent "does this open detail?" contract is
//  the whole point, so it is nailed down here — the views only execute effects.
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Grid selection reducer")
struct GridSelectionTests {

    // Stable, readable ids: index i → UUID(...00i). Order is [a,b,c,d,e,f].
    private static let order: [UUID] = (0..<6).map {
        UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")!
    }
    private var order: [UUID] { Self.order }
    private func id(_ i: Int) -> UUID { Self.order[i] }

    private func sel(_ ids: [Int], anchor: Int? = nil, lead: Int? = nil) -> GridSelection {
        GridSelection(
            ids: Set(ids.map(id)),
            anchor: anchor.map(id),
            lead: lead.map(id))
    }

    // MARK: - Idle image-click opens detail; never selects

    @Test("idle: image-click opens detail, sets lead+anchor, selects nothing")
    func idleImageClickOpens() {
        let (next, effect) = GridSelection().applying(.tapImage(id(2)), order: order)
        #expect(effect == .openDetail(id(2)))
        #expect(next.ids.isEmpty)
        #expect(next.lead == id(2))
        #expect(next.anchor == id(2))
        #expect(next.isSelecting == false)
    }

    // MARK: - Circle-click always toggles, never opens (enters mode)

    @Test("idle: circle-click selects (enters mode), no open")
    func idleCircleSelects() {
        let (next, effect) = GridSelection().applying(.tapCircle(id(1)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(1)])
        #expect(next.isSelecting)
        #expect(next.anchor == id(1))
        #expect(next.lead == id(1))
    }

    @Test("selecting: circle-click on an unselected cell adds it")
    func selectingCircleAdds() {
        let (next, effect) = sel([1]).applying(.tapCircle(id(3)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(1), id(3)])
    }

    @Test("selecting: circle-click on a selected cell removes it")
    func selectingCircleRemoves() {
        let (next, effect) = sel([1, 3]).applying(.tapCircle(id(3)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(1)])
    }

    // MARK: - Selecting image-click toggles, NEVER opens

    @Test("selecting: image-click toggles an unselected cell on, no open")
    func selectingImageAddsNoOpen() {
        let (next, effect) = sel([0]).applying(.tapImage(id(2)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(0), id(2)])
    }

    @Test("selecting: image-click toggles a selected cell off, no open")
    func selectingImageRemovesNoOpen() {
        let (next, effect) = sel([0, 2]).applying(.tapImage(id(2)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(0)])
    }

    @Test("deselecting the LAST item exits selecting mode (next image-click would open)")
    func deselectLastExitsMode() {
        let (next, effect) = sel([2]).applying(.tapImage(id(2)), order: order)
        #expect(effect == .none)
        #expect(next.isEmpty)
        // From the resulting idle state, an image-click opens again.
        let (after, afterEffect) = next.applying(.tapImage(id(4)), order: order)
        #expect(afterEffect == .openDetail(id(4)))
        #expect(after.isEmpty)
    }

    // MARK: - ⌘-click is a circle alias; ⇧/⌘ never open in any state

    @Test("command-click toggles like the circle, idle or selecting, never opens")
    func commandClickToggles() {
        let (a, ae) = GridSelection().applying(.commandClick(id(1)), order: order)
        #expect(ae == .none)
        #expect(a.ids == [id(1)])
        let (b, be) = sel([1, 2]).applying(.commandClick(id(1)), order: order)
        #expect(be == .none)
        #expect(b.ids == [id(2)])
    }

    @Test("shift-click never opens detail, idle or selecting")
    func shiftNeverOpens() {
        #expect(GridSelection().applying(.shiftClick(id(2)), order: order).effect == .none)
        #expect(sel([0]).applying(.shiftClick(id(3)), order: order).effect == .none)
    }

    // MARK: - ⇧-range across the anchor in feed order

    @Test("shift-click with no anchor selects a lone item and pins the anchor")
    func shiftNoAnchor() {
        let (next, _) = GridSelection().applying(.shiftClick(id(3)), order: order)
        #expect(next.ids == [id(3)])
        #expect(next.anchor == id(3))
        #expect(next.lead == id(3))
    }

    @Test("shift-click ranges forward from the anchor, inclusive")
    func shiftRangeForward() {
        let start = sel([1], anchor: 1, lead: 1)
        let (next, _) = start.applying(.shiftClick(id(4)), order: order)
        #expect(next.ids == [id(1), id(2), id(3), id(4)])
        #expect(next.anchor == id(1))
        #expect(next.lead == id(4))
    }

    @Test("shift-click ranges backward from the anchor, inclusive")
    func shiftRangeBackward() {
        let start = sel([4], anchor: 4, lead: 4)
        let (next, _) = start.applying(.shiftClick(id(1)), order: order)
        #expect(next.ids == [id(1), id(2), id(3), id(4)])
        #expect(next.anchor == id(4))
    }

    @Test("a second shift-click re-ranges from the SAME anchor (replaces, not grows)")
    func shiftReRangeFromAnchor() {
        let start = sel([1], anchor: 1, lead: 1)
        let (mid, _) = start.applying(.shiftClick(id(4)), order: order)
        let (next, _) = mid.applying(.shiftClick(id(2)), order: order)
        #expect(next.ids == [id(1), id(2)])   // shrank back toward the anchor
        #expect(next.anchor == id(1))
    }

    // MARK: - selectOnly (drag on an unselected cell)

    @Test("selectOnly replaces any existing selection with the one id")
    func selectOnlyReplaces() {
        let (next, effect) = sel([0, 1, 2], anchor: 0, lead: 2).applying(
            .selectOnly(id(4)), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(4)])
        #expect(next.anchor == id(4))
        #expect(next.lead == id(4))
    }

    // MARK: - ⌘A / Esc

    @Test("select-all selects every item; anchor=first, lead=last")
    func selectAll() {
        let (next, effect) = GridSelection().applying(.selectAll, order: order)
        #expect(effect == .none)
        #expect(next.ids == Set(order))
        #expect(next.anchor == id(0))
        #expect(next.lead == id(5))
    }

    @Test("select-all on an empty grid is a no-op")
    func selectAllEmpty() {
        let (next, effect) = GridSelection().applying(.selectAll, order: [])
        #expect(effect == .none)
        #expect(next.isEmpty)
    }

    @Test("clear empties the whole selection and cursor")
    func clear() {
        let (next, effect) = sel([1, 2, 3], anchor: 1, lead: 3).applying(.clear, order: order)
        #expect(effect == .none)
        #expect(next == GridSelection())
    }

    // MARK: - Arrows: plain moves the cursor; ⇧ extends the range

    @Test("plain arrow moves the cursor only, selecting nothing, and scrolls")
    func plainArrowMovesCursor() {
        let (next, effect) = sel([], lead: 1).applying(
            .arrow(.right, extend: false), order: order, columns: 3)
        #expect(effect == .scrollTo(id(2)))
        #expect(next.lead == id(2))
        #expect(next.ids.isEmpty)
    }

    @Test("plain arrow with no cursor lands on the first item")
    func plainArrowNoCursor() {
        let (next, effect) = GridSelection().applying(
            .arrow(.down, extend: false), order: order, columns: 3)
        #expect(effect == .scrollTo(id(0)))
        #expect(next.lead == id(0))
    }

    @Test("shift-arrow extends the range from the cursor and scrolls")
    func shiftArrowExtends() {
        let (next, effect) = sel([2], anchor: 2, lead: 2).applying(
            .arrow(.right, extend: true), order: order, columns: 3)
        #expect(effect == .scrollTo(id(3)))
        #expect(next.ids == [id(2), id(3)])
        #expect(next.anchor == id(2))
        #expect(next.lead == id(3))
    }

    @Test("shift-arrow down extends a whole row via the column count")
    func shiftArrowRow() {
        let (next, _) = sel([0], anchor: 0, lead: 0).applying(
            .arrow(.down, extend: true), order: order, columns: 3)
        // Row step of 3: 0→3, range [0,1,2,3].
        #expect(next.ids == [id(0), id(1), id(2), id(3)])
    }

    @Test("shift-arrow at the last item stays put (clamped), no phantom growth")
    func shiftArrowClampsAtEnd() {
        let (next, effect) = sel([5], anchor: 5, lead: 5).applying(
            .arrow(.right, extend: true), order: order, columns: 3)
        #expect(effect == .scrollTo(id(5)))
        #expect(next.ids == [id(5)])
    }

    @Test("shift-arrow up at the top row stays put")
    func shiftArrowClampsAtTop() {
        let (next, _) = sel([1], anchor: 1, lead: 1).applying(
            .arrow(.up, extend: true), order: order, columns: 3)
        #expect(next.lead == id(1))
    }

    @Test("arrow on an empty grid is a no-op")
    func arrowEmptyGrid() {
        let (next, effect) = GridSelection().applying(
            .arrow(.right, extend: false), order: [], columns: 3)
        #expect(effect == .none)
        #expect(next == GridSelection())
    }

    // MARK: - Marquee (rubber-band)

    @Test("plain marquee replaces the selection with the box's hits")
    func marateePlainReplaces() {
        let start = sel([5], lead: 5)
        let (next, effect) = start.applying(
            .marquee(hits: [id(1), id(2)], base: []), order: order)
        #expect(effect == .none)
        #expect(next.ids == [id(1), id(2)])
    }

    @Test("⇧-additive marquee unions the box's hits with the captured base")
    func marqueeAdditiveUnions() {
        let base: Set<UUID> = [id(0)]
        let start = sel([0])
        let (next, _) = start.applying(
            .marquee(hits: [id(2), id(3)], base: base), order: order)
        #expect(next.ids == [id(0), id(2), id(3)])
    }

    @Test("shrinking the box drops items not in the base")
    func marqueeShrinks() {
        // First a wide box, then a narrower one — plain (empty base).
        let (wide, _) = GridSelection().applying(
            .marquee(hits: [id(0), id(1), id(2)], base: []), order: order)
        let (narrow, _) = wide.applying(
            .marquee(hits: [id(0)], base: []), order: order)
        #expect(narrow.ids == [id(0)])
    }

    // MARK: - Enter opens the lead

    @Test("openLead opens the cursor item's detail")
    func openLead() {
        let (next, effect) = sel([1, 2], lead: 2).applying(.openLead, order: order)
        #expect(effect == .openDetail(id(2)))
        #expect(next.ids == [id(1), id(2)])   // selection untouched
    }

    @Test("openLead with no cursor does nothing")
    func openLeadNoCursor() {
        let (_, effect) = GridSelection().applying(.openLead, order: order)
        #expect(effect == .none)
    }

    // MARK: - Reload pruning

    @Test("prune drops selected ids no longer present")
    func pruneDropsMissingIDs() {
        let start = sel([0, 2, 4], anchor: 2, lead: 4)
        let pruned = start.pruned(to: [id(0), id(2)])   // 4 is gone
        #expect(pruned.ids == [id(0), id(2)])
    }

    @Test("prune clears a removed anchor and lead to nil (overlay auto-dismiss)")
    func pruneClearsRemovedAnchorLead() {
        let start = sel([0, 2, 4], anchor: 4, lead: 4)
        let pruned = start.pruned(to: [id(0), id(2)])
        #expect(pruned.anchor == nil)
        #expect(pruned.lead == nil)
    }

    @Test("prune keeps a still-present anchor and lead")
    func pruneKeepsPresentAnchorLead() {
        let start = sel([0, 2], anchor: 2, lead: 0)
        let pruned = start.pruned(to: [id(0), id(2), id(3)])
        #expect(pruned.anchor == id(2))
        #expect(pruned.lead == id(0))
    }

    @Test("prune to an empty order clears everything")
    func pruneToEmpty() {
        let pruned = sel([0, 1, 2], anchor: 0, lead: 2).pruned(to: [])
        #expect(pruned == GridSelection())
    }

    // MARK: - Click-action routing (modifier → action)

    @Test("modifier routing: shift wins over command; command over plain")
    func clickActionRouting() {
        let x = id(2)
        #expect(gridClickAction(imageID: x, shift: false, command: false) == .tapImage(x))
        #expect(gridClickAction(imageID: x, shift: false, command: true) == .commandClick(x))
        #expect(gridClickAction(imageID: x, shift: true, command: false) == .shiftClick(x))
        #expect(gridClickAction(imageID: x, shift: true, command: true) == .shiftClick(x))
    }
}
