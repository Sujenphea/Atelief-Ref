//
//  DetailFanSpreadTests.swift
//  AtelierRefsTests
//
//  080 §3.5 / §5 — the spread, pinned as pure functions in the shape `DetailStepTests`
//  and `DetailFanPileTests` set: runs in, a decision out, no view.
//
//  The arc is where this increment's off-by-ones live. `fanSpreadWindow` answers WHICH
//  members are drawn and how many are not, and the load-bearing property is not "seven
//  cards" but "the open item is always one of them" — a window that failed that would
//  show the user a slice of a post they are not standing in, which is worse than showing
//  no spread at all.
//
//  T4.2 / T4.3 sit here too (080 §5 · T4): the spread is the first thing that captures a
//  member index and acts on it LATER, so it is the first thing a reload can catch out.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - The arc window

@Suite("Detail page: which members the spread draws (080 §3.5)")
struct FanSpreadWindowTests {

    /// The cap the page actually uses, so a retune here is a test failure rather than a
    /// silent change of behaviour.
    private let cap = DetailFanSpreadMetrics.cap

    @Test("a post that fits draws every member and no +N", arguments: [2, 3, 5, 7])
    func shortPostDrawsEverything(memberCount: Int) {
        let window = fanSpreadWindow(memberCount: memberCount, currentIndex: 0, cap: cap)
        #expect(window.indices == Array(0..<memberCount))
        #expect(window.hidden == 0)
    }

    @Test("a post past the cap draws the cap and says how many it did not")
    func longPostReportsTheRemainder() {
        let window = fanSpreadWindow(memberCount: 15, currentIndex: 0, cap: cap)
        #expect(window.indices.count == cap)
        #expect(window.hidden == 15 - cap)   // the "+8"
    }

    /// **The load-bearing test.** Wherever the run has walked to, the spread has to
    /// contain the item the page is showing — otherwise it is a slice of somebody else's
    /// position. The end of a long post is where a naive `0..<cap` window fails.
    @Test(
        "the open item is inside the window at every position",
        arguments: [3, 7, 15, 40])
    func currentIsAlwaysInside(memberCount: Int) {
        for current in 0..<memberCount {
            let window = fanSpreadWindow(
                memberCount: memberCount, currentIndex: current, cap: cap)
            #expect(
                window.indices.contains(current),
                "member \(current) of \(memberCount) fell outside \(window.indices)")
        }
    }

    /// Image 12 of 15 with a cap of 7 — 080 §5's named case. A window left at `0…6`
    /// would draw seven cards none of which is the one on screen.
    @Test("walking to the tail slides the window rather than leaving it at the head")
    func tailSlidesTheWindow() {
        let window = fanSpreadWindow(memberCount: 15, currentIndex: 11, cap: 7)
        #expect(window.indices == [8, 9, 10, 11, 12, 13, 14])
        #expect(window.hidden == 8)
    }

    @Test("the window is contiguous and in post order, never a sample")
    func windowIsContiguous() {
        for current in 0..<15 {
            let indices = fanSpreadWindow(
                memberCount: 15, currentIndex: current, cap: cap).indices
            #expect(indices == Array(indices.sorted()))
            for (a, b) in zip(indices, indices.dropFirst()) { #expect(b == a + 1) }
        }
    }

    @Test("the window never runs off either end")
    func windowStaysInBounds() {
        for current in 0..<15 {
            let indices = fanSpreadWindow(
                memberCount: 15, currentIndex: current, cap: cap).indices
            #expect(indices.first ?? 0 >= 0)
            #expect(indices.last ?? 0 <= 14)
        }
    }

    /// **T4.2 — the index shift.** `detailRunIndexByItem` is rebuilt on every reload
    /// (`IngestionModel.swift:559-560`), so a spread drawn before a delete can be asked
    /// for a window with an index that no longer exists. It must clamp, not trap.
    @Test("a stale index past the end of a shrunken post still yields a usable window")
    func staleIndexAfterRebuild() {
        // Drawn when the post had 15 members; a delete has since taken it to 4.
        let window = fanSpreadWindow(memberCount: 4, currentIndex: 12, cap: cap)
        #expect(window.indices == [0, 1, 2, 3])
        #expect(window.hidden == 0)
    }

    @Test("a negative index clamps to the head rather than producing a negative range")
    func negativeIndexClamps() {
        let window = fanSpreadWindow(memberCount: 15, currentIndex: -3, cap: cap)
        #expect(window.indices == Array(0..<cap))
    }

    @Test("degenerate inputs yield nothing to draw, not a crash")
    func degenerateInputs() {
        #expect(fanSpreadWindow(memberCount: 0, currentIndex: 0, cap: 7).indices.isEmpty)
        #expect(fanSpreadWindow(memberCount: 5, currentIndex: 0, cap: 0).indices.isEmpty)
        #expect(fanSpreadWindow(memberCount: -1, currentIndex: 0, cap: 7).indices.isEmpty)
    }

    /// A cap of one is the degenerate arc — still the open item, never a neighbour.
    @Test("a cap of one draws the open item alone")
    func capOfOne() {
        let window = fanSpreadWindow(memberCount: 15, currentIndex: 9, cap: 1)
        #expect(window.indices == [9])
        #expect(window.hidden == 14)
    }
}

