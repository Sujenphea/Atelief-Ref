//
//  DestinationPicker.swift
//  AtelierRefs
//
//  024 · K3 — **the keyboard's way into the destination list.** `M` opens it on
//  "Move to…", `A` on "Add to…", on the collection grid and (for `A` only) on a Space
//  board.
//
//  It is NOT a third picker. The rows, their order, the indentation by depth, the
//  pinned Unsorted, the greying of the collection you are already in, the 240pt cap
//  and the empty state all come from ``CollectionDestinationList``, which the
//  selection bar's Move to / Add to accordion and the item detail page's add chip
//  already render — [027] G2's "one destination list, one ordering, everywhere".
//  What this file adds is the two things a POINTER never needed:
//
//   • a cursor, so the list is walkable with ↑ / ↓ and committed with Return;
//   • a promise to hand first responder BACK when it closes, which is what keeps the
//     grid's own arrows alive afterwards (`DetailKeyCatcher.restoreResponder` and
//     `SpaceView.restoreCanvasFocus` are the same discipline).
//
//  [011] C-1's ⌘K type-ahead machinery is deliberately NOT built here. The list is
//  height-capped and the cursor scrolls with it, which is the cheap 90%; a filter
//  field is a feature with its own empty states and its own doc.
//

import AtelierCore
import SwiftUI

/// A raised destination picker: which verb, and the assets it will act on.
///
/// The asset ids are captured WHEN THE KEY IS PRESSED, not read again when a row is
/// clicked. A picker is up for as long as the user takes to read the tree, and a
/// background reload (a capture landing, an undo) can move the selection under it —
/// filing whatever happens to be selected a second later is not what was asked for.
struct DestinationRequest: Identifiable {
    let id = UUID()
    let verb: CollectionDestinationMenu.Verb
    /// The assets to file, resolved once at the press.
    let assetIDs: [UUID]
}

/// The popover body: a verb heading over the shared destination list, with a keyboard
/// cursor on it.
struct DestinationPicker: View {
    let verb: CollectionDestinationMenu.Verb
    /// How many assets the verb will act on — the heading says so, because `M` can
    /// fire on a keyboard cursor with nothing visibly selected and the count is the
    /// only thing on screen that says what it caught.
    let count: Int
    let folders: [Collection]
    let unsortedID: UUID
    /// Listed but greyed — and skipped by the cursor. The collection in view on a
    /// grid; EMPTY on a board, which is not a collection and so excludes nothing.
    var disabled: Set<UUID> = []
    /// The host's destination-tree memo — see ``CollectionDestinationList/cache``.
    /// It matters more here than anywhere: `highlighted` is `@State` on this view,
    /// so every arrow key re-runs the body, and the body rebuilt the tree once for
    /// `navigableIDs` and twice more inside the list.
    var cache: MoveTargetsCache?
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void

    /// The row Return would file into. Seeded to the first navigable row on open, so
    /// the picker is usable without touching the arrow keys at all.
    @State private var highlighted: UUID?
    @FocusState private var isFocused: Bool

    private var navigableIDs: [UUID] {
        guard let cache else {
            return CollectionDestinationList.navigableIDs(
                folders: folders, unsortedID: unsortedID, disabled: disabled)
        }
        return CollectionDestinationList
            .rows(tree: cache.destinationTree(folders: folders, unsortedID: unsortedID))
            .map(\.id)
            .filter { !disabled.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            heading
            CollectionDestinationList(
                folders: folders, unsortedID: unsortedID,
                disabled: disabled, highlighted: highlighted,
                cache: cache,
                onSelect: commit)
        }
        .selectionMenuChrome()
        // The popover's content is what holds SwiftUI focus, so `.onKeyPress` below
        // only fires while this list has the keyboard — the structural guard Home's
        // gallery relies on ([345]), rather than a `keyboardShortcut` that would be
        // matched before any first responder was consulted.
        .focusable()
        .focused($isFocused)
        .onAppear {
            highlighted = navigableIDs.first
            // Hopped off the update that installs the popover: its window is not key
            // yet inside `onAppear`, and focus taken before then does not stick. The
            // same hop `SpaceView.restoreCanvasFocus` and `DetailKeyCatcher.armIfNeeded`
            // take, for the same reason.
            Task { @MainActor in isFocused = true }
        }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            commit(highlighted)
            return .handled
        }
        // Escape is handled rather than left to the popover's own dismissal so the
        // caller's `onDismiss` runs on this path too — that is where the keyboard goes
        // back to the grid.
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var heading: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(verb.title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkPrimary)
            Spacer(minLength: Theme.Spacing.sm)
            Text("\(count)")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .accessibilityLabel("\(count) items")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
    }

    /// Walk the cursor, clamped at both ends. `.handled` even at a stop, so an ↑ on
    /// the first row is absorbed here rather than scrolling the grid behind.
    private func move(_ delta: Int) -> KeyPress.Result {
        highlighted = CollectionDestinationList.step(
            from: highlighted, in: navigableIDs, by: delta)
        return .handled
    }

    /// File, then close. One call site for the click and for Return, so the two can
    /// never disagree about whether the picker stays up.
    private func commit(_ id: UUID) {
        onSelect(id)
        onDismiss()
    }
}
