//
//  DropRouterTests.swift
//  AtelierRefsTests
//
//  009 · N3 — the payload round-trip and the ONE pure drop decision. Covers every
//  reachable branch: same-vs-cross collection cell drops, manual-vs-non-manual
//  sort, from==to, empty payload, and ⌥ both ways for a collection target — so
//  the three drop surfaces can decode→route→execute without hand-rolled guards.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Asset drag payload + drop router")
struct DropRouterTests {

    private let colA = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private let colB = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
    private func assets(_ n: Int) -> [UUID] {
        (0..<n).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
    }

    // MARK: - Payload Codable round-trip

    @Test("payload round-trips through Codable unchanged")
    func payloadRoundTrip() throws {
        let original = AssetDragPayload(assetIDs: assets(3), sourceCollectionID: colA)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssetDragPayload.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Cell drop (reorder)

    @Test("same-collection manual cell drop reorders")
    func cellSameManualReorders() {
        let ids = assets(2)
        let payload = AssetDragPayload(assetIDs: ids, sourceCollectionID: colA)
        let outcome = routeDrop(
            payload, onto: .cell(collectionID: colA, sortMode: .manual), optionDown: false)
        #expect(outcome == .reorder(assetIDs: ids))
    }

    @Test("cell drop in a non-manual sort is refused (reorder has no meaning)")
    func cellNonManualRejects() {
        let payload = AssetDragPayload(assetIDs: assets(1), sourceCollectionID: colA)
        #expect(routeDrop(
            payload, onto: .cell(collectionID: colA, sortMode: .newest),
            optionDown: false) == .reject)
        #expect(routeDrop(
            payload, onto: .cell(collectionID: colA, sortMode: .mostViewed),
            optionDown: false) == .reject)
    }

    @Test("cross-collection cell drop is refused (moves go via the rail/stack)")
    func cellCrossCollectionRejects() {
        let payload = AssetDragPayload(assetIDs: assets(2), sourceCollectionID: colB)
        let outcome = routeDrop(
            payload, onto: .cell(collectionID: colA, sortMode: .manual), optionDown: false)
        #expect(outcome == .reject)
    }

    @Test("⌥ does not turn a cell reorder into a copy")
    func cellIgnoresOption() {
        let ids = assets(2)
        let payload = AssetDragPayload(assetIDs: ids, sourceCollectionID: colA)
        let outcome = routeDrop(
            payload, onto: .cell(collectionID: colA, sortMode: .manual), optionDown: true)
        #expect(outcome == .reorder(assetIDs: ids))
    }

    // MARK: - Internal marker (192 — the semantics-free detail-drag identity)

    @Test("the internal marker is rejected at EVERY target — it only marks, never acts")
    func internalMarkerRoutesNowhere() {
        let marker = AssetDragPayload.internalMarker
        #expect(routeDrop(
            marker, onto: .cell(collectionID: colA, sortMode: .manual),
            optionDown: false) == .reject)
        #expect(routeDrop(marker, onto: .collection(colA), optionDown: false) == .reject)
        #expect(routeDrop(marker, onto: .collection(colA), optionDown: true) == .reject)
    }

    @Test("the marker's source id is the nil UUID — impossible for a real collection")
    func internalMarkerSourceIsNilUUID() {
        #expect(AssetDragPayload.internalMarker.assetIDs.isEmpty)
        #expect(AssetDragPayload.internalMarker.sourceCollectionID
            == UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    // MARK: - Collection drop (move / copy)

    @Test("plain collection drop moves from source to target")
    func collectionPlainMoves() {
        let ids = assets(3)
        let payload = AssetDragPayload(assetIDs: ids, sourceCollectionID: colA)
        let outcome = routeDrop(payload, onto: .collection(colB), optionDown: false)
        #expect(outcome == .move(assetIDs: ids, from: colA, to: colB))
    }

    @Test("⌥ collection drop copies into the target, source kept")
    func collectionOptionCopies() {
        let ids = assets(3)
        let payload = AssetDragPayload(assetIDs: ids, sourceCollectionID: colA)
        let outcome = routeDrop(payload, onto: .collection(colB), optionDown: true)
        #expect(outcome == .copy(assetIDs: ids, to: colB))
    }

    @Test("a drop onto the SOURCE collection is refused (from == to)")
    func collectionSelfRejects() {
        let payload = AssetDragPayload(assetIDs: assets(2), sourceCollectionID: colA)
        #expect(routeDrop(payload, onto: .collection(colA), optionDown: false) == .reject)
        #expect(routeDrop(payload, onto: .collection(colA), optionDown: true) == .reject)
    }

    @Test("a sourceless (search / board) collection drop copies, never moves")
    func collectionSourcelessCopies() {
        let ids = assets(2)
        let payload = AssetDragPayload(assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID)
        // No source to move OUT of → always a copy (add), with or without ⌥.
        #expect(routeDrop(payload, onto: .collection(colA), optionDown: false)
            == .copy(assetIDs: ids, to: colA))
        #expect(routeDrop(payload, onto: .collection(colA), optionDown: true)
            == .copy(assetIDs: ids, to: colA))
    }

    // MARK: - Degenerate payloads

    @Test("an empty payload is always refused, whatever the target")
    func emptyPayloadRejects() {
        let empty = AssetDragPayload(assetIDs: [], sourceCollectionID: colA)
        #expect(routeDrop(
            empty, onto: .cell(collectionID: colA, sortMode: .manual),
            optionDown: false) == .reject)
        #expect(routeDrop(empty, onto: .collection(colB), optionDown: false) == .reject)
        #expect(routeDrop(empty, onto: .collection(colB), optionDown: true) == .reject)
    }
}
