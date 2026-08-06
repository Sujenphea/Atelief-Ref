//
//  CollectionDestinationMenu.swift
//  AtelierRefs
//
//  027 · G2/G3 — the "file these items into a collection" menu, as NESTED native
//  submenus. One of the TWO renderings of the single destination ordering
//  (``CollectionTargets/destinationTree``); the other is the SwiftUI
//  ``CollectionDestinationList``. Neither may sort or group on its own — the bug
//  this file exists to fix was exactly that: the grid's right-click built from
//  `moveTargets` (the current collection's DIRECT subfolders + every root), so
//  `Refs/Type/Serif` was unreachable by right-click at any depth, forever.
//
//  Shape:
//
//      Move to ▸  Unsorted
//                 ─────────
//                 Refs ▸  Move here
//                         ─────────
//                         Type ▸  Move here
//                                 ─────────
//                                 Serif
//                                 Sans
//                 Photography ▸ …
//
//  The pure `[DestinationTreeNode] -> [DestinationMenuItem]` half is unit-tested;
//  the `NSMenu` half is a mechanical transcription of it (a right-click cannot be
//  driven from a unit test, so keeping the decisions OUT of the AppKit walk is
//  what makes them testable at all).
//

import AppKit
import AtelierCore
import Foundation

/// One row of a destination menu — the pure, AppKit-free description the `NSMenu`
/// is transcribed from. `Equatable` so a fixture tree can be asserted whole.
nonisolated enum DestinationMenuItem: Equatable {
    /// A divider (after the pinned Unsorted row; after a parent's "here" row).
    case separator
    /// A clickable row that files into `id`. Disabled for the collection the items
    /// already live in — listed rather than omitted, so the menu reads as the
    /// complete tree.
    case destination(id: UUID, title: String, isEnabled: Bool)
    /// A row that OPENS a submenu. It cannot itself be clicked (AppKit gives a
    /// submenu-bearing item no action), which is the one real cost of nesting —
    /// hence the leading "here" row inside `items`.
    case submenu(id: UUID, title: String, items: [DestinationMenuItem])
}

/// Builds the nested destination menu, pure half and AppKit half.
nonisolated enum CollectionDestinationMenu {
    /// The label of the leading row a parent needs so its own collection stays
    /// reachable ("Move here" / "Add here"). Verb-specific, because a "Move here"
    /// row inside "Add to ▸" would name the wrong action.
    enum Verb: String {
        case move = "Move here"
        case add = "Add here"

        /// The verb as a HEADING over the whole tree — the selection bar's accordion
        /// sections, the right-click submenu titles, and (024 · K3) the `M` / `A`
        /// picker all say this. One vocabulary: a keyboard picker that said
        /// "Move to Collection" while the bar beside it said "Move to" would be two.
        var title: String {
            switch self {
            case .move: "Move to"
            case .add: "Add to"
            }
        }
    }

    // MARK: - Pure

    /// The menu rows for the whole collection hierarchy.
    ///
    /// - `disabled` — listed but greyed (the collection the items already live in).
    ///   A greyed parent still OPENS: its children are legitimate destinations.
    /// - Every row with children gains a leading `verb` row plus a separator, and
    ///   ONLY such rows: adding one to a leaf would double the row count for
    ///   nothing.
    /// - The pinned Unsorted root is followed by a separator when other roots
    ///   exist, matching the gallery's "Unsorted is not one of your folders" read.
    ///
    /// **The depth is deliberately NOT capped.** A 6-level hierarchy makes a
    /// 6-deep submenu chain, which is unpleasant but honest; a silent cap would
    /// make folders unreachable, which is the bug being fixed here. If depth ever
    /// becomes a real complaint the answer is a searchable picker (011 · C-1's ⌘K
    /// machinery), not truncation.
    static func items(
        tree: [DestinationTreeNode], unsortedID: UUID,
        disabled: Set<UUID> = [], verb: Verb
    ) -> [DestinationMenuItem] {
        var rows = tree.map { row($0, disabled: disabled, verb: verb) }
        // The pinned Unsorted root reads as a separate thing from the user's own
        // folders, exactly as it does in the gallery and the indented list.
        if rows.count > 1, tree.first?.collection.id == unsortedID {
            rows.insert(.separator, at: 1)
        }
        return rows
    }

    /// The whole hierarchy from a flat `folders` list — the one-call form for
    /// callers that hold no memoized tree.
    static func items(
        folders: [Collection], unsortedID: UUID, disabled: Set<UUID> = [], verb: Verb
    ) -> [DestinationMenuItem] {
        items(
            tree: CollectionTargets.destinationTree(folders: folders, unsortedID: unsortedID),
            unsortedID: unsortedID, disabled: disabled, verb: verb)
    }

    /// One node → one row, recursively. A leaf is a plain destination; a parent is
    /// a submenu whose FIRST row files into the parent itself.
    private static func row(
        _ node: DestinationTreeNode, disabled: Set<UUID>, verb: Verb
    ) -> DestinationMenuItem {
        let id = node.collection.id
        let isEnabled = !disabled.contains(id)
        guard !node.children.isEmpty else {
            return .destination(id: id, title: node.collection.name, isEnabled: isEnabled)
        }
        let here: [DestinationMenuItem] = [
            .destination(id: id, title: verb.rawValue, isEnabled: isEnabled),
            .separator,
        ]
        return .submenu(
            id: id, title: node.collection.name,
            items: here + node.children.map { row($0, disabled: disabled, verb: verb) })
    }

    /// Every destination id the rows offer, in menu order — a parent's "here" row
    /// first, then its subtree. The contract test asserts this matches the SwiftUI
    /// list's row order, which is how "one ordering, two renderers" is enforced
    /// rather than merely intended.
    static func destinationIDs(_ items: [DestinationMenuItem]) -> [UUID] {
        items.flatMap { item -> [UUID] in
            switch item {
            case .separator: []
            case let .destination(id, _, _): [id]
            case let .submenu(_, _, children): destinationIDs(children)
            }
        }
    }

    // MARK: - AppKit

    /// The rows as a live `NSMenu`, each destination firing `action` with its id.
    @MainActor
    static func menu(
        _ items: [DestinationMenuItem], action: @escaping @MainActor (UUID) -> Void
    ) -> NSMenu {
        let built = NSMenu()
        for item in items {
            switch item {
            case .separator:
                built.addItem(.separator())
            case let .destination(id, title, isEnabled):
                let row = BlockMenuItem(title: title) { action(id) }
                row.isEnabled = isEnabled
                built.addItem(row)
            case let .submenu(_, title, children):
                let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                row.submenu = menu(children, action: action)
                built.addItem(row)
            }
        }
        // Without this AppKit re-enables every item from its own validation pass
        // (a `BlockMenuItem` has a target + action, so it always validates true)
        // and the greyed current-collection row would come back clickable.
        built.autoenablesItems = false
        return built
    }
}
