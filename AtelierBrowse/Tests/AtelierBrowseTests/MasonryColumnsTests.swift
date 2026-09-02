// AtelierBrowse tests — the decomposition 093 § 3 rests on.
//
// The claim being checked is not "these arrays look right". It is that `C` lazy column
// stacks reproduce the Mac's round-robin placement exactly, which is what lets the
// phone keep the library's rhythm without porting a solver or bridging a collection
// view. So the tests state the PROPERTY — column membership is `i % C`, reading the
// columns row by row replays the input, the count is always `C` — rather than pinning
// one fixture's output.

import Foundation
import Testing

import AtelierCore
@testable import AtelierBrowse

@Suite("MasonryColumns (093 §3)")
struct MasonryColumnsTests {

    // MARK: - Decomposition

    @Test("item i lands in column i % C — the property the whole design rests on")
    func roundRobinMembership() {
        for columns in 1 ... 5 {
            let indices = MasonryColumns.columnIndices(itemCount: 37, columns: columns)
            for (column, items) in indices.enumerated() {
                for index in items {
                    #expect(index % columns == column)
                }
            }
        }
    }

    @Test("a column is the stride subsequence, in ascending order")
    func columnIsStride() {
        let indices = MasonryColumns.columnIndices(itemCount: 10, columns: 3)
        #expect(indices[0] == [0, 3, 6, 9])
        #expect(indices[1] == [1, 4, 7])
        #expect(indices[2] == [2, 5, 8])
    }

    @Test("reading the columns row by row replays the input order")
    func readingOrderIsFeedOrder() {
        // Feed order == reading order is the reason `MasonryLayout` is round-robin at
        // all (`MasonryLayout.swift:6`–`:9`); if this fails the phone's grid is showing
        // the library in an order the Mac does not.
        let columns = 3
        let items = Array(0 ..< 20)
        let distributed = MasonryColumns.distribute(items, columns: columns)
        var replayed: [Int] = []
        for row in 0 ..< items.count {
            for column in 0 ..< columns where row < distributed[column].count {
                replayed.append(distributed[column][row])
            }
        }
        #expect(replayed == items)
    }

    @Test("the result always has exactly C entries, empty ones included")
    func alwaysCColumns() {
        // A trailing EMPTY column rather than a missing one — the view's `HStack` keeps
        // its geometry when a collection holds fewer items than there are columns.
        let indices = MasonryColumns.columnIndices(itemCount: 1, columns: 3)
        #expect(indices.count == 3)
        #expect(indices[0] == [0])
        #expect(indices[1].isEmpty)
        #expect(indices[2].isEmpty)
    }

    @Test("no item is lost or duplicated across the columns")
    func partition() {
        let indices = MasonryColumns.columnIndices(itemCount: 101, columns: 4)
        let all = indices.flatMap { $0 }
        #expect(all.count == 101)
        #expect(Set(all) == Set(0 ..< 101))
    }

    @Test("an empty collection yields C empty columns, not zero columns")
    func empty() {
        let indices = MasonryColumns.columnIndices(itemCount: 0, columns: 2)
        #expect(indices.count == 2)
        #expect(indices.flatMap { $0 }.isEmpty)
    }

    @Test("a non-positive column count clamps to one")
    func clampsColumns() {
        #expect(MasonryColumns.columnIndices(itemCount: 3, columns: 0) == [[0, 1, 2]])
        #expect(MasonryColumns.columnIndices(itemCount: 3, columns: -4) == [[0, 1, 2]])
    }

    @Test("distribute carries the elements the indices name")
    func distributeMatchesIndices() {
        let items = ["a", "b", "c", "d", "e"]
        #expect(MasonryColumns.distribute(items, columns: 2) == [["a", "c", "e"], ["b", "d"]])
    }

    // MARK: - Aspect

    @Test("a normal image keeps its own ratio")
    func aspectPassesThrough() {
        #expect(MasonryColumns.aspect(asset(width: 1000, height: 500)) == 2)
        #expect(MasonryColumns.aspect(asset(width: 500, height: 1000)) == 0.5)
    }

