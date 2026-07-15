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
}
