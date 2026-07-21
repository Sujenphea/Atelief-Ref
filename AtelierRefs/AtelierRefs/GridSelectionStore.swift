//
//  GridSelectionStore.swift
//  AtelierRefs
//
//  036 §2 A0 — the Library grid's multi-selection, extracted OFF the
//  `IngestionModel` god-object into its own observable so a selection publish
//  invalidates only the views that observe THIS store, not every view that
//  observes `IngestionModel` (the god-object fan-out: a click / ⇧-click / arrow /
//  marquee tick re-ran every `IngestionModel` subscriber).
//
//  HONEST scope (036 §5 step 5): this does NOT by itself stop the whole
//  `CollectionView` from re-rendering on a selection change — that view still
//  reads `selection` at ~nine sites in its own body, so it re-runs until those
//  reads move down into per-cell views (later A1–A2 work). What A0 removes is the
//  cross-view fan-out. `CollectionView` keeps parity by observing this store
//  directly (its former repaint path — `IngestionModel.objectWillChange` — no
//  longer fires on selection).
//
//  The selection LOGIC is unchanged: the pure `GridSelection` reducer stays the
//  only truth. This store is a thin owner — it holds the value + the feed `order`
//  the reducer needs, and forwards mutations through the SAME reducer seams
//  `IngestionModel` used before (`applying`, `pruned`, direct `lead` set, and the
//  Jump replace), publishing only real changes exactly as the old `didSet` did.
//

import Combine
import Foundation

/// The Library grid's selection state (036 A0), owned separately from
/// `IngestionModel`. Mutated ONLY through these seams so the mode-dependent click
/// contract stays the pure `GridSelection` reducer (009 · N2), now with a
/// narrower publish blast radius.
@MainActor
final class GridSelectionStore: ObservableObject {

    /// The grid's multi-selection: selected membership ids + the ⇧-range anchor +
    /// the `lead` (detail-overlay / keyboard cursor). Publishes on every real
    /// change (the reducer/prune/replace paths guard equality where the old
    /// `IngestionModel.selection` did).
    @Published private(set) var selection = GridSelection()

    /// The feed order (membership ids in display order) the reducer reads for
    /// range (⇧) and arrow-key math. Pushed by the model whenever `items` changes
    /// (`rebuildItemDerivations`), so a per-tick `items.map` allocation is avoided
    /// on the marquee hot path — mirrors the old hoisted `itemOrder`.
    private(set) var order: [UUID] = []

    /// Update the feed order used by ⇧/arrow reductions. Cheap; no publish (the
    /// selection value is untouched).
    func setOrder(_ order: [UUID]) {
        self.order = order
    }

    /// Apply a selection `action` through the pure ``GridSelection`` reducer over
    /// the current `order` (+ `columns` for arrow keys) and return the view
    /// ``GridSelectionEffect``. Publishes only a real change — the marquee re-fires
    /// on every mouse-move tick, and an unchanged hit set must not re-render its
    /// observers (identical to the old `applySelection` guard).
    @discardableResult
    func apply(_ action: GridSelectionAction, columns: Int = 1) -> GridSelectionEffect {
        let (next, effect) = selection.applying(action, order: order, columns: columns)
        if next != selection { selection = next }
        return effect
    }

    /// Set the `lead` cursor directly (detail-open / prev-next stepping). Matches
    /// the old `selection.lead = …` assignment: it publishes unconditionally so the
    /// publish cadence the overlay relies on is preserved.
    func setLead(_ id: UUID?) {
        var next = selection
        next.lead = id
        selection = next
    }

    /// Replace the whole selection (the 011-B4 Jump path lands a freshly computed
    /// selection against just-loaded items). Publishes unconditionally, matching
    /// the old `selection = jumped` assignment (the caller already guards empties).
    func replace(_ selection: GridSelection) {
        self.selection = selection
    }

    /// Prune the selection to the ids still present after a contents reload
    /// (folder switch / move-away / delete). A removed `anchor`/`lead` falls back
    /// to `nil`, dismissing the detail overlay — the existing auto-dismiss.
    /// Publishes unconditionally, exactly as the old
    /// `selection = selection.pruned(to:)` did.
    func prune(to order: [UUID]) {
        selection = selection.pruned(to: order)
    }
}
