// AtelierBrowse — the collection tree the phone's switcher shows (093 § 2).
//
// The Mac sidebar holds six things and exactly one of them survives onto a phone: the
// collections tree. A navigation container built to hold one destination type is not a
// navigation container, it is a picker — so on the phone the grid is the root, its
// title is the switcher, and tapping the title presents THIS.
//
// The ordering is not re-decided here. It is `CollectionTargets`'
// (`CollectionTargets.swift:19`, `:35`, `:58`): Unsorted pinned first, then siblings by
// persisted `sortIndex` with `(name, id)` as a stable tiebreak, recursively, cycle-safe.
// Restated rather than imported because that file belongs to the macOS app target — see
// the manifest — and the tests below assert the RULES (Unsorted first, sortIndex before
// name, a cycle terminates) rather than a fixture's spelling, so a drift has to be a
// disagreement about the rule rather than about a name.

import AtelierCore
import Foundation

/// One node of the phone's collection tree: a collection and its ordered children.
///
/// `Identifiable` by the collection's id so a SwiftUI `List` / `DisclosureGroup` can
/// walk it directly.
public struct BrowseCollectionNode: Sendable, Equatable, Identifiable {
    public let collection: Collection
    public let children: [BrowseCollectionNode]

    public var id: UUID { collection.id }

    /// ``children``, or `nil` when there are none.
    ///
    /// The optional form is what SwiftUI's outline APIs take (`List(_:children:)`), and
    /// the `nil` is load-bearing there rather than cosmetic: an empty array still draws
    /// a disclosure chevron on a leaf, which invites a tap that does nothing.
    public var childNodes: [BrowseCollectionNode]? {
        children.isEmpty ? nil : children
    }

    public init(collection: Collection, children: [BrowseCollectionNode]) {
        self.collection = collection
        self.children = children
    }
}

/// The phone's collection ordering — a namespace, `static` only.
public enum BrowseCollectionTree {
    /// The sibling-order comparator: persisted `sortIndex` first, then `(name, id)` as
    /// a stable tiebreak so equal indices stay deterministic.
    /// `CollectionTargets.byManualOrder` (`CollectionTargets.swift:35`).
    public static func byManualOrder(_ a: Collection, _ b: Collection) -> Bool {
        (a.sortIndex, a.name, a.id.uuidString) < (b.sortIndex, b.name, b.id.uuidString)
    }

    /// The root collections in switcher order: the protected Unsorted folder pinned
    /// FIRST, then the rest in manual order. `CollectionTargets.galleryRoots`
    /// (`CollectionTargets.swift:19`).
    public static func roots(_ all: [Collection], unsortedID: UUID) -> [Collection] {
        let roots = all.filter { $0.parentCollectionID == nil }
        let unsorted = roots.filter { $0.id == unsortedID }
        let rest = roots.filter { $0.id != unsortedID }.sorted(by: byManualOrder)
        return unsorted + rest
    }

    /// The whole hierarchy as a recursive tree, roots in ``roots(_:unsortedID:)``
    /// order and each parent's children in manual order.
    ///
    /// Cycle-safe: a corrupt `parentCollectionID` loop cannot recurse forever, because
    /// a node already on the current path is dropped — the same guard
    /// `CollectionTargets.destinationTree` carries (`CollectionTargets.swift:58`). A
    /// collection whose parent id points at something that is not in `all` is
    /// unreachable from any root and therefore absent; that is a corrupt row, and the
    /// switcher is not the surface that repairs one.
    public static func tree(
        _ all: [Collection], unsortedID: UUID = Collection.unsortedID
    ) -> [BrowseCollectionNode] {
        let childrenByParent = Dictionary(grouping: all, by: { $0.parentCollectionID })
        func build(_ siblings: [Collection], onPath: Set<UUID>) -> [BrowseCollectionNode] {
            siblings.map { collection in
                var path = onPath
                path.insert(collection.id)
                let children = (childrenByParent[collection.id] ?? [])
                    .filter { !path.contains($0.id) }
                    .sorted(by: byManualOrder)
                return BrowseCollectionNode(
                    collection: collection, children: build(children, onPath: path))
            }
        }
        return build(roots(all, unsortedID: unsortedID), onPath: [])
    }

    /// Every node of `tree`, flattened pre-order with its depth — what a plain `List`
    /// needs when it indents rather than disclosing.
    public static func flattened(
        _ nodes: [BrowseCollectionNode], depth: Int = 0
    ) -> [(node: BrowseCollectionNode, depth: Int)] {
        nodes.flatMap { node in
            [(node, depth)] + flattened(node.children, depth: depth + 1)
        }
    }

    /// The node for `id` anywhere in `nodes`, or `nil`.
    public static func node(
        _ id: UUID, in nodes: [BrowseCollectionNode]
    ) -> BrowseCollectionNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = self.node(id, in: node.children) { return found }
        }
        return nil
    }
}
