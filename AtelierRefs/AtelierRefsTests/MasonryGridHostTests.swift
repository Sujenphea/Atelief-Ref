//
//  MasonryGridHostTests.swift
//  AtelierRefsTests
//
//  036 §2 A1 — the pure, extractable pieces of the AppKit grid host: the
//  coordinator's snapshot-diff decision and `idToIndex` map, the analytic-frame →
//  thumbnail-bucket choice, and the shared accessibility-label function.
//
//  The `NSViewRepresentable` / coordinator wiring itself cannot be exercised
//  headlessly (it needs a live `NSScrollView` + `NSCollectionView` in a window,
//  and the diffable data source drives real cell materialization) — that path is
//  covered by the manual verification noted in the change-log. These tests pin
//  the LOGIC the coordinator delegates to, which is where a regression would
//  actually hide.
//

import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

private func detail(
    id: UUID = UUID(), kind: AssetKind = .image,
    title: String? = nil, authorHandle: String? = nil
) -> CollectionItemDetail {
    let sourceID = UUID(), assetID = UUID()
    let source = Source(
        id: sourceID, platform: .web, authorHandle: authorHandle, title: title,
        capturedAt: Date())
    let asset = Asset(
        id: assetID, kind: kind,
        blobHash: kind == .image ? UUID().uuidString : nil,
        mimeType: kind == .image ? "image/png" : nil,
        width: 100, height: 100, duration: nil,
        fileSize: kind == .image ? 100 : nil,
        downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
    let item = CollectionItem(id: id, collectionID: UUID(), assetID: assetID, addedAt: Date())
    return CollectionItemDetail(item: item, asset: asset, source: source)
}

// MARK: - Snapshot ids + idToIndex

@Suite("Grid host: snapshot ids and idToIndex")
struct GridHostIdentityTests {

    @Test("snapshot ids are the membership item.ids in display order")
    func snapshotIDsInOrder() {
        let a = detail(), b = detail(), c = detail()
        let ids = gridSnapshotIDs(for: [a, b, c])
        #expect(ids == [a.item.id, b.item.id, c.item.id])
    }

    @Test("idToIndex maps each id to its row")
    func idToIndexMapsRows() {
        let a = detail(), b = detail(), c = detail()
        let map = gridIDToIndex(for: [a, b, c])
        #expect(map[a.item.id] == 0)
        #expect(map[b.item.id] == 1)
        #expect(map[c.item.id] == 2)
        #expect(map.count == 3)
    }

    @Test("an empty item set yields an empty map and ids")
    func empty() {
        #expect(gridSnapshotIDs(for: []).isEmpty)
        #expect(gridIDToIndex(for: []).isEmpty)
    }
}

// MARK: - Apply strategy (reconfigure vs snapshot)

@Suite("Grid host: apply strategy")
struct GridApplyStrategyTests {

    @Test("same ids, same order, same collection → reconfigure in place")
    func sameOrderReconfigures() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(gridApplyStrategy(oldIDs: ids, newIDs: ids, collectionChanged: false) == .reconfigure)
    }

    @Test("a collection switch always snapshots, even at identical ids")
    func collectionSwitchSnapshots() {
        let ids = [UUID(), UUID()]
        #expect(gridApplyStrategy(oldIDs: ids, newIDs: ids, collectionChanged: true) == .snapshot)
    }

    @Test("a reorder (same set, different order) snapshots")
    func reorderSnapshots() {
        let a = UUID(), b = UUID()
        #expect(gridApplyStrategy(oldIDs: [a, b], newIDs: [b, a], collectionChanged: false) == .snapshot)
    }

    @Test("an insert or delete (different membership) snapshots")
    func membershipChangeSnapshots() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(gridApplyStrategy(oldIDs: [a, b], newIDs: [a, b, c], collectionChanged: false) == .snapshot)
        #expect(gridApplyStrategy(oldIDs: [a, b, c], newIDs: [a, b], collectionChanged: false) == .snapshot)
    }

    @Test("first load (empty → populated) snapshots")
    func firstLoadSnapshots() {
        #expect(gridApplyStrategy(oldIDs: [], newIDs: [UUID()], collectionChanged: false) == .snapshot)
    }
}

// MARK: - Bucket from analytic frame

@Suite("Grid host: thumbnail bucket from analytic frame")
struct GridThumbnailBucketTests {

    @Test("uses the frame's long side, matching thumbnailPixelBucket")
    func longSideDrivesBucket() {
        // A 150x100 cell on 2x → long side 150 → 300 px → snaps up to 384.
        let frame = CGRect(x: 0, y: 0, width: 150, height: 100)
        #expect(
            gridThumbnailBucket(frame: frame, columnWidth: 150, scale: 2)
                == thumbnailPixelBucket(pointLongSide: 150, scale: 2))
        // A tall cell: height is the long side.
        let tall = CGRect(x: 0, y: 0, width: 100, height: 300)
        #expect(
            gridThumbnailBucket(frame: tall, columnWidth: 100, scale: 2)
                == thumbnailPixelBucket(pointLongSide: 300, scale: 2))
    }

    @Test("a nil frame falls back to the solved column width")
    func nilFrameFallsBackToColumnWidth() {
        #expect(
            gridThumbnailBucket(frame: nil, columnWidth: 120, scale: 2)
                == thumbnailPixelBucket(pointLongSide: 120, scale: 2))
    }

    @Test("caps at the 512 on-disk tier ceiling")
    func capsAtTier() {
        let huge = CGRect(x: 0, y: 0, width: 4000, height: 100)
        #expect(gridThumbnailBucket(frame: huge, columnWidth: 4000, scale: 2) == 512)
    }
}

// MARK: - Accessibility label (shared pure function)

@Suite("Grid host: accessibility label")
struct GridCellAccessibilityLabelTests {

    @Test("kind names map to human words")
    func kinds() {
        #expect(gridCellAccessibilityLabel(for: detail(kind: .image)) == "Image")
        #expect(gridCellAccessibilityLabel(for: detail(kind: .video)) == "Video")
        #expect(gridCellAccessibilityLabel(for: detail(kind: .tweet)) == "Tweet")
        #expect(gridCellAccessibilityLabel(for: detail(kind: .link)) == "Link")
        #expect(gridCellAccessibilityLabel(for: detail(kind: .color)) == "Color")
    }

    @Test("a title wins over the handle and the bare kind")
    func titlePreferred() {
        let d = detail(kind: .link, title: "Hello World", authorHandle: "@someone")
        #expect(gridCellAccessibilityLabel(for: d) == "Link, Hello World")
    }

    @Test("a whitespace-only title is ignored, falling through to the handle")
    func blankTitleFallsThrough() {
        let d = detail(kind: .tweet, title: "   ", authorHandle: "@ndreas")
        #expect(gridCellAccessibilityLabel(for: d) == "Tweet by @ndreas")
    }

    @Test("no title and no handle is the bare kind")
    func bareKind() {
        #expect(gridCellAccessibilityLabel(for: detail(kind: .image)) == "Image")
    }
}
