//
//  CollectionTargetsTests.swift
//  AtelierRefsTests
//
//  009 · N2 — the single source of collection ordering, shared by the gallery,
//  the Move/Add destination renderers, and the drop rail. Guards Unsorted-pinning,
//  the whole-hierarchy destination tree (027 · G2, which replaced the old
//  one-level `moveTargets` split), and stable (name,id) ordering so the surfaces
//  can never drift apart.
//
//  **Since 098 · finding 6 these assert the package's implementation.** The ordering,
//  the recursion and the cycle guard moved to ``BrowseCollectionTree`` — where 093 § 2
//  had already restated them for the phone's switcher — and `CollectionTargets` kept
//  only what the phone has no surface for. Not one assertion below changed: they were
//  written against the RULES (Unsorted first, `sortIndex` before name, id breaks a tie,
//  a corrupt parent loop terminates), and the rules are the same rules, so what these
//  now prove is that both platforms get them from the same lines. The three cases that
//  named `CollectionTargets.galleryRoots` name `BrowseCollectionTree.roots` instead;
//  `destinationTree` keeps its name because it still exists, as a one-line forward.
//

import AtelierBrowse
import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Collection targets ordering")
struct CollectionTargetsTests {

    private let unsortedID = Collection.unsortedID

    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil, sortIndex: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, description: nil, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            parentCollectionID: parent, sortIndex: sortIndex)
    }

    // MARK: - Gallery roots

    @Test("gallery roots pin Unsorted first, then name-sorted; subfolders excluded")
    func galleryRootsOrder() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let zed = collection("Zed")
        let alpha = collection("Alpha")
        let child = collection("Child", parent: alpha.id)

        let roots = BrowseCollectionTree.roots(
            [zed, unsorted, alpha, child], unsortedID: unsortedID)

        #expect(roots.map(\.name) == ["Unsorted", "Alpha", "Zed"])
    }

    @Test("gallery roots break a duplicate-name tie by id (stable)")
    func galleryRootsStableTie() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        let first = collection("Same", id: idA)
        let second = collection("Same", id: idB)

        let roots = BrowseCollectionTree.roots([second, first], unsortedID: unsortedID)

        #expect(roots.map(\.id) == [idA, idB])
    }

    // MARK: - The destination tree (027 · G2 — the ONE ordering)

    @Test("the destination tree carries the WHOLE hierarchy, not one level")
    func destinationTreeIsRecursive() {
        // The exact shape 027 §A names: from `Refs` the old `moveTargets` reached
        // `Refs/Type` but never `Refs/Type/Serif`, at any depth, forever.
        let unsorted = collection("Unsorted", id: unsortedID)
        let refs = collection("Refs")
        let type = collection("Type", parent: refs.id)
        let serif = collection("Serif", parent: type.id)
        let sans = collection("Sans", parent: type.id, sortIndex: 1)

        let tree = CollectionTargets.destinationTree(
            folders: [unsorted, refs, type, serif, sans], unsortedID: unsortedID)

        #expect(tree.map(\.collection.name) == ["Unsorted", "Refs"])
        #expect(tree[1].children.map(\.collection.name) == ["Type"])
        #expect(tree[1].children[0].children.map(\.collection.name) == ["Serif", "Sans"])
    }

    @Test("the current collection is NOT filtered out (it is greyed by the renderers)")
    func destinationTreeKeepsTheCurrentCollection() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let current = collection("Current")
        let other = collection("Other")

        let tree = CollectionTargets.destinationTree(
            folders: [unsorted, current, other], unsortedID: unsortedID)

        #expect(tree.map(\.collection.name) == ["Unsorted", "Current", "Other"])
    }

    @Test("children come in MANUAL order (sortIndex), roots in gallery order")
    func destinationTreeManualOrder() {
        let unsorted = collection("Unsorted", id: unsortedID)
        // sortIndex wins over the alphabetical tiebreak, at both levels.
        let zed = collection("Zed", sortIndex: 0)
        let alpha = collection("Alpha", sortIndex: 1)
        let bChild = collection("B", parent: zed.id, sortIndex: 0)
        let aChild = collection("A", parent: zed.id, sortIndex: 1)

        let tree = CollectionTargets.destinationTree(
            folders: [unsorted, alpha, zed, aChild, bChild], unsortedID: unsortedID)

        #expect(tree.map(\.collection.name) == ["Unsorted", "Zed", "Alpha"])
        #expect(tree[1].children.map(\.collection.name) == ["B", "A"])
    }

    @Test("an empty library yields no destinations")
    func destinationTreeEmpty() {
        #expect(CollectionTargets.destinationTree(folders: [], unsortedID: unsortedID).isEmpty)
    }

    @Test("a corrupt parent loop under a real root terminates instead of recursing forever")
    func destinationTreeCycleSafe() {
        // root → a → b → a. Without the on-path guard this recurses until the stack
        // dies; with it, the repeat is dropped and the walk ends.
        let root = collection("Root")
        let aID = UUID(), bID = UUID()
        let a = collection("A", id: aID, parent: root.id)
        let b = collection("B", id: bID, parent: aID)
        // The corrupt row: `A` again, this time claiming `B` as its parent.
        let loopBackToA = collection("A", id: aID, parent: bID)

        let tree = CollectionTargets.destinationTree(
            folders: [root, a, b, loopBackToA], unsortedID: unsortedID)

        #expect(tree.map(\.collection.name) == ["Root"])
        #expect(tree[0].children.map(\.collection.name) == ["A"])
        #expect(tree[0].children[0].children.map(\.collection.name) == ["B"])
        #expect(tree[0].children[0].children[0].children.isEmpty)
    }

    // MARK: - The flattened, indented list

    @Test("the flattened tree is pre-order with a depth per row")
    func moveTargetTreeDepths() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let refs = collection("Refs")
        let type = collection("Type", parent: refs.id)
        let serif = collection("Serif", parent: type.id)
        let photography = collection("Photography", sortIndex: 1)
        let portraits = collection("Portraits", parent: photography.id)

        let rows = CollectionTargets.moveTargetTree(
            folders: [unsorted, refs, type, serif, photography, portraits],
            unsortedID: unsortedID)

        #expect(rows.map(\.collection.name)
            == ["Unsorted", "Refs", "Type", "Serif", "Photography", "Portraits"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 0, 1])
    }

    @Test("a 6-deep chain is flattened to depths 0…5 — no cap, ever")
    func moveTargetTreeSixDeep() {
        var folders = [collection("Unsorted", id: unsortedID)]
        var parent: UUID?
        for level in 0..<6 {
            let c = collection("L\(level)", parent: parent)
            folders.append(c)
            parent = c.id
        }

        let rows = CollectionTargets.moveTargetTree(folders: folders, unsortedID: unsortedID)

        #expect(rows.map(\.collection.name) == ["Unsorted", "L0", "L1", "L2", "L3", "L4", "L5"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 3, 4, 5])
    }

    // MARK: - Folder reparent targets (043)

    @Test("reparent targets exclude self, descendants, current parent, and Unsorted")
    func reparentExclusions() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let root = collection("Root")
        let mover = collection("Mover", parent: root.id)   // current parent = Root
        let child = collection("Child", parent: mover.id)  // descendant
        let grandchild = collection("Grandchild", parent: child.id)
        let other = collection("Other")

        let targets = CollectionTargets.folderMoveTargets(
            for: mover.id,
            folders: [unsorted, root, mover, child, grandchild, other],
            unsortedID: unsortedID)

        // Root (current parent), Mover (self), Child + Grandchild (descendants),
        // and Unsorted are all excluded — only the unrelated Other remains.
        #expect(targets.map(\.name) == ["Other"])
    }

    @Test("reparent targets are name-then-id ordered")
    func reparentOrder() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let mover = collection("Mover")           // top level: no current parent
        let zed = collection("Zed")
        let alpha = collection("Alpha")

        let targets = CollectionTargets.folderMoveTargets(
            for: mover.id,
            folders: [unsorted, mover, zed, alpha],
            unsortedID: unsortedID)

        #expect(targets.map(\.name) == ["Alpha", "Zed"])
    }

    @Test("descendantIDs walks the whole subtree, excluding the root itself")
    func descendants() {
        let root = collection("Root")
        let a = collection("A", parent: root.id)
        let b = collection("B", parent: a.id)
        let c = collection("C", parent: root.id)
        let unrelated = collection("Unrelated")

        let ids = CollectionTargets.descendantIDs(
            of: root.id, in: [root, a, b, c, unrelated])

        #expect(ids == Set([a.id, b.id, c.id]))
    }

    @Test("descendantIDs is cycle-safe (a corrupt parent loop terminates)")
    func descendantsCycleSafe() {
        let aID = UUID(), bID = UUID()
        // A ↔ B parent each other — a corrupt cycle that must not hang the walk.
        // The `visited` guard bounds it: each id is enqueued at most once, so the
        // walk terminates (reaching both nodes) instead of looping forever.
        let a = collection("A", id: aID, parent: bID)
        let b = collection("B", id: bID, parent: aID)

        let ids = CollectionTargets.descendantIDs(of: aID, in: [a, b])

        #expect(ids == Set([aID, bID]))
    }

    // MARK: - canReparent (043 · 5A)

    @Test("canReparent rejects moving into self")
    func reparentRejectsSelf() {
        let a = collection("A")
        #expect(!CollectionTargets.canReparent(
            a.id, into: a.id, folders: [a], unsortedID: unsortedID))
    }

    @Test("canReparent rejects moving into a direct child")
    func reparentRejectsDirectChild() {
        let parent = collection("Parent")
        let child = collection("Child", parent: parent.id)
        #expect(!CollectionTargets.canReparent(
            parent.id, into: child.id, folders: [parent, child], unsortedID: unsortedID))
    }

    @Test("canReparent rejects moving into a deep descendant")
    func reparentRejectsDeepDescendant() {
        let root = collection("Root")
        let mid = collection("Mid", parent: root.id)
        let leaf = collection("Leaf", parent: mid.id)
        #expect(!CollectionTargets.canReparent(
            root.id, into: leaf.id, folders: [root, mid, leaf], unsortedID: unsortedID))
    }

    @Test("canReparent is cycle-safe on corrupt data and still rejects the cycle")
    func reparentCycleSafe() {
        let aID = UUID(), bID = UUID()
        let a = collection("A", id: aID, parent: bID)
        let b = collection("B", id: bID, parent: aID)
        // `b` is (corruptly) a descendant of `a`, so a→b is refused; the walk
        // must terminate rather than hang.
        #expect(!CollectionTargets.canReparent(
            aID, into: bID, folders: [a, b], unsortedID: unsortedID))
    }

    @Test("canReparent rejects filing a folder under the protected Unsorted")
    func reparentRejectsIntoUnsorted() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let a = collection("A")
        #expect(!CollectionTargets.canReparent(
            a.id, into: unsortedID, folders: [unsorted, a], unsortedID: unsortedID))
    }

    @Test("canReparent rejects moving the protected Unsorted itself")
    func reparentRejectsMovingUnsorted() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let a = collection("A")
        #expect(!CollectionTargets.canReparent(
            unsortedID, into: a.id, folders: [unsorted, a], unsortedID: unsortedID))
    }

    @Test("canReparent allows moving to top level (nil parent)")
    func reparentAllowsTopLevel() {
        let root = collection("Root")
        let child = collection("Child", parent: root.id)
        #expect(CollectionTargets.canReparent(
            child.id, into: nil, folders: [root, child], unsortedID: unsortedID))
    }

    @Test("canReparent allows an unrelated destination")
    func reparentAllowsUnrelated() {
        let a = collection("A")
        let b = collection("B")
        #expect(CollectionTargets.canReparent(
            a.id, into: b.id, folders: [a, b], unsortedID: unsortedID))
    }

    @Test("canReparent allows the SAME parent (a structural no-op — reorder is valid)")
    func reparentAllowsSameParent() {
        let parent = collection("Parent")
        let child = collection("Child", parent: parent.id)
        // Dropping back under the current parent is structurally fine; the drop
        // coordinator treats it as a reorder, not a reparent.
        #expect(CollectionTargets.canReparent(
            child.id, into: parent.id, folders: [parent, child], unsortedID: unsortedID))
    }
}
