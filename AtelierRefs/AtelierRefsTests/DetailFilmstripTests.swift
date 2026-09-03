//
//  DetailFilmstripTests.swift
//  AtelierRefsTests
//
//  041 · "Bottom — centered 5-thumbnail filmstrip", deferred there and built by
//  099 · P9 — pinned as pure functions in the shape `DetailStepTests`,
//  `DetailFanPileTests` and `DetailFanSpreadTests` set: runs in, a decision out,
//  no view.
//
//  The strip's window is the same centre-and-clamp arithmetic the spread's is, and
//  `detailFilmstripWindow` delegates to it rather than restating it. These tests do
//  NOT therefore duplicate `FanSpreadWindowTests`: they assert the properties the
//  STRIP depends on at the strip's own cap over RUN-sized inputs — thousands of
//  items, where a post is a handful — because the delegation is an implementation
//  choice and the properties are the contract. If the strip ever grows its own
//  arithmetic, these are what must keep passing.
//
//  The load-bearing one is `currentIsAlwaysInside`. A window that failed it would
//  draw the user five neighbours of an item they are not standing on, which is
//  worse than drawing no strip at all — and the last two items of a folder are
//  exactly where a naive `0..<cap` gets it wrong.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - The window

@Suite("Detail page: which neighbours the filmstrip draws (041)")
struct DetailFilmstripWindowTests {

    /// The cap the page actually uses, so a retune is a test failure rather than a
    /// silent change of behaviour.
    private let cap = DetailFilmstripMetrics.cap

    @Test("041's number: the strip draws five")
    func capIsFive() {
        #expect(DetailFilmstripMetrics.cap == 5)
    }

    @Test("the cap is odd, so the open item sits centred except at the ends")
    func capIsOdd() {
        #expect(DetailFilmstripMetrics.cap % 2 == 1)
    }

    @Test("a run shorter than the cap draws every item", arguments: [2, 3, 4, 5])
    func shortRunDrawsEverything(count: Int) {
        #expect(detailFilmstripWindow(count: count, currentIndex: 0, cap: cap)
            == Array(0..<count))
    }

    @Test("a run past the cap draws exactly the cap", arguments: [6, 60, 4000])
    func longRunDrawsTheCap(count: Int) {
        #expect(detailFilmstripWindow(count: count, currentIndex: 0, cap: cap).count == cap)
    }

    /// **The load-bearing test.** Wherever the run has walked to, the strip must hold
    /// the item the page is showing.
    @Test(
        "the open item is inside the window at every position",
        arguments: [1, 2, 5, 6, 60])
    func currentIsAlwaysInside(count: Int) {
        for current in 0..<count {
            let window = detailFilmstripWindow(
                count: count, currentIndex: current, cap: cap)
            #expect(
                window.contains(current),
                "item \(current) of \(count) fell outside \(window)")
        }
    }

    /// A FOLDER-sized run, which is the difference between this strip and the spread:
    /// a post is a handful of members, a collection is thousands, and the window must
    /// hold at every one of them without materialising the run.
    @Test("the open item is inside the window across a folder-sized run")
    func currentIsInsideAtScale() {
        let count = 4000
        for current in stride(from: 0, to: count, by: 7) {
            #expect(detailFilmstripWindow(count: count, currentIndex: current, cap: cap)
                .contains(current))
        }
        // The two ends explicitly — where a naive window fails.
        #expect(detailFilmstripWindow(count: count, currentIndex: 0, cap: cap).contains(0))
        #expect(detailFilmstripWindow(count: count, currentIndex: count - 1, cap: cap)
            .contains(count - 1))
    }

    @Test("walking to the tail slides the window rather than leaving it at the head")
    func tailSlidesTheWindow() {
        #expect(detailFilmstripWindow(count: 60, currentIndex: 59, cap: cap)
            == [55, 56, 57, 58, 59])
    }

    @Test("the window is contiguous and in run order, never a sample")
    func windowIsContiguous() {
        for current in 0..<60 {
            let window = detailFilmstripWindow(count: 60, currentIndex: current, cap: cap)
            #expect(window == Array(window.sorted()))
            for (a, b) in zip(window, window.dropFirst()) { #expect(b == a + 1) }
        }
    }

    @Test("the window never runs off either end")
    func windowStaysInBounds() {
        for count in [1, 2, 5, 6, 37] {
            for current in 0..<count {
                let window = detailFilmstripWindow(
                    count: count, currentIndex: current, cap: cap)
                #expect(window.allSatisfy { (0..<count).contains($0) })
            }
        }
    }

    /// The strip is drawn from a `count` read one body pass earlier, so a reload that
    /// shrinks the run can hand it a stale position — the same hazard 080 §5 · T4.2
    /// records for the spread.
    @Test("a stale index past the end of a shrunken run still yields a usable window")
    func staleIndexIsClamped() {
        let window = detailFilmstripWindow(count: 3, currentIndex: 40, cap: cap)
        #expect(window == [0, 1, 2])
    }

    @Test("a negative index clamps to the head rather than producing a negative range")
    func negativeIndexClamps() {
        #expect(detailFilmstripWindow(count: 10, currentIndex: -5, cap: cap) == [0, 1, 2, 3, 4])
    }

    @Test("an empty run yields nothing to draw, not a crash")
    func emptyRunDrawsNothing() {
        #expect(detailFilmstripWindow(count: 0, currentIndex: 0, cap: cap).isEmpty)
        #expect(detailFilmstripWindow(count: -3, currentIndex: 0, cap: cap).isEmpty)
        #expect(detailFilmstripWindow(count: 10, currentIndex: 0, cap: 0).isEmpty)
    }

    @Test("a run of one is its own window — the view then hides the strip entirely")
    func singleRun() {
        #expect(detailFilmstripWindow(count: 1, currentIndex: 0, cap: cap) == [0])
    }
}

