//
//  CanvasSelection.swift
//  CanvasRenderer
//
//  049 · D6 — the pure, AppKit-free multi-selection reducer behind the Spaces
//  board's multi-select. It is the canvas peer of the Library grid's
//  `GridSelection`, but deliberately LEANER: a free-form, zoomable, z-ordered
//  board has NO linear feed order and NO column geometry, so there is no
//  ⇧-range, no arrow navigation, and no `lead`/detail cursor. Selection is
//  simply a set of tile ids; **⇧ is ADDITIVE** (there is no order to range over).
//
//  Every gesture is a `CanvasSelectionAction` fed through `applying(_:)`, which
//  returns the next value — so the whole mode-dependent click contract is
//  testable without a window (the `GridSelection` pattern). Identity: the ids are
//  `Tile.id` (the index into the provider's rows), matching the engine's
//  `selectedTileIDs`; the app maps them to space-item UUIDs at the persistence
//  boundary.
//

/// The Spaces board's selection state (049 · D6). Selection MODE is derived, not
/// stored — "selecting" is simply `!ids.isEmpty`, so there is no separate flag to
/// drift out of sync (mirrors `GridSelection`).
public struct CanvasSelection: Equatable, Sendable {
    /// The selected tile ids (order-independent; `Tile.id` = index into the
    /// provider's rows).
    public private(set) var ids: Set<Int>

    public init(ids: Set<Int> = []) { self.ids = ids }

    /// Nothing selected.
    public var isEmpty: Bool { ids.isEmpty }
    /// At least one tile selected (selecting mode).
    public var isSelecting: Bool { !ids.isEmpty }
}

/// A user gesture resolved against the board (049 · D6). No feed order or columns
/// appear here — a board has neither, which is exactly why there is no ⇧-range.
public enum CanvasSelectionAction: Equatable, Sendable {
    /// Replace the selection with exactly this tile — a plain click, or the
    /// Finder-scope "grab an unselected tile" rule.
    case selectOnly(Int)
    /// Toggle this tile's membership (⌘-click).
    case toggle(Int)
    /// Add this tile without removing others (⇧-click — additive on a board).
    case add(Int)
    /// A live marquee (rubber-band) update: the ids the box currently touches,
    /// unioned with `base` — the selection captured when the drag began (empty for
    /// a plain marquee, the prior selection for a ⇧-additive one). Mirrors the
    /// `GridSelection` `.marquee(hits:base:)` union shape.
    case marquee(hits: Set<Int>, base: Set<Int>)
    /// Clear the selection (Esc / click empty background).
    case clear
}

public extension CanvasSelection {
    /// Apply `action`, returning the next selection. Pure: no UI, no I/O — the
    /// whole click contract is exercised here.
    func applying(_ action: CanvasSelectionAction) -> CanvasSelection {
        var next = self
        switch action {
        case let .selectOnly(id):
            next.ids = [id]
        case let .toggle(id):
            if next.ids.contains(id) { next.ids.remove(id) } else { next.ids.insert(id) }
        case let .add(id):
            next.ids.insert(id)
        case let .marquee(hits, base):
            next.ids = base.union(hits)
        case .clear:
            next.ids = []
        }
        return next
    }

    /// Prune to the ids still present after a content reload (049 · D7). Selected
    /// ids intersect the tiles that survive; the canvas peer of
    /// `GridSelection.pruned(to:)`.
    func pruned(to present: Set<Int>) -> CanvasSelection {
        CanvasSelection(ids: ids.intersection(present))
    }
}

/// Map a raw tile click (which id, which modifiers held) to its selection action
/// (049 · D6). Pure so the modifier routing is unit-testable independent of the
/// AppKit `NSEvent.modifierFlags` read that supplies the booleans. ⇧ wins over ⌘
/// when both are held (⇧ signals additive intent, the stronger signal — parity
/// with `gridClickAction`).
public func canvasClickAction(tileID id: Int, shift: Bool, command: Bool) -> CanvasSelectionAction {
    if shift { return .add(id) }
    if command { return .toggle(id) }
    return .selectOnly(id)
}

/// What a mouse-DOWN on a tile does vs. what it defers to the mouse-UP click
/// (049 · D6). The board selects on the DOWN edge so the highlight is immediate,
/// EXCEPT the one Finder case that must defer: a plain press on an ALREADY-selected
/// tile. That press might become a drag, and a drag of a selected tile must carry
/// the WHOLE selection — so it must NOT collapse to that one tile on the way down.
/// It collapses only if the press stays a click (on up). Mirrors the grid's
/// `gridPressRouting`, minus the detail-open concept a board doesn't have.
public struct CanvasPressRouting: Equatable, Sendable {
    /// Applied immediately on mouse-DOWN (`nil` = leave the selection untouched on
    /// the way down).
    public var pressAction: CanvasSelectionAction?
    /// Applied on mouse-UP ONLY if the press did not become a drag (a plain click).
    public var clickAction: CanvasSelectionAction?

    public init(pressAction: CanvasSelectionAction?, clickAction: CanvasSelectionAction?) {
        self.pressAction = pressAction
        self.clickAction = clickAction
    }
}

/// The tiles a drag STARTING on `grabbed` should carry (049 · D3, the canvas
/// Finder-scope rule): the WHOLE selection when the grabbed tile is part of it,
/// else just the grabbed tile itself.
///
/// Deliberately canvas-local and NOT shared with the Library grid's
/// `gridActionTargets` (049 · D5, confirmed): the two payloads differ in identity
/// (`Int` tile index vs `UUID`) AND ordering (a board is unordered; the grid's is
/// feed-ordered, which its block-insert reorder depends on). A common generic would
/// de-duplicate this single predicate at the cost of a cross-module dependency and
/// an ordering shim — the wrong trade. The engine treats the grabbed tile as the
/// drag's primary and de-duplicates it, so it may appear in the returned set.
public func canvasDragCarry(grabbed: Int, selection: Set<Int>) -> Set<Int> {
    selection.contains(grabbed) ? selection : [grabbed]
}

/// Route a mouse-DOWN on the tile `id` to its press/click selection actions
/// (049 · D6, the Finder rule):
///  - **⇧** adds on down; **⌘** toggles on down (modifiers act immediately, never
///    defer — parity with `gridPressRouting`).
///  - A plain press on an **unselected** tile selects it on down (immediate
///    highlight; a following drag carries just it).
///  - A plain press on a **selected** tile DEFERS: nothing on down (so a drag keeps
///    and carries the whole selection); on up — if it stayed a click — it collapses
///    to that one tile.
public func canvasPressRouting(
    tileID id: Int, isSelected: Bool, shift: Bool, command: Bool
) -> CanvasPressRouting {
    if shift { return CanvasPressRouting(pressAction: .add(id), clickAction: nil) }
    if command { return CanvasPressRouting(pressAction: .toggle(id), clickAction: nil) }
    if isSelected { return CanvasPressRouting(pressAction: nil, clickAction: .selectOnly(id)) }
    return CanvasPressRouting(pressAction: .selectOnly(id), clickAction: nil)
}
