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

    private func fixtureDetail() -> CollectionItemDetail {
        let sourceID = UUID(), assetID = UUID()
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
            asset: Asset(
                id: assetID, kind: .image, blobHash: nil, mimeType: nil,
                width: 100, height: 100, fileSize: nil, downloadState: .downloaded,
                createdAt: Date(), sourceId: sourceID),
            source: Source(
                id: sourceID, platform: .instagram,
                originalURL: "https://www.instagram.com/p/AbCd/", capturedAt: Date()))
    }

    private func laidOutCell(
        postMemberCount: Int, postExpanded: Bool = false, isPostLead: Bool = true
    ) -> MasonryGridItem {
        let cell = MasonryGridItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        cell.configure(
            detail: fixtureDetail(), url: nil, bucket: 256, gifURL: nil,
            postMemberCount: postMemberCount, postExpanded: postExpanded,
            isPostLead: isPostLead)
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

    /// The chip is what toggles a post open and closed, so it must sit in the SAME
    /// spot in both states — anchored to the tile's corner, not the fan-inset
    /// content rect. Anchored to the content rect it moved diagonally by the fan
    /// inset (~11pt on a square tile, roughly its own height) on every toggle,
    /// sliding out from under a cursor parked on it.
    @Test("the chip pins to the tile corner in BOTH states — a toggle never moves it")
    func chipDoesNotMoveOnToggle() throws {
        let collapsed = try #require(badgeLayer(laidOutCell(postMemberCount: 3)))
        let expanded = try #require(
            badgeLayer(laidOutCell(postMemberCount: 3, postExpanded: true)))
        #expect(collapsed.frame == expanded.frame)
        #expect(collapsed.frame.minX == PostBadge.inset)
        #expect(collapsed.frame.minY == PostBadge.inset)
    }

    /// `setPostMemberCount` places the chip too (a reconfigure at an unchanged
    /// size never re-enters `viewDidLayout`), so its placement must agree with the
    /// layout pass — one shared path, or a collapsed tile's hit rect drifts from
    /// the drawn capsule until the next relayout.
    @Test("a reconfigure without a relayout places the chip where layout would")
    func reconfigureAgreesWithLayout() throws {
        let cell = laidOutCell(postMemberCount: 3)
        let placed = try #require(badgeLayer(cell)).frame
        // Reconfigure only — no `layoutSubtreeIfNeeded`, mirroring a live-cell
        // reconfigure between layout passes.
        cell.configure(
            detail: fixtureDetail(), url: nil, bucket: 256, gifURL: nil,
            postMemberCount: 3, postExpanded: false, isPostLead: true)
        #expect(try #require(badgeLayer(cell)).frame == placed)
    }

    private func badgeLayer(_ cell: MasonryGridItem) -> CALayer? {
        cell.view.layer?.sublayers?.first { $0.contents != nil && !$0.isHidden }
    }

    // MARK: - Chip hit-testing from ANALYTIC geometry (311)

    /// The click path resolves the chip from the LAYOUT's frame plus the model,
    /// never from the cell's layer. Measured cause: AppKit hands a press to
    /// whichever cell view its own hit-test lands on, and across the reflow of a
    /// previous click that is a RECYCLED cell which has already moved — a press
    /// over the open lead's chip arrived at a member cell 200pt away (the point
    /// converting to `(-179, -259)`, outside its bounds), whose chip is correctly
    /// hidden, so it fell through and opened THAT member. These pin the pure rules
    /// the coordinator now uses instead.
    @Test("the analytic chip rect is exactly where the cell draws the chip")
    func analyticRectMatchesDrawnChip() throws {
        let cell = laidOutCell(postMemberCount: 3)
        let drawn = try #require(badgeLayer(cell)).frame
        // This fixture's tile sits at the origin, so its analytic frame is its bounds.
        let analytic = try #require(
            gridBadgeRect(
                inTile: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
                memberCount: 3))
        #expect(analytic == drawn)
    }

    /// The rect must track the TILE's origin, or the chip zone of a tile halfway
    /// down the grid would be tested against the grid's top-left corner.
    @Test("the analytic chip rect is relative to the tile, not the grid")
    func analyticRectFollowsTheTile() throws {
        let tile = CGRect(x: 440, y: 330, width: 200, height: 267)
        let rect = try #require(gridBadgeRect(inTile: tile, memberCount: 3))
        #expect(rect.minX == tile.minX + PostBadge.inset)
        #expect(rect.minY == tile.minY + PostBadge.inset)
    }

    @Test("a lone tile has no chip rect, so no press can read as a chip")
    func loneTileHasNoRect() {
        let tile = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(gridBadgeRect(inTile: tile, memberCount: 1) == nil)
        #expect(gridBadgeRect(inTile: tile, memberCount: 0) == nil)
    }

    /// The coordinator's copy of `showsPostChip`: a COLLAPSED post always chips, an
    /// OPEN one chips on its lead only (309).
    @Test("the chip-bearing rule matches what the cell draws", arguments: [
        (3, false, true, true),     // collapsed lead
        (3, false, false, true),    // collapsed non-lead (a collapsed feed shows only leads)
        (3, true, true, true),      // open lead — the close affordance
        (3, true, false, false),    // open member — no chip
        (1, false, true, false),    // lone item
        (0, false, true, false),
    ])
    func chipRule(count: Int, expanded: Bool, lead: Bool, expected: Bool) {
        #expect(
            gridTileShowsChip(memberCount: count, isExpanded: expanded, isLead: lead) == expected)
    }

    /// The regression this change exists for: a press on an OPEN lead's chip must
    /// read as the chip no matter which cell AppKit dispatched it to.
    @Test("a press on an OPEN lead's chip is a chip hit")
    func openLeadChipZoneHits() {
        let tile = CGRect(x: 232, y: 55, width: 200, height: 267)
        let inChip = CGPoint(x: tile.minX + PostBadge.inset + 4, y: tile.minY + PostBadge.inset + 4)
        #expect(
            gridBadgeZoneHit(
                point: inChip, tileFrame: tile, memberCount: 8,
                isExpanded: true, isLead: true))
        // The middle of that same tile is NOT the chip — that press still selects.
        #expect(
            !gridBadgeZoneHit(
                point: CGPoint(x: tile.midX, y: tile.midY), tileFrame: tile,
                memberCount: 8, isExpanded: true, isLead: true))
    }

    @Test("an OPEN post's member has no chip zone anywhere in its tile")
    func openMemberHasNoZone() {
        let tile = CGRect(x: 440, y: 330, width: 200, height: 267)
        let corner = CGPoint(x: tile.minX + PostBadge.inset + 4, y: tile.minY + PostBadge.inset + 4)
        #expect(
            !gridBadgeZoneHit(
                point: corner, tileFrame: tile, memberCount: 8,
                isExpanded: true, isLead: false))
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

    @Test("an OPENED post's LEAD keeps its chip but loses the pile")
    func openedPostDropsTheFan() {
        let cell = laidOutCell(postMemberCount: 3, postExpanded: true)
        // Nothing is hidden behind it any more, so it stands for nothing...
        #expect(fanCards(cell).isEmpty)
        #expect(artwork(cell)?.frame.width == Self.side)
        // ...but the chip stays, because it is what closes the post again.
        #expect(chipPainted(cell))
    }

    @Test("an OPENED post's other members draw NO chip (309)")
    func openedMembersDropTheChip() {
        // Since 309 an open post's members sit as one contiguous run, so a chip on
        // each would be N identical badges over what reads as a single block. Only
        // the lead — where the collapsed tile stood — carries the close affordance.
        let cell = laidOutCell(postMemberCount: 3, postExpanded: true, isPostLead: false)
        #expect(!chipPainted(cell))
        #expect(fanCards(cell).isEmpty)
    }

    @Test("a COLLAPSED post chips regardless of lead-ness")
    func collapsedAlwaysChips() {
        // `isPostLead` gates the chip only while the post is open. A collapsed feed
        // only ever configures the lead anyway, so a `false` here must not be able
        // to produce a chipless tile standing for a hidden post.
        #expect(chipPainted(laidOutCell(postMemberCount: 3, isPostLead: false)))
    }

    /// Whether any visible layer carries painted contents — the chip, since these
    /// fixtures have no artwork (`blobHash: nil`) and the fan cards draw with
    /// borders rather than contents.
    private func chipPainted(_ cell: MasonryGridItem) -> Bool {
        cell.view.layer?.sublayers?.contains { $0.contents != nil && !$0.isHidden } == true
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
