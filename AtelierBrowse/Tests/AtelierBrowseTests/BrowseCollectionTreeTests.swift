// AtelierBrowse tests — the switcher's ordering (093 § 2).
//
// These assert the RULES rather than a fixture's spelling, because this file is a
// restatement of `CollectionTargets` and the thing that must not drift is the rule:
// Unsorted first, then `sortIndex`, then `(name, id)`; children in the same order as
// siblings; a corrupt parent cycle terminates.

import Foundation
import Testing

import AtelierCore
@testable import AtelierBrowse

@Suite("BrowseCollectionTree (093 §2)")
struct BrowseCollectionTreeTests {

    @Test("Unsorted is pinned first however it sorts on its own merits")
    func unsortedPinned() {
        // Named "Zzz" with the highest sortIndex — every other rule would put it last.
        let unsorted = collection(id: Collection.unsortedID, name: "Zzz", sortIndex: 99)
        let a = collection(name: "Aaa", sortIndex: 0)
        let roots = BrowseCollectionTree.roots([a, unsorted], unsortedID: Collection.unsortedID)
        #expect(roots.map(\.id) == [unsorted.id, a.id])
    }

    @Test("siblings order by sortIndex before name")
    func manualOrderBeatsName() {
        let first = collection(name: "Zebra", sortIndex: 0)
        let second = collection(name: "Aardvark", sortIndex: 1)
        let roots = BrowseCollectionTree.roots([second, first], unsortedID: Collection.unsortedID)
        #expect(roots.map(\.name) == ["Zebra", "Aardvark"])
    }

    @Test("equal sortIndex falls back to name, then to id — a stable, total order")
    func tieBreaks() {
        let a = collection(id: uuid(102), name: "Same", sortIndex: 0)
        let b = collection(id: uuid(101), name: "Same", sortIndex: 0)
        let c = collection(id: uuid(109), name: "Other", sortIndex: 0)
        let roots = BrowseCollectionTree.roots([a, b, c], unsortedID: Collection.unsortedID)
        #expect(roots.map(\.id) == [c.id, b.id, a.id])
    }

    @Test("children nest under their parent, in the same sibling order")
    func nesting() {
        let parent = collection(id: uuid(101), name: "Parent", sortIndex: 0)
        let childB = collection(id: uuid(103), name: "B", sortIndex: 1, parent: parent.id)
        let childA = collection(id: uuid(102), name: "A", sortIndex: 0, parent: parent.id)
        let grandchild = collection(id: uuid(104), name: "Deep", sortIndex: 0, parent: childA.id)

        let tree = BrowseCollectionTree.tree(
            [childB, grandchild, parent, childA], unsortedID: Collection.unsortedID)

        #expect(tree.count == 1)
        #expect(tree[0].children.map(\.collection.name) == ["A", "B"])
        #expect(tree[0].children[0].children.map(\.collection.name) == ["Deep"])
    }

    @Test("a corrupt parent cycle terminates rather than recursing forever")
    func cycleSafe() {
        // Two collections each claiming the other as parent, so neither is a root and
        // the tree is empty — but building it must RETURN.
        let a = collection(id: uuid(101), name: "A", sortIndex: 0, parent: uuid(102))
        let b = collection(id: uuid(102), name: "B", sortIndex: 0, parent: uuid(101))
        #expect(BrowseCollectionTree.tree([a, b], unsortedID: Collection.unsortedID).isEmpty)

        // And a cycle reachable FROM a root stops at the repeat rather than looping.
        let root = collection(id: Collection.unsortedID, name: "Unsorted", sortIndex: 0)
        let child = collection(id: uuid(103), name: "C", sortIndex: 0, parent: root.id)
        let loop = collection(id: uuid(104), name: "D", sortIndex: 0, parent: child.id)
        let backEdge = collection(id: child.id, name: "C again", sortIndex: 0, parent: loop.id)
        let tree = BrowseCollectionTree.tree(
            [root, child, loop, backEdge], unsortedID: Collection.unsortedID)
        #expect(tree.count == 1)
    }

    @Test("flattening is pre-order with a depth per row")
    func flatten() {
        let parent = collection(id: uuid(101), name: "Parent", sortIndex: 0)
        let child = collection(id: uuid(102), name: "Child", sortIndex: 0, parent: parent.id)
        let grandchild = collection(id: uuid(103), name: "Grandchild", sortIndex: 0, parent: child.id)
        let sibling = collection(id: uuid(104), name: "Sibling", sortIndex: 1)

        let rows = BrowseCollectionTree.flattened(
            BrowseCollectionTree.tree([parent, child, grandchild, sibling],
                                      unsortedID: Collection.unsortedID))
        #expect(rows.map(\.node.collection.name) == ["Parent", "Child", "Grandchild", "Sibling"])
        #expect(rows.map(\.depth) == [0, 1, 2, 0])
    }

    @Test("a node is findable anywhere in the tree")
    func findNode() {
        let parent = collection(id: uuid(101), name: "Parent", sortIndex: 0)
        let child = collection(id: uuid(102), name: "Child", sortIndex: 0, parent: parent.id)
        let tree = BrowseCollectionTree.tree([parent, child], unsortedID: Collection.unsortedID)
        #expect(BrowseCollectionTree.node(child.id, in: tree)?.collection.name == "Child")
        #expect(BrowseCollectionTree.node(uuid(199), in: tree) == nil)
    }

    @Test("a collection whose parent is not in the set is unreachable, not a root")
    func orphanIsNotPromoted() {
        // A corrupt row must not silently appear at the top level, where it would read
        // as a real root collection.
        let orphan = collection(id: uuid(101), name: "Orphan", sortIndex: 0, parent: uuid(142))
        #expect(BrowseCollectionTree.tree([orphan], unsortedID: Collection.unsortedID).isEmpty)
    }

    // MARK: - Fixtures

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func collection(
        id: UUID = UUID(), name: String, sortIndex: Int, parent: UUID? = nil
    ) -> Collection {
        Collection(
            id: id, name: name, createdAt: Date(), updatedAt: Date(),
            parentCollectionID: parent, sortIndex: sortIndex)
    }
}
