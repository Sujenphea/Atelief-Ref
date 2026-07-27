//
//  CanvasDropRouterTests.swift
//  AtelierRefsTests
//
//  059 · SP1 / 11A — the exhaustive matrix for the pure board-drop decision
//  ``canvasDropRoute``, the canvas analog of ``DropRouterTests``. Every
//  ``CanvasDropContents`` case has an expected ``CanvasDropRoute`` here, so a
//  drift in the routing rule is caught before any AppKit wiring exists.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("canvasDropRoute: board-drop decision matrix")
struct CanvasDropRouterTests {

    private func payload(_ ids: [UUID], from source: UUID = UUID()) -> AssetDragPayload {
        AssetDragPayload(assetIDs: ids, sourceCollectionID: source)
    }

    // MARK: In-app asset drags → place

    @Test("an asset drag with ids places exactly those ids")
    func assetDragPlaces() {
        let ids = [UUID(), UUID()]
        #expect(canvasDropRoute(.assetDrag(payload(ids))) == .place(assetIDs: ids))
    }

    @Test("a membership-less (library / other-board) asset drag still places")
    func membershiplessAssetDragPlaces() {
        // A drag from library search / another board carries the nil source id;
        // a board is always additive, so source is irrelevant to placement.
        let ids = [UUID()]
        let p = payload(ids, from: AssetDragPayload.nilSourceID)
        #expect(canvasDropRoute(.assetDrag(p)) == .place(assetIDs: ids))
    }

    @Test("an empty asset drag is refused (internal marker never places nothing)")
    func emptyAssetDragRejected() {
        #expect(canvasDropRoute(.assetDrag(payload([]))) == .reject)
        #expect(canvasDropRoute(.assetDrag(AssetDragPayload.internalMarker)) == .reject)
    }

    // MARK: External content → ingest-then-place

    @Test("external content with an importable type ingests then places")
    func externalImportableIngests() {
        #expect(canvasDropRoute(.external(hasImportableType: true)) == .ingestThenPlace)
    }

    @Test("external content with nothing importable is refused")
    func externalUnimportableRejected() {
        #expect(canvasDropRoute(.external(hasImportableType: false)) == .reject)
    }

    // MARK: Foreign / empty → reject

    @Test("a sidebar space-reorder drag is never a board drop")
    func spaceReorderRejected() {
        #expect(canvasDropRoute(.spaceReorder) == .reject)
    }

    @Test("an unrecognized / empty drop is refused")
    func emptyRejected() {
        #expect(canvasDropRoute(.empty) == .reject)
    }
}
