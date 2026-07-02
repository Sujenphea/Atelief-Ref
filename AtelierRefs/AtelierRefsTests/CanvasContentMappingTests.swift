//
//  CanvasContentMappingTests.swift
//  AtelierRefsTests
//
//  Guards the canvas tile ↔ item mapping used by delete: a right-click / Delete
//  on a tile must resolve to the SAME asset the tile draws, and the shared
//  selection (a membership id) must map back to the right tile. An off-by-one
//  here would delete the wrong image, so it's worth a focused test.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("CanvasContent tile ↔ item mapping")
struct CanvasContentMappingTests {

    /// A detail with distinct membership + asset ids and no canvas placement
    /// (so tiles auto-lay in order, tile.id == index).
    private func detail(order: Int) -> CollectionItemDetail {
        let sourceID = UUID()
        let assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: String(format: "%08x", order),
            mimeType: "image/png", width: 100, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(),
            sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date())
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    private func makeContent(_ details: [CollectionItemDetail]) -> CanvasContent {
        CanvasContent(items: details, store: MediaStore(root: FileManager.default.temporaryDirectory))
    }

    @Test("detail(forTileID:) returns the item that tile draws")
    func detailRoundTrips() {
        let details = (0..<3).map { detail(order: $0) }
        let content = makeContent(details)
        for (index, expected) in details.enumerated() {
            #expect(content.detail(forTileID: index)?.item.id == expected.item.id)
            #expect(content.detail(forTileID: index)?.asset.id == expected.asset.id)
        }
    }

    @Test("tileID(forItemID:) inverts detail(forTileID:)")
    func tileIDInverts() {
        let details = (0..<3).map { detail(order: $0) }
        let content = makeContent(details)
        for (index, d) in details.enumerated() {
            #expect(content.tileID(forItemID: d.item.id) == index)
        }
    }

    @Test("out-of-range / unknown ids resolve to nil (no wrong-asset action)")
    func unknownIsNil() {
        let content = makeContent((0..<2).map { detail(order: $0) })
        #expect(content.detail(forTileID: 2) == nil)   // past the end
        #expect(content.detail(forTileID: -1) == nil)  // negative
        #expect(content.tileID(forItemID: UUID()) == nil) // not on this board
    }
}