    @Test("a panorama and a skyscraper are clamped, so one image cannot blow a column")
    func aspectClamps() {
        #expect(MasonryColumns.aspect(asset(width: 10_000, height: 100))
            == MasonryColumns.maxAspect)
        #expect(MasonryColumns.aspect(asset(width: 100, height: 10_000))
            == MasonryColumns.minAspect)
    }

    @Test("a media-less kind and a degenerate dimension fall back to a square")
    func aspectFallback() {
        #expect(MasonryColumns.aspect(asset(width: nil, height: nil)) == 1)
        #expect(MasonryColumns.aspect(asset(width: 100, height: nil)) == 1)
        #expect(MasonryColumns.aspect(asset(width: 0, height: 100)) == 1)
        #expect(MasonryColumns.aspect(asset(width: -5, height: 100)) == 1)
    }

    // MARK: - Geometry

    @Test("columns and gaps pack into the available width exactly")
    func columnWidthPacks() {
        let width = MasonryColumns.columnWidth(
            availableWidth: 390, columns: 2, spacing: 8)
        #expect(width == 191)
        #expect(width * 2 + 8 == 390)
    }

    @Test("a column stays drawable even when the width cannot hold it")
    func columnWidthFloor() {
        #expect(MasonryColumns.columnWidth(availableWidth: 10, columns: 8, spacing: 8) == 1)
    }

    // MARK: - Column count

    @Test("the phone is two columns in portrait and three in landscape")
    func phoneColumns() {
        #expect(MasonryColumns.phoneColumns(isLandscape: false) == 2)
        #expect(MasonryColumns.phoneColumns(isLandscape: true) == 3)
    }

    // MARK: - What the partition costs (098 · finding 14)

    /// `MasonryGridView.body` calls ``MasonryColumns/distribute(_:columns:)`` INLINE, so
    /// the partition is re-run on every body evaluation of the grid — including the ones
    /// an unconditional `@Observable` store write triggers when nothing has changed.
    ///
    /// Memoising it in view state was considered and refused: the memo's key would be the
    /// array itself, which is the same O(n) walk the partition is, plus a retained copy.
    /// The honest alternative was to find out what the walk costs, and this is that.
    /// A ceiling rather than a target — an order of magnitude above what this machine
    /// does — so only a change of shape trips it: an O(n log n) sort appearing inside the
    /// decomposition, or a per-element allocation that is not the element itself.
    ///
    /// 20,000 is the review's number and it is far past any real collection; if the walk
    /// is cheap there it is cheap on Unsorted.
    @Test("partitioning twenty thousand items stays an O(n) walk")
    func distributionAtTwentyThousand() {
        let items = Array(0 ..< 20_000)

        // Ten evaluations, because ONE body evaluation is not the unit of interest — a
        // reload that fires three of them is (098 · finding 14), and a single sample of a
        // sub-millisecond event is noise.
        let started = ContinuousClock.now
        var total = 0
        for _ in 0 ..< 10 {
            let columns = MasonryColumns.distribute(items, columns: 2)
            total += columns.reduce(0) { $0 + $1.count }
        }
        let elapsed = Self.seconds(since: started)

        #expect(total == 200_000)
        print("  14: 10 partitions of 20,000 items in "
            + "\(String(format: "%.4f", elapsed))s "
            + "(\(String(format: "%.4f", elapsed / 10))s each)")
        #expect(
            elapsed < 1.0,
            """
            ten partitions of 20,000 items took \(elapsed)s — the decomposition has \
            gained something worse than a linear walk
            """)
    }

    @Test("three columns cost the same walk as two")
    func distributionIsIndependentOfColumnCount() {
        // The partition is `C` strides over `n`, so it is O(n) whatever `C` is — the
        // landscape grid must not be measurably worse than the portrait one.
        let items = Array(0 ..< 20_000)
        for columns in [2, 3] {
            let started = ContinuousClock.now
            _ = MasonryColumns.distribute(items, columns: columns)
            let elapsed = Self.seconds(since: started)
            #expect(elapsed < 1.0, "\(columns) columns took \(elapsed)s")
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let (s, attoseconds) = start.duration(to: ContinuousClock.now).components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }

    // MARK: - Fixtures

    private func asset(width: Int?, height: Int?) -> Asset {
        Asset(
            id: UUID(), kind: width == nil ? .color : .image,
            blobHash: width == nil ? nil : String(repeating: "a", count: 64),
            mimeType: width == nil ? nil : "image/jpeg",
            width: width, height: height, fileSize: width == nil ? nil : 1,
            downloadState: .downloaded, createdAt: Date(), sourceId: UUID())
    }
}
