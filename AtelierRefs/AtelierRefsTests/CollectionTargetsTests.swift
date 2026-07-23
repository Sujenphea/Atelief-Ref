//
//  CollectionTargetsTests.swift
//  AtelierRefsTests
//
//  009 · N2 — the single source of collection ordering, shared by the gallery,
//  the Move/Add menus, and the drop rail. Guards Unsorted-pinning, the
//  subfolders-then-roots split, current-collection exclusion, and stable
//  (name,id) ordering so the three surfaces can never drift apart.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Collection targets ordering")
struct CollectionTargetsTests {

    private let unsortedID = Collection.unsortedID

    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil
    ) -> Collection {
        Collection(
            id: id, name: name, description: nil, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            parentCollectionID: parent)
    }

    // MARK: - Gallery roots

    @Test("gallery roots pin Unsorted first, then name-sorted; subfolders excluded")
    func galleryRootsOrder() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let zed = collection("Zed")
        let alpha = collection("Alpha")
        let child = collection("Child", parent: alpha.id)

        let roots = CollectionTargets.galleryRoots(
            [zed, unsorted, alpha, child], unsortedID: unsortedID)

        #expect(roots.map(\.name) == ["Unsorted", "Alpha", "Zed"])
    }

    @Test("gallery roots break a duplicate-name tie by id (stable)")
    func galleryRootsStableTie() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        let first = collection("Same", id: idA)
        let second = collection("Same", id: idB)

        let roots = CollectionTargets.galleryRoots([second, first], unsortedID: unsortedID)

        #expect(roots.map(\.id) == [idA, idB])
    }

    // MARK: - Move targets

    @Test("move targets list subfolders first, then roots (Unsorted included)")
    func moveTargetsSplit() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let current = collection("Current")
        let other = collection("Other")
        let subB = collection("Sub-B", parent: current.id)
        let subA = collection("Sub-A", parent: current.id)

        let targets = CollectionTargets.moveTargets(
            from: current.id,
            folders: [unsorted, current, other, subB, subA],
            unsortedID: unsortedID)

        #expect(targets.subfolders.map(\.name) == ["Sub-A", "Sub-B"])
        #expect(targets.roots.map(\.name) == ["Unsorted", "Other"])
        #expect(targets.all.map(\.name) == ["Sub-A", "Sub-B", "Unsorted", "Other"])
    }

    @Test("the current collection is never offered as its own target")
    func excludesCurrent() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let current = collection("Current")
        let other = collection("Other")

        let targets = CollectionTargets.moveTargets(
            from: current.id,
            folders: [unsorted, current, other],
            unsortedID: unsortedID)

        #expect(!targets.roots.contains { $0.id == current.id })
        #expect(targets.roots.map(\.name) == ["Unsorted", "Other"])
    }

    @Test("moving FROM a subfolder: its parent's other children are NOT auto-included, roots are")
    func fromSubfolder() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let root = collection("Root")
        let sub = collection("Sub", parent: root.id)
        let leaf = collection("Leaf", parent: sub.id)

        let targets = CollectionTargets.moveTargets(
            from: sub.id,
            folders: [unsorted, root, sub, leaf],
            unsortedID: unsortedID)

        // Only `sub`'s own direct children (leaf); roots are Unsorted + Root.
        #expect(targets.subfolders.map(\.name) == ["Leaf"])
        #expect(targets.roots.map(\.name) == ["Unsorted", "Root"])
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
