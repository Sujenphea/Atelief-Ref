//
//  GridSelection.swift
//  AtelierRefs
//
//  009 · N2 — the pure, SwiftUI-free selection reducer behind the Library grid's
//  multi-select. Selection is a value (`ids` + `anchor` + `lead`); every gesture
//  and key is an ``GridSelectionAction`` fed through ``GridSelection/applying``,
//  which returns the NEXT selection plus a view ``GridSelectionEffect`` (open the
//  detail page, scroll a cell into view, or nothing). Views never branch on mode
//  themselves — they report the raw input and execute the returned effect (the
//  `GridNavigation`/`GridReorder` pattern, exhaustively unit-tested).
//
//  Identity note: the ids here are MEMBERSHIP ids (`CollectionItem.id`), matching
//  `lead`'s role as the detail-overlay cursor and surviving a contents reload;
//  the drop/move/delete boundary maps them to asset ids via the loaded items.
//

import Foundation

/// The Library grid's selection state (009 · N2). Selection MODE is derived, not
/// stored — "selecting" is simply `!ids.isEmpty`, so there is no separate flag to
/// drift out of sync.
struct GridSelection: Equatable {
    /// The selected membership ids (order-independent; feed order lives in the
    /// grid's `items`).
    var ids: Set<UUID> = []
    /// The ⇧-range pivot — where a range selection grows FROM.
    var anchor: UUID?
    /// The detail-overlay / keyboard-cursor item. Distinct from selection: a
    /// plain arrow moves the cursor WITHOUT selecting, and the detail page shows
    /// the lead.
    var lead: UUID?
    /// The ids owned by the LIVE ⇧-range (anchor→lead). The next ⇧ action
    /// re-pivots: it subtracts this set, then unions the new anchor→target range
    /// — so the range shrinks/grows Finder-style while scattered picks made
    /// BEFORE it survive. Any membership edit outside a ⇧ action collapses it
    /// (its ids simply stay selected as ordinary picks).
    var shiftRange: Set<UUID> = []

    /// Nothing selected (idle mode: plain clicks open detail).
    var isEmpty: Bool { ids.isEmpty }
    /// At least one item selected (selecting mode: plain clicks toggle).
    var isSelecting: Bool { !ids.isEmpty }
}

/// What the view must do after a selection transition (009 · N2). The reducer
/// decides; the view executes — so the mode-dependent "does this open detail?"
/// rule is testable without any UI.
enum GridSelectionEffect: Equatable {
    /// Nothing beyond publishing the new selection.
    case none
    /// Open the full-window detail page for this membership id.
    case openDetail(UUID)
    /// Scroll this membership id's cell into view (keyboard nav).
    case scrollTo(UUID)
}

/// A user gesture or key, resolved against the grid's feed order + column count.
enum GridSelectionAction: Equatable {
    /// A plain click on the thumbnail image: opens detail when idle, toggles
    /// while selecting (never opens detail mid-triage).
    case tapImage(UUID)
    /// A click on the hover/selection circle: always toggles, never opens detail
    /// — this is what ENTERS selection mode from idle.
    case tapCircle(UUID)
    /// ⇧-click: range from the anchor in feed order (never opens detail).
    case shiftClick(UUID)
    /// ⌘-click: toggle (the keyboard-savvy alias of the circle).
    case commandClick(UUID)
    /// Replace the selection with exactly this one id (Finder convention when a
    /// drag begins on an unselected cell — 009 · N3).
    case selectOnly(UUID)
    /// ⌘A: select every item.
    case selectAll
    /// A live marquee (rubber-band) update: the ids the box currently touches,
    /// unioned with `base` — the selection captured when the drag began (empty
    /// for a plain marquee, the prior selection for a ⇧-additive one). 009 · N6.
    case marquee(hits: Set<UUID>, base: Set<UUID>)
    /// Esc / deselect-all / click empty background: clear selection, exit mode.
    case clear
    /// An arrow key; `extend` is ⇧ held (extend the range vs move the cursor).
    case arrow(GridArrowKey, extend: Bool)
    /// Return: open the cursor item's detail (006's planned invocation).
    case openLead
    /// Set the detail-overlay / keyboard cursor to this id WITHOUT touching the
    /// selection set — the detail page's lead-sync-on-close (036 §3 B1). Prev/next
    /// stepping is kept off `IngestionModel`, so on close the model's lead is moved
    /// once to wherever the user stepped to. Scrolls the lead into view like an
    /// arrow move (the caller may discard the effect where a scroll isn't wanted).
    case setLead(UUID)
    /// A key (X) that toggles the CURSOR cell's membership in place — the
    /// keyboard peer of the hover-circle. Arrows move the cursor without touching
    /// the set, so this builds a SCATTERED selection from the keyboard alone
    /// (034 P1). A no-op with no cursor yet.
    case toggleLead
}

