//
//  CollectionDropRoutingTests.swift
//  AtelierRefsTests
//
//  043 · Phase C · 12A — the pure drag brain for the NSOutlineView sidebar. Two
//  units, both AppKit-free and exhaustively tested so the coordinator glue can
//  stay thin: the `CollectionDragPayload` wire round-trip, and
//  `CollectionTargets.routeOutlineDrop(...)` (proposed parent + child index →
//  `.move` / `.reject`, including the same-parent reorder index normalization).
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Collection drop routing (043 · 12A)")
struct CollectionDropRoutingTests {

    private let unsortedID = Collection.unsortedID

    /// A fixture with an explicit `sortIndex` so sibling order is deterministic in
    /// the reorder-normalization cases.
    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil, order: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, description: nil, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            parentCollectionID: parent, sortMode: .manual, sortIndex: order)
    }

    // MARK: - Payload round-trip

    @Test("CollectionDragPayload round-trips through its pasteboard bytes")
    func payloadRoundTrip() throws {
        let payload = CollectionDragPayload(collectionID: UUID())
        let data = try payload.pasteboardData()
        #expect(CollectionDragPayload.decode(from: data) == payload)
    }

    @Test("a garbage pasteboard buffer decodes to nil, not a crash")
    func payloadDecodeGarbage() {
        #expect(CollectionDragPayload.decode(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    // MARK: - Nest onto a row (childIndex == nil)

    @Test("drop ON a row nests + appends (index nil)")
    func nestOntoRow() {
        let a = collection("A")
        let b = collection("B")
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: a.id, into: b.id, childIndex: nil,
            folders: [a, b], unsortedID: unsortedID)
        #expect(drop == .move(toParent: b.id, index: nil))
    }

    @Test("drop ON self is rejected")
    func nestOntoSelf() {
        let a = collection("A")
        #expect(CollectionTargets.routeOutlineDrop(
            dragged: a.id, into: a.id, childIndex: nil,
            folders: [a], unsortedID: unsortedID) == .reject)
    }

    @Test("drop ON a descendant is rejected")
    func nestOntoDescendant() {
        let root = collection("Root")
        let child = collection("Child", parent: root.id)
        #expect(CollectionTargets.routeOutlineDrop(
            dragged: root.id, into: child.id, childIndex: nil,
            folders: [root, child], unsortedID: unsortedID) == .reject)
    }

    @Test("drop ON the protected Unsorted is rejected")
    func nestOntoUnsorted() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let a = collection("A")
        #expect(CollectionTargets.routeOutlineDrop(
            dragged: a.id, into: unsortedID, childIndex: nil,
            folders: [unsorted, a], unsortedID: unsortedID) == .reject)
    }

    @Test("dragging the protected Unsorted is rejected")
    func dragUnsorted() {
        let unsorted = collection("Unsorted", id: unsortedID)
        let a = collection("A")
        #expect(CollectionTargets.routeOutlineDrop(
            dragged: unsortedID, into: a.id, childIndex: nil,
            folders: [unsorted, a], unsortedID: unsortedID) == .reject)
    }

    // MARK: - Between rows (childIndex >= 0)

    @Test("drop BETWEEN under a different parent inserts at the index unchanged")
    func betweenDifferentParent() {
        let p = collection("P")
        let q = collection("Q")
        let dragged = collection("D", parent: p.id, order: 0)
        let x = collection("X", parent: q.id, order: 0)
        let y = collection("Y", parent: q.id, order: 1)
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: dragged.id, into: q.id, childIndex: 1,
            folders: [p, q, dragged, x, y], unsortedID: unsortedID)
        #expect(drop == .move(toParent: q.id, index: 1))
    }

    @Test("drop BETWEEN at top level inserts at the index")
    func betweenTopLevel() {
        let dragged = collection("D", parent: collection("P").id)
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: dragged.id, into: nil, childIndex: 2,
            folders: [dragged], unsortedID: unsortedID)
        #expect(drop == .move(toParent: nil, index: 2))
    }

    @Test("same-parent reorder DOWN normalizes the index by −1 (removed slot)")
    func reorderDownNormalizes() {
        // P: [A(0), B(1), C(2)]; drag A to childIndex 2 (below its own slot 0).
        let p = collection("P")
        let a = collection("A", parent: p.id, order: 0)
        let b = collection("B", parent: p.id, order: 1)
        let c = collection("C", parent: p.id, order: 2)
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: a.id, into: p.id, childIndex: 2,
            folders: [p, a, b, c], unsortedID: unsortedID)
        // With A removed the list is [B, C]; inserting "before index 2" == append
        // after C == service index 1.
        #expect(drop == .move(toParent: p.id, index: 1))
    }

    @Test("same-parent reorder UP keeps the index (no removal shift)")
    func reorderUpKeepsIndex() {
        // P: [A(0), B(1), C(2)]; drag C to childIndex 0 (above its slot 2).
        let p = collection("P")
        let a = collection("A", parent: p.id, order: 0)
        let b = collection("B", parent: p.id, order: 1)
        let c = collection("C", parent: p.id, order: 2)
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: c.id, into: p.id, childIndex: 0,
            folders: [p, a, b, c], unsortedID: unsortedID)
        #expect(drop == .move(toParent: p.id, index: 0))
    }

    @Test("drop BETWEEN under a descendant is rejected")
    func betweenDescendantRejected() {
        let root = collection("Root")
        let mid = collection("Mid", parent: root.id)
        #expect(CollectionTargets.routeOutlineDrop(
            dragged: root.id, into: mid.id, childIndex: 0,
            folders: [root, mid], unsortedID: unsortedID) == .reject)
    }
}
