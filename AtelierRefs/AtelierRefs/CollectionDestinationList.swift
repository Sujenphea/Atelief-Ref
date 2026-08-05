//
//  CollectionDestinationList.swift
//  AtelierRefs
//
//  026 · I1 / 027 · G2 — the "file these items into a collection" list as an
//  INDENTED, height-capped SwiftUI list. One of the TWO renderings of the single
//  destination ordering (``CollectionTargets/destinationTree``); the other is the
//  nested AppKit ``CollectionDestinationMenu``.
//
//  Lifted verbatim out of `CollectionView.destinationList` (the selection bar's
//  Move to / Add to accordion) so the item-detail page's add-to-collection chip
//  can consume the SAME list. That chip used to render `listCollections()`
//  filtered — a flat alphabetical dump across the whole tree, where a nested
//  `Refs/Type/Serif` appeared as a bare `Serif` beside unrelated roots, two
//  `Inspiration` folders under different parents were indistinguishable, Unsorted
//  was an ordinary unpinned row, and nothing capped the height, so a 40-folder
//  library produced a menu taller than the window.
//
//  The two consumers differ only in how a collection the items already relate to
//  is treated: the selection bar DISABLES the collection on screen (greyed, so the
//  list still reads as the complete tree), while the detail page EXCLUDES the
//  collections the asset already belongs to (they are memberships, shown as chips
//  beside the trigger — offering them again would be a no-op row).
//

import AtelierCore
import SwiftUI

struct CollectionDestinationList: View {
    /// Every collection in the library, flat — ordering is this view's job, never
    /// the caller's.
    let folders: [Collection]
    let unsortedID: UUID
    /// Listed but greyed: the collection the items are already in.
    var disabled: Set<UUID> = []
    /// Dropped from the list: memberships the asset already has (the detail page).
    var excluded: Set<UUID> = []
    /// The non-tappable row shown when nothing is left to offer.
    var emptyTitle: String = "No collections"
    let onSelect: (UUID) -> Void

    /// The list's height cap. Past it the list scrolls; short lists shrink to fit.
    static let maxHeight: CGFloat = 240

    @State private var contentHeight: CGFloat = 0

    /// The rows, pure: the whole hierarchy pre-order with a depth per row, minus
    /// the excluded ids. An excluded PARENT keeps its children at their original
    /// depth — the indentation still describes where a folder lives, which is the
    /// whole point of showing a tree rather than a flat list.
    nonisolated static func rows(
        folders: [Collection], unsortedID: UUID, excluded: Set<UUID> = []
    ) -> [MoveTargetNode] {
        CollectionTargets.moveTargetTree(folders: folders, unsortedID: unsortedID)
            .filter { !excluded.contains($0.id) }
    }

    private var nodes: [MoveTargetNode] {
        Self.rows(folders: folders, unsortedID: unsortedID, excluded: excluded)
    }

    var body: some View {
        if nodes.isEmpty {
            SelectionMenuRow(emptyTitle, isEnabled: false)
        } else {
            // A bare `ScrollView` reports no ideal height in a content-sized popover
            // and collapses to zero (no rows show). Measure the content's natural
            // height (it lays out full-size on the unbounded scroll axis regardless
            // of the ScrollView's own frame) and pin the ScrollView to
            // `min(content, maxHeight)` — shrink-to-fit for short lists, scroll past it.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(nodes) { node in
                        SelectionMenuRow(
                            node.collection.name, indent: node.depth,
                            isEnabled: !disabled.contains(node.id)) {
                            onSelect(node.id)
                        }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: MenuListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(contentHeight, Self.maxHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(MenuListHeightKey.self) { contentHeight = $0 }
        }
    }
}