extension GridSelection {
    /// Apply `action` against the current feed `order` (membership ids in display
    /// order) and `columns` per row, returning the next selection + the view
    /// effect. Pure: no UI, no I/O — the whole mode-dependent click contract is
    /// exercised here.
    func applying(
        _ action: GridSelectionAction, order: [UUID], columns: Int = 1
    ) -> (selection: GridSelection, effect: GridSelectionEffect) {
        var next = self
        switch action {
        case let .tapImage(id):
            // The one mode-dependent gesture: idle opens, selecting toggles.
            if isSelecting {
                next.toggle(id)
                return (next, .none)
            }
            next.lead = id
            next.anchor = id
            return (next, .openDetail(id))

        case let .tapCircle(id), let .commandClick(id):
            next.toggle(id)
            return (next, .none)

        case let .selectOnly(id):
            next.ids = [id]
            next.anchor = id
            next.lead = id
            next.shiftRange = []
            return (next, .none)

        case let .shiftClick(id):
            next.selectRange(to: id, in: order)
            return (next, .none)

        case .selectAll:
            guard !order.isEmpty else { return (self, .none) }
            next.ids = Set(order)
            next.anchor = order.first
            next.lead = order.last
            next.shiftRange = []
            return (next, .none)

        case let .marquee(hits, base):
            next.ids = base.union(hits)
            next.shiftRange = []
            // Give the box a real pivot: a following ⇧-click must range from the
            // marquee's own edges (first/last hit in feed order), not from a
            // stale pre-drag anchor. An empty box leaves the pivot alone.
            if let first = order.first(where: hits.contains) { next.anchor = first }
            if let last = order.last(where: hits.contains) { next.lead = last }
            return (next, .none)

        case .clear:
            return (GridSelection(), .none)

        case let .arrow(key, extend):
            return next.movingCursor(key, extend: extend, order: order, columns: columns)

        case .openLead:
            if let lead = next.lead { return (next, .openDetail(lead)) }
            return (next, .none)

        case let .setLead(id):
            next.lead = id
            return (next, .scrollTo(id))

        case .toggleLead:
            // Toggle the cursor cell in place; `toggle` re-pins anchor/lead to it
            // (already the lead), so the cursor doesn't jump. No cursor → no-op.
            guard let lead = next.lead else { return (self, .none) }
            next.toggle(lead)
            return (next, .none)
        }
    }

    /// Prune to the ids still present after a feed reload (009 · N2). Selected ids
    /// intersect the new order; a removed `anchor`/`lead` falls back to `nil`
    /// (which dismisses the detail overlay, matching the existing auto-dismiss).
    func pruned(to order: [UUID]) -> GridSelection {
        let present = Set(order)
        var next = self
        next.ids = ids.intersection(present)
        next.shiftRange = shiftRange.intersection(present)
        if let anchor, !present.contains(anchor) { next.anchor = nil }
        if let lead, !present.contains(lead) { next.lead = nil }
        return next
    }

    // MARK: - Private transitions