// MARK: - The decode bucket

@Suite("Detail page: the filmstrip sizes its own decode (036 §4 C3)")
struct DetailFilmstripBucketTests {

    /// `AsyncThumbnail.bucket` defaults to the 512 ceiling and the pipeline requires
    /// the caller to size itself. A 48pt thumb on a 2× display needs 96px, which snaps
    /// to the ladder's bottom rung (128) — taking the default would decode sixteen
    /// times the bitmap, five times over, on every step through a cold folder.
    @Test("a thumbnail decodes at the small tier, never the 512 default",
          arguments: [1.0, 2.0])
    func bucketMatchesTheThumb(scale: Double) {
        let bucket = DetailFilmstripMetrics.bucket(scale: CGFloat(scale))
        #expect(bucket < thumbnailPixelBuckets[thumbnailPixelBuckets.count - 1])
        // Never UNDER the thumb's pixels either — the pipeline snaps up, so a
        // thumbnail is never upscaled at draw.
        #expect(CGFloat(bucket)
            >= DetailFilmstripMetrics.thumbSide * CGFloat(max(scale, 1)))
    }

    /// The strip is chrome under the picture, not a transient the user reaches for, so
    /// it must not cost more than the spread's cards do.
    @Test("a strip thumbnail is no larger than a spread card")
    func thumbIsNoLargerThanASpreadCard() {
        #expect(DetailFilmstripMetrics.thumbSide <= DetailFanSpreadMetrics.cardSide)
    }

    /// The strip is a ROW and the spread is a fanned deck — the spread's cards overlap
    /// (`cardSpacing < cardSide`) and these must not, or the strip would be saying
    /// "post" where it means "folder".
    @Test("the strip's thumbnails do not overlap, unlike the spread's cards")
    func stripDoesNotOverlap() {
        #expect(DetailFilmstripMetrics.spacing > 0)
        #expect(DetailFanSpreadMetrics.cardSpacing < DetailFanSpreadMetrics.cardSide)
    }
}

// MARK: - The host contract

@Suite("Detail page: the filmstrip's artwork lookup (041)")
struct DetailFilmstripArtworkTests {

    /// The strip's window is derived from a `count` the host reported one body pass
    /// earlier, so `blobHash` WILL be asked for positions that no longer exist. Both
    /// real hosts bounds-check inside the closure; this pins that the contract permits
    /// it — `nil` is a placeholder slot, never a trap.
    @Test("an out-of-range position yields nil rather than trapping")
    func outOfRangeIsNil() {
        let run = ["a", "b", "c"]
        let strip = ItemDetailFilmstrip(
            blobHash: { run.indices.contains($0) ? run[$0] : nil },
            thumbnailURL: { _ in nil })
        #expect(strip.blobHash(1) == "b")
        #expect(strip.blobHash(9) == nil)
        #expect(strip.blobHash(-1) == nil)
    }

    /// A media-less item (003 · O1) is a SLOT, not a gap: it is real, it is counted by
    /// the pager, and the arrows step onto it — so the strip draws a placeholder for
    /// it rather than closing the row up, which would misalign every thumbnail after
    /// it with the position it claims to be.
    @Test("a media-less item is a slot, and the window still counts it")
    func mediaLessItemKeepsItsSlot() {
        let run: [String?] = ["a", nil, "c", "d", "e", "f"]
        let strip = ItemDetailFilmstrip(
            blobHash: { run.indices.contains($0) ? run[$0] : nil },
            thumbnailURL: { _ in nil })
        let window = detailFilmstripWindow(
            count: run.count, currentIndex: 2, cap: DetailFilmstripMetrics.cap)
        #expect(window == [0, 1, 2, 3, 4])
        #expect(strip.blobHash(1) == nil)
        // The slot is still in the window — not skipped over.
        #expect(window.contains(1))
    }

    /// The strip's click goes through the navigator's OWN `step`, by delta, so it can
    /// only reach where the arrows can. The current item is a no-op rather than a
    /// zero-delta step, which would re-present the same picture and bump its view
    /// count for a click that asked for nothing.
    @Test("a click on a neighbour steps by the delta; a click on the open item does not")
    func clickStepsByDelta() {
        var deltas: [Int] = []
        let navigator = ItemDetailNavigator(
            index: 7, count: 60, step: { deltas.append($0) })
        // What `DetailFilmstrip.thumb` computes for each drawn position.
        for position in detailFilmstripWindow(
            count: navigator.count, currentIndex: navigator.index,
            cap: DetailFilmstripMetrics.cap) {
            guard position != navigator.index else { continue }
            navigator.step(position - navigator.index)
        }
        #expect(deltas == [-2, -1, 1, 2])
    }

    /// A host that wires no artwork gets today's page. The strip is removed, not
    /// degraded to a row of grey squares.
    @Test("a navigator with no filmstrip leaves the page as it was")
    func navigatorWithoutAFilmstrip() {
        let navigator = ItemDetailNavigator(index: 0, count: 9, step: { _ in })
        #expect(navigator.filmstrip == nil)
    }
}