// MARK: - T4.3 · the jump clamps in the callee

@Suite("Detail page: the spread's jump is clamped by the callee (080 §5 · T4.3)")
struct FanSpreadJumpTests {

    private static let url = "https://example.com/p/AAA"

    /// One member of a post, built from its OWN `Source` row as the ingest funnel writes
    /// them. File-private and duplicated from `DetailPostTests` on purpose: every test
    /// file in this target keeps its own `item(...)`, and hoisting one to module scope
    /// would collide with the nine others that share the name.
    private func item(carouselIndex: Int, blobHash: String?) -> CollectionItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(
            id: sourceID, platform: .instagram, originalURL: Self.url, capturedAt: Date(),
            rawMetadata: .object(["carouselIndex": .number(Double(carouselIndex))]))
        let asset = Asset(
            id: assetID, kind: blobHash == nil ? .tweet : .image, blobHash: blobHash,
            mimeType: blobHash == nil ? nil : "image/jpeg",
            width: blobHash == nil ? nil : 100, height: blobHash == nil ? nil : 100,
            fileSize: blobHash == nil ? nil : 100, downloadState: .downloaded,
            createdAt: Date(), sourceId: sourceID)
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
            asset: asset, source: source)
    }

    /// The contract `ItemDetailPost.jump` documents: the CALLEE clamps. The spread draws a
    /// card for member `k` and the click can land after a reload has shrunk the post, so a
    /// caller-side guard would be checking a number that was already stale when it read it.
    @Test("a jump past the end of a shrunken post is clamped, not dropped or trapped")
    func jumpClampsInTheCallee() throws {
        let members = (0..<4).map { item(carouselIndex: $0, blobHash: "h\($0)") }
        let groups = PostGroups(items: members)

        var landed: [Int] = []
        let post = try #require(groups.detailPost(
            forItem: members[0].item.id,
            thumbnailURL: { _ in nil },
            // The host's clamp, which is what the real hosts install.
            jump: { landed.append(min(max($0, 0), 3)) }))

        post.jump(12)   // a card drawn when the post was longer
        post.jump(-4)
        post.jump(2)
        #expect(landed == [3, 0, 2])
    }
}

// MARK: - The decode bucket

@Suite("Detail page: the spread sizes its own decode (080 §3.5)")
struct FanSpreadBucketTests {

    /// `AsyncThumbnail.bucket` defaults to the 512 ceiling and the pipeline requires the
    /// caller to size itself. A 64pt card on a 2× display needs 128px — taking the default
    /// would decode sixteen times the pixels it can show, per card, on every cold spread.
    @Test("a card decodes at the small tier, never the 512 default", arguments: [1.0, 2.0])
    func bucketMatchesTheCard(scale: Double) {
        let bucket = DetailFanSpreadMetrics.bucket(scale: CGFloat(scale))
        #expect(bucket < thumbnailPixelBuckets[thumbnailPixelBuckets.count - 1])
        // Never UNDER the card's pixels either — the pipeline snaps up so a card is
        // never upscaled at draw.
        #expect(CGFloat(bucket) >= DetailFanSpreadMetrics.cardSide * CGFloat(max(scale, 1)))
    }

    @Test("the cap is odd, so the open item sits centred except at the ends")
    func capIsOdd() {
        #expect(DetailFanSpreadMetrics.cap % 2 == 1)
    }
}

// MARK: - Dragging along the arc

/// Drag-to-scrub: the pointer's x, in the arc's own space, becomes the card it is over.
///
/// The cards OVERLAP — `cardSpacing` (52) is narrower than `cardSide` (64), which is what
/// makes the arc read as a fanned deck rather than a row — so "the card under the pointer"
/// is a slot at the spacing's pitch, not a hit test against a card's drawn bounds. Those
/// two answers differ for every pointer position in an overlap, which is most of them.
@Suite("Detail page: dragging along the arc picks a card")
struct FanSpreadScrubTests {

    private let pitch = DetailFanSpreadMetrics.cardSpacing

    @Test("each slot's own span maps to that slot")
    func slotsMapToThemselves() {
        for slot in 0..<7 {
            let mid = CGFloat(slot) * pitch + pitch / 2
            #expect(fanSpreadScrubSlot(x: mid, pitch: pitch, count: 7) == slot)
        }
    }

    /// The property that matters for a scrub: dragging one way never steps back. A
    /// non-monotonic mapping would make the raise stutter under a steady drag.
    @Test("the mapping is monotonic across the whole arc")
    func mappingIsMonotonic() {
        var last = -1
        for step in 0...(7 * 52) {
            let slot = fanSpreadScrubSlot(x: CGFloat(step), pitch: pitch, count: 7)
            let value = try! #require(slot)
            #expect(value >= last)
            last = value
        }
    }

    /// Running off either end holds the end card, the way a scrubber holds its end,
    /// rather than blinking out or wrapping to the other side of the post.
    @Test("a drag past either end holds the end card")
    func endsClamp() {
        #expect(fanSpreadScrubSlot(x: -500, pitch: pitch, count: 7) == 0)
        #expect(fanSpreadScrubSlot(x: 99_999, pitch: pitch, count: 7) == 6)
    }

