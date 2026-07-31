//
//  MasonryGridItemBadgeTests.swift
//  AtelierRefsTests
//
//  307 · carousel grouping — where the carousel chip actually lands.
//
//  The cell's container is FLIPPED (`FlippedContentView.isFlipped`), and the chip
//  is a `CALayer` rather than a subview, so "top-leading" depends on whether the
//  backing layer's sublayer coordinate space is flipped along with the view. Get
//  that wrong and the badge silently renders in the BOTTOM-left corner — a bug no
//  amount of reading the frame arithmetic reveals, and one the pure grouping tests
//  can't see. This pins the layer geometry and the corner together.
//

import AppKit
import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Carousel chip placement")
struct MasonryGridItemBadgeTests {

    private static let side: CGFloat = 200

    private func laidOutCell(postMemberCount: Int) -> MasonryGridItem {
        let cell = MasonryGridItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let sourceID = UUID(), assetID = UUID()
        let detail = CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
            asset: Asset(
                id: assetID, kind: .image, blobHash: nil, mimeType: nil,
                width: 100, height: 100, fileSize: nil, downloadState: .downloaded,
                createdAt: Date(), sourceId: sourceID),
            source: Source(
                id: sourceID, platform: .instagram,
                originalURL: "https://www.instagram.com/p/AbCd/", capturedAt: Date()))
        cell.configure(
            detail: detail, url: nil, bucket: 256, gifURL: nil,
            postMemberCount: postMemberCount)
        cell.view.layoutSubtreeIfNeeded()
        return cell
    }

    /// The sublayer coordinate space the chip's frame is expressed in. If this is
    /// flipped (as the view is), a small `y` is the TOP; if AppKit ever stops
    /// flipping it, the chip's placement math has to be inverted.
    @Test("the cell's backing layer shares the view's flipped geometry")
    func backingLayerIsGeometryFlipped() {
        let cell = laidOutCell(postMemberCount: 3)
        #expect(cell.view.isFlipped)
        #expect(cell.view.layer?.isGeometryFlipped == true)
    }

    @Test("the chip sits in the TOP-LEADING corner, clear of the selection circle")
    func chipIsTopLeading() {
        let cell = laidOutCell(postMemberCount: 3)
        guard let badge = cell.view.layer?.sublayers?.first(where: { $0.contents != nil })
        else {
            Issue.record("no badge layer was painted for a 3-member post")
            return
        }
        // Leading half (the circle owns top-trailing) and the top edge, in the
        // flipped space asserted above.
        #expect(badge.frame.maxX < Self.side / 2)
        #expect(badge.frame.minY < Self.side / 2)
        #expect(badge.frame.minY >= PostBadge.inset - 0.5)
        #expect(badge.isHidden == false)
    }

    @Test("a lone item paints no chip")
    func loneItemHasNoChip() {
        let cell = laidOutCell(postMemberCount: 0)
        let painted = cell.view.layer?.sublayers?.contains {
            $0.contents != nil && !$0.isHidden
        }
        #expect(painted != true)
    }

    @Test("reuse clears the chip so a recycled cell can't inherit one")
    func reuseClearsTheChip() {
        let cell = laidOutCell(postMemberCount: 4)
        cell.prepareForReuse()
        let painted = cell.view.layer?.sublayers?.contains {
            $0.contents != nil && !$0.isHidden
        }
        #expect(painted != true)
    }
}