    /// Toggle `id`'s membership and make it the new anchor + cursor. A toggle is
    /// a membership edit outside the ⇧-range, so the live range collapses — its
    /// ids stay selected, they just stop being range-owned.
    private mutating func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        anchor = id
        lead = id
        shiftRange = []
    }

    /// Union the anchor→`id` contiguous range into the selection (Finder-style
    /// additive — scattered picks survive a ⇧-click), after subtracting the
    /// PREVIOUS range so consecutive ⇧ actions re-pivot (shrink/grow) instead of
    /// accreting. With no live anchor, `id` becomes the anchor (a lone range).
    /// Sharp edge, shared with Finder: a pick the previous range swallowed is
    /// released with it when the range shrinks past it.
    private mutating func selectRange(to id: UUID, in order: [UUID]) {
        guard let targetIndex = order.firstIndex(of: id) else { return }
        let anchorIndex = anchor.flatMap { order.firstIndex(of: $0) } ?? targetIndex
        let lo = min(anchorIndex, targetIndex)
        let hi = max(anchorIndex, targetIndex)
        let range = Set(order[lo...hi])
        ids = ids.subtracting(shiftRange).union(range)
        shiftRange = range
        anchor = order[anchorIndex]
        lead = id
    }

    /// Move the cursor one step; `extend` grows the range from the anchor instead.
    private func movingCursor(
        _ key: GridArrowKey, extend: Bool, order: [UUID], columns: Int
    ) -> (GridSelection, GridSelectionEffect) {
        guard !order.isEmpty else { return (self, .none) }
        let currentIndex = lead.flatMap { order.firstIndex(of: $0) }
        guard let target = nextGridIndex(
            from: currentIndex, key: key, count: order.count, columns: columns)
        else { return (self, .none) }
        let targetID = order[target]
        var next = self
        if extend {
            // Establish a pivot at the current cursor before the first extension.
            if next.anchor == nil || order.firstIndex(of: next.anchor!) == nil {
                next.anchor = lead ?? targetID
            }
            next.selectRange(to: targetID, in: order)
        } else {
            next.lead = targetID
        }
        return (next, .scrollTo(targetID))
    }
}

/// Map a raw cell click (which id, which modifiers held) to its selection action
/// (009 · N2). Pure so the modifier routing is unit-testable independent of the
/// AppKit `NSEvent.modifierFlags` read that supplies the booleans. ⇧ wins over ⌘
/// when both are held (⇧ signals a range, the stronger intent).
func gridClickAction(imageID id: UUID, shift: Bool, command: Bool) -> GridSelectionAction {
    if shift { return .shiftClick(id) }
    if command { return .commandClick(id) }
    return .tapImage(id)
}

/// What the mouse-DOWN edge of a cell-image interaction does. `pressAction` is
/// applied immediately on press; `consumesRelease` tells the cell to swallow the
/// matching mouse-up click so the action isn't applied twice.
struct GridPressRouting: Equatable {
    var pressAction: GridSelectionAction?
    var consumesRelease: Bool
}

/// Route the mouse-DOWN on a cell image (Finder's algorithm). Every cell is
/// `.draggable`, and a SwiftUI `Button` fires on mouse-UP — so a press with a
/// few points of trackpad drift activates the drag session and the click never
/// arrives. Anything that can safely fire on the down edge therefore does:
/// ⇧/⌘ clicks, and toggling an UNSELECTED cell on while selecting. Two cases
/// deliberately stay on mouse-up (press → nil): opening detail from idle (a
/// press that becomes a drag must NOT open), and toggling a SELECTED cell off
/// (a press that becomes a drag must keep it selected and drag the selection).
func gridPressRouting(
    imageID id: UUID, isSelecting: Bool, isSelected: Bool, shift: Bool, command: Bool
) -> GridPressRouting {
    if shift { return GridPressRouting(pressAction: .shiftClick(id), consumesRelease: true) }
    if command { return GridPressRouting(pressAction: .commandClick(id), consumesRelease: true) }
    if isSelecting && !isSelected {
        return GridPressRouting(pressAction: .tapImage(id), consumesRelease: true)
    }
    return GridPressRouting(pressAction: nil, consumesRelease: false)
}