    @Test("a shorter arc clamps to its own last card, not the cap")
    func shortArcClampsToItsOwnEnd() {
        #expect(fanSpreadScrubSlot(x: 99_999, pitch: pitch, count: 3) == 2)
    }

    @Test("degenerate inputs yield no slot rather than a crash")
    func degenerateInputs() {
        #expect(fanSpreadScrubSlot(x: 10, pitch: pitch, count: 0) == nil)
        #expect(fanSpreadScrubSlot(x: 10, pitch: 0, count: 7) == nil)
        #expect(fanSpreadScrubSlot(x: .nan, pitch: pitch, count: 7) == nil)
        #expect(fanSpreadScrubSlot(x: .infinity, pitch: pitch, count: 7) == nil)
    }

    /// A slot is an index into the WINDOW, not a member of the post — the two differ by
    /// the window's start for any post past the cap, and conflating them would scrub to
    /// the wrong image on exactly the long posts the spread exists for.
    @Test("a slot resolves through the window to the right member")
    func slotResolvesThroughTheWindow() {
        let window = fanSpreadWindow(memberCount: 15, currentIndex: 11, cap: 7)
        #expect(window.indices == [8, 9, 10, 11, 12, 13, 14])

        let firstSlot = try! #require(
            fanSpreadScrubSlot(x: pitch / 2, pitch: pitch, count: window.indices.count))
        #expect(window.indices[firstSlot] == 8)   // NOT 0

        let lastSlot = try! #require(
            fanSpreadScrubSlot(x: 6 * pitch + pitch / 2, pitch: pitch,
                               count: window.indices.count))
        #expect(window.indices[lastSlot] == 14)   // NOT 6
    }
}

// MARK: - Where the hover zone sits

/// The zone that opens the spread has to sit on the ARTWORK's bottom edge, not the pane's
/// and not the picture's middle.
///
/// This suite exists because the first version used the letterbox gap
/// (`(paneHeight − fittedHeight) / 2`) instead of `(fittedHeight − zoneHeight) / 2`. Both
/// compile, both are plausibly "how the picture sits in the pane", and the wrong one is
/// invisible on a letterboxed image and dead centre on one that fills its pane.
@Suite("Detail page: the spread's hover zone sits on the artwork's bottom edge")
struct FanSpreadZoneTests {

    /// The invariant, stated in pane coordinates: the bottom of the zone and the bottom of
    /// the artwork are the same line, whatever the letterboxing.
    @Test(
        "the zone's bottom edge is the artwork's bottom edge",
        arguments: [
            (pane: 900.0, fitted: 900.0),   // fills the pane — the case that regressed
            (pane: 900.0, fitted: 600.0),   // letterboxed
            (pane: 900.0, fitted: 120.0),   // a wide panorama in a tall pane
            (pane: 400.0, fitted: 60.0),    // shorter than the zone
        ])
    func zoneBottomMeetsArtworkBottom(pane: Double, fitted: Double) {
        let paneHeight = CGFloat(pane), fittedHeight = CGFloat(fitted)
        let zoneHeight = min(fittedHeight, DetailFanSpreadMetrics.hoverZoneHeight)
        let offset = fanSpreadZoneOffset(
            fittedHeight: fittedHeight, zoneHeight: zoneHeight)

        // Both are centred on the pane, so measure from that shared centre.
        let artworkBottom = fittedHeight / 2
        let zoneBottom = offset + zoneHeight / 2
        #expect(abs(zoneBottom - artworkBottom) < 0.001)

        // And the zone never climbs above the artwork's top edge.
        #expect(offset - zoneHeight / 2 >= -fittedHeight / 2 - 0.001)
        _ = paneHeight   // the answer must NOT depend on the pane — see the suite's note
    }

    /// The regression, named. A picture that fills its pane has no letterbox gap, so the
    /// old expression returned 0 and put the arc over the middle of the image.
    @Test("a picture that fills its pane still pushes the zone to the bottom")
    func fullBleedPictureIsNotCentred() {
        let fittedHeight: CGFloat = 900
        let zoneHeight = min(fittedHeight, DetailFanSpreadMetrics.hoverZoneHeight)
        let offset = fanSpreadZoneOffset(fittedHeight: fittedHeight, zoneHeight: zoneHeight)
        #expect(offset > 0)
        #expect(offset == (900 - zoneHeight) / 2)
    }

    /// An artwork shorter than the zone gets a zone its own height, which then needs no
    /// push at all — the two rectangles already share a bottom edge.
    @Test("an artwork shorter than the zone needs no offset")
    func shortArtworkNeedsNoOffset() {
        let fittedHeight: CGFloat = 60
        let zoneHeight = min(fittedHeight, DetailFanSpreadMetrics.hoverZoneHeight)
        #expect(zoneHeight == fittedHeight)
        #expect(fanSpreadZoneOffset(fittedHeight: fittedHeight, zoneHeight: zoneHeight) == 0)
    }
}
