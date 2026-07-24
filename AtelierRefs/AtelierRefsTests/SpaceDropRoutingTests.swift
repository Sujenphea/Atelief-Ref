//
//  SpaceDropRoutingTests.swift
//  AtelierRefsTests
//
//  043 (spaces) — the pure drag brain for the flat Spaces NSOutlineView, the
//  space analog of `CollectionDropRoutingTests`. Two AppKit-free units so the
//  coordinator glue stays thin: the `SpaceDragPayload` wire round-trip, and
//  `SpaceTargets.routeOutlineDrop(...)` (child index → `.move` / `.reject`,
//  including the same-list reorder index normalization). Spaces are flat, so there
//  is no nest / cycle case — a strict subset of the collection routing.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Space drop routing (043 · spaces)")
struct SpaceDropRoutingTests {

    /// A fixture with an explicit `sortIndex` so list order is deterministic in the
    /// reorder-normalization cases. `createdAt` is fixed so it never tie-breaks.
    private func space(_ name: String, id: UUID = UUID(), order: Int = 0) -> Space {
        Space(
            id: id, name: name, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            sortIndex: order)
    }

    // MARK: - Payload round-trip

    @Test("SpaceDragPayload round-trips through its pasteboard bytes")
    func payloadRoundTrip() throws {
        let payload = SpaceDragPayload(spaceID: UUID())
        let data = try payload.pasteboardData()
        #expect(SpaceDragPayload.decode(from: data) == payload)
    }

    @Test("a garbage pasteboard buffer decodes to nil, not a crash")
    func payloadDecodeGarbage() {
        #expect(SpaceDragPayload.decode(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    // MARK: - Routing

    @Test("dragging a space not in the list is rejected")
    func unknownDraggedRejected() {
        let a = space("A", order: 0)
        #expect(SpaceTargets.routeOutlineDrop(
            dragged: UUID(), childIndex: 0, spaces: [a]) == .reject)
    }

    @Test("a nil child index appends")
    func nilIndexAppends() {
        let a = space("A", order: 0)
        let b = space("B", order: 1)
        #expect(SpaceTargets.routeOutlineDrop(
            dragged: a.id, childIndex: nil, spaces: [a, b]) == .move(index: nil))
    }

    @Test("reorder DOWN normalizes the index by −1 (removed slot)")
    func reorderDownNormalizes() {
        // List [A(0), B(1), C(2)]; drag A to childIndex 2 (below its own slot 0).
        let a = space("A", order: 0)
        let b = space("B", order: 1)
        let c = space("C", order: 2)
        // With A removed the list is [B, C]; "before index 2" == append after C ==
        // service index 1.
        #expect(SpaceTargets.routeOutlineDrop(
            dragged: a.id, childIndex: 2, spaces: [a, b, c]) == .move(index: 1))
    }

    @Test("reorder UP keeps the index (no removal shift)")
    func reorderUpKeepsIndex() {
        // List [A(0), B(1), C(2)]; drag C to childIndex 0 (above its slot 2).
        let a = space("A", order: 0)
        let b = space("B", order: 1)
        let c = space("C", order: 2)
        #expect(SpaceTargets.routeOutlineDrop(
            dragged: c.id, childIndex: 0, spaces: [a, b, c]) == .move(index: 0))
    }

    @Test("ordered() sorts by sortIndex regardless of input order")
    func orderedSortsBySortIndex() {
        let a = space("A", order: 2)
        let b = space("B", order: 0)
        let c = space("C", order: 1)
        #expect(SpaceTargets.ordered([a, b, c]).map(\.name) == ["B", "C", "A"])
    }
}
