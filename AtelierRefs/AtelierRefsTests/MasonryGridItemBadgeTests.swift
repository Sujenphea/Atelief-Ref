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

    private func laidOutCell(postMemberCount: Int, postExpanded: Bool = false) -> MasonryGridItem {
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
            postMemberCount: postMemberCount, postExpanded: postExpanded)
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

    // MARK: - Pile geometry (307)

    /// The invariant that was WRONG with a fixed inset: a tilted card must still fit
    /// inside the cell, because the cell clips and the overflow scales with the
    /// OTHER dimension — so a tall tile at the same angle needs far more room than a
    /// square one. Checked across the aspect ratios a masonry grid really produces.
    /// Whether `point` is inside a rounded rect of `size` centred on the origin —
    /// the shape the cell actually clips to. Outside the straight edges the corner
    /// arc governs, which is why a bounding-box check is not enough.
    private func insideRounded(_ point: CGPoint, size: CGSize, radius: CGFloat) -> Bool {
        let dx = max(0, abs(point.x) - (size.width / 2 - radius))
        let dy = max(0, abs(point.y) - (size.height / 2 - radius))
        return dx * dx + dy * dy <= radius * radius + 0.01
    }

    /// The invariant a fixed inset got wrong twice over: a tilted card must fit the
    /// cell's ROUNDED rect. Checking the four rotated corners catches both the
    /// aspect-ratio overflow (a tall tile swings much further) and the corner radius
    /// shaving a card that only fits the straight edges.
    @Test("no card corner escapes the rounded cell, at any aspect ratio", arguments: [
        CGSize(width: 200, height: 200),    // square
        CGSize(width: 200, height: 400),    // tall portrait
        CGSize(width: 200, height: 900),    // the extreme a screenshot produces
        CGSize(width: 400, height: 120),    // wide banner
        CGSize(width: 90, height: 90),      // a dense zoom notch
    ])
    func pileNeverClips(size: CGSize) {
        let radius = Theme.Radius.tile
        let (inset, degrees) = fanPileGeometry(
            in: size, maxDegrees: 5, maxInset: 12, minInset: 5, cornerRadius: radius)
        let w = size.width - 2 * inset, h = size.height - 2 * inset
        #expect(w > 0 && h > 0)
        let t = CGFloat(degrees * .pi / 180)
        // The card's own corners, rotated about the shared centre.
        for sx in [CGFloat(-1), 1] {
            for sy in [CGFloat(-1), 1] {
                let x = sx * w / 2, y = sy * h / 2
                let rotated = CGPoint(
                    x: x * cos(t) - y * sin(t),
                    y: x * sin(t) + y * cos(t))
                #expect(insideRounded(rotated, size: size, radius: radius))
            }
        }
    }

    @Test("a tall tile trades tilt for inset rather than shrinking to nothing")
    func tallTileReducesTheTilt() {
        let square = fanPileGeometry(
            in: CGSize(width: 200, height: 200), maxDegrees: 5, maxInset: 12,
            minInset: 5, cornerRadius: Theme.Radius.tile)
        let tall = fanPileGeometry(
            in: CGSize(width: 200, height: 900), maxDegrees: 5, maxInset: 12,
            minInset: 5, cornerRadius: Theme.Radius.tile)
        // The square tile can afford the full tilt; the tall one cannot.
        #expect(square.degrees == 5)
        #expect(tall.degrees < square.degrees)
        // And the inset stays bounded instead of eating the image.
        #expect(tall.inset <= 16)
    }

    // MARK: - The fanned pile (307)

    /// The cards behind the artwork: the only visible sublayers carrying a 1pt
    /// border (the rings are 0 until selected, the contrast hairline starts hidden).
    private func fanCards(_ cell: MasonryGridItem) -> [CALayer] {
        (cell.view.layer?.sublayers ?? []).filter { $0.borderWidth == 1 && !$0.isHidden }
    }

    /// The artwork layer, told apart from the chip by its gravity (`resizeAspectFill`
    /// vs the chip's `resizeAspect`).
    private func artwork(_ cell: MasonryGridItem) -> CALayer? {
        (cell.view.layer?.sublayers ?? []).first { $0.contentsGravity == .resizeAspectFill }
    }

    @Test("a collapsed post draws two cards behind pulled-in artwork")
    func collapsedPostFans() {
        let cell = laidOutCell(postMemberCount: 3)
        #expect(fanCards(cell).count == 2)
        let art = try? #require(artwork(cell))
        // Inset on every side, so the tilted cards have room inside the clip.
        #expect((art?.frame.width ?? Self.side) < Self.side)
        #expect((art?.frame.minX ?? 0) > 0)
    }

    @Test("a lone item fills its cell and draws no pile")
    func loneItemHasNoFan() {
        let cell = laidOutCell(postMemberCount: 0)
        #expect(fanCards(cell).isEmpty)
        #expect(artwork(cell)?.frame.width == Self.side)
    }

    @Test("an OPENED post keeps its chip but loses the pile")
    func openedPostDropsTheFan() {
        let cell = laidOutCell(postMemberCount: 3, postExpanded: true)
        // Nothing is hidden behind it any more, so it stands for nothing...
        #expect(fanCards(cell).isEmpty)
        #expect(artwork(cell)?.frame.width == Self.side)
        // ...but the chip stays, because it is what closes the post again.
        let chip = cell.view.layer?.sublayers?.contains {
            $0.contents != nil && !$0.isHidden
        }
        #expect(chip == true)
    }

    @Test("reuse clears the pile as well as the chip")
    func reuseClearsTheFan() {
        let cell = laidOutCell(postMemberCount: 4)
        #expect(fanCards(cell).count == 2)
        cell.prepareForReuse()
        cell.view.layoutSubtreeIfNeeded()
        #expect(fanCards(cell).isEmpty)
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
