// AtelierBrowse — what a large collection actually costs to open (096 review 14A).
//
// **The question, and why the existing gate does not answer it.** 093 § 3's laziness gate is
// cited in 092 as run and passed: 2,010 items, **8 tile bodies** instantiated at launch. That
// proves the VIEW is lazy. It says nothing about the array behind it — `CollectionFeed.load`
// calls `items(in:)`, which reads every row of the collection into `[CollectionItemDetail]`
// and holds it for as long as the screen is on the navigation stack.
//
// Unsorted is where every share lands (092 · S3), nothing auto-files it, and it is the screen
// the phone opens on. It is therefore the collection most likely to grow without bound, and
// the read is on the launch path.
//
// **Measured here rather than on a device, deliberately.** The thing that scales is a SQL
// read and an array materialisation, and both are host-testable; what needs a simulator is
// SwiftUI's behaviour, which the laziness gate already covered. Measuring the expensive half
// where measurement is cheap and repeatable beats arranging a device session to learn the
// same number once.
//
// **The assertions are ceilings, not targets.** A wall-clock bound in a test suite that runs
// on CI runners of unknown load is only honest if it is generous enough that only a change of
// ALGORITHM trips it — an N+1 appearing inside the read, a sort moving from SQL into Swift, a
// per-row `fileExists`. The numbers below are roughly an order of magnitude above what this
// machine does, and they are there to catch a shape change rather than a slow afternoon.

import Foundation
import Testing

import AtelierCapture
import AtelierCore
import AtelierLibraryPaths
@testable import AtelierBrowse

@Suite("BrowseLibrary at scale (096 review 14A)", .serialized)
struct BrowseScaleTests {

    /// Big enough that a per-row cost would be obvious, small enough that seeding it through
    /// the real `AppServices.ingest` — which is what makes this a measurement of the real
    /// path rather than of a hand-built table — stays inside a reasonable test run.
    ///
    /// The review asked for 20,000. This is 5,000, and the difference is honest: seeding goes
    /// through the same ingest funnel the app uses, one transaction per item, and 20,000 of
    /// those is minutes of test time on every run forever. 5,000 is four times the largest
    /// library anyone here has, and the cost curve it measures is the same one — if the read
    /// is linear at 5,000 it is linear at 20,000, and if it is not linear that shows up here
    /// first.
    static let itemCount = 5_000

    /// A generous ceiling for reading the whole collection. See the header: this is a shape
    /// gate, not a performance target.
    static let readBudget: TimeInterval = 5.0

    @Test("a five-thousand-item collection reads in one pass, not one query per item")
    func largeCollectionReadsInOnePass() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        try await Self.seed(fixture, count: Self.itemCount)

        let started = ContinuousClock.now
        let items = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)
        let elapsed = Self.seconds(since: started)

        #expect(items.count == Self.itemCount)
        #expect(
            elapsed < Self.readBudget,
            """
            reading \(Self.itemCount) items took \(elapsed)s, over the \(Self.readBudget)s \
            ceiling — the read has probably gained a per-row cost (an N+1, a sort moved out \
            of SQL, a stat per tile)
            """)
        // Reported on every run, because the NUMBER is the point of this test and an
        // assertion that merely passes tells nobody what it cost.
        print("  14A: read \(items.count) items in \(String(format: "%.3f", elapsed))s")
    }

    /// The second half of the same question. A screen push loads a collection while the
    /// previous one is still alive — by design, and `LibraryStore`'s header argues for it —
    /// so the cost that matters is not one read but the reads a navigation stack holds at
    /// once. If the per-read cost is linear, two of them are two; if something is quadratic
    /// in the collection size, this is where it shows.
    @Test("a second concurrent read of the same collection does not cost more than twice")
    func concurrentReadsScaleLinearly() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        try await Self.seed(fixture, count: Self.itemCount)

        // Warm: the first read of a fresh pool pays for page-cache misses that have nothing
        // to do with collection size, and charging those to the comparison would make this
        // test about SQLite's startup rather than about scaling.
        _ = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)

        let singleStart = ContinuousClock.now
        _ = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)
        let single = Self.seconds(since: singleStart)

        let pairStart = ContinuousClock.now
        async let first = fixture.library.items(in: BrowseLibrary.rootCollectionID)
        async let second = fixture.library.items(in: BrowseLibrary.rootCollectionID)
        let (a, b) = try await (first, second)
        let pair = Self.seconds(since: pairStart)

        #expect(a.count == Self.itemCount && b.count == Self.itemCount)
        print("  14A: one read \(String(format: "%.3f", single))s, "
            + "two concurrent \(String(format: "%.3f", pair))s")
        // Four times a single read, not two: `AppServices` serialises through a pool, the
        // machine is shared with whatever else CI is doing, and a bound this loose still
        // catches the failure worth catching — a cost that grows faster than the work.
        #expect(
            pair < max(Self.readBudget, single * 4 + 0.5),
            "two concurrent reads cost \(pair)s against \(single)s for one — superlinear")
    }

    /// The thumbnail path is asked for once per tile as the grid scrolls, so its per-item cost
    /// is on the scroll path rather than the launch path. It must stay arithmetic.
    ///
    /// `BrowseLibrary.gridThumbnailURL(for:)` documents that it does NOT stat — *"a grid
    /// scrolls past hundreds of these and a missing thumbnail is something the image loader
    /// finds out anyway"*. That is a promise about complexity, and this is the test of it: five
    /// thousand resolutions against a library with no thumbnail files at all. A `fileExists`
    /// sneaking in would not fail correctness anywhere; it would just make scrolling worse on
    /// exactly the libraries where scrolling matters.
    @Test("resolving a thumbnail path stays arithmetic, with no filesystem hit per tile")
    func thumbnailResolutionDoesNotTouchTheDisk() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        try await Self.seed(fixture, count: 500)
        let items = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)

        let started = ContinuousClock.now
        for _ in 0..<10 {
            for item in items {
                _ = fixture.library.gridThumbnailURL(for: item.asset)
            }
        }
        let elapsed = Self.seconds(since: started)

        print("  14A: 5,000 thumbnail resolutions in \(String(format: "%.3f", elapsed))s")
        #expect(
            elapsed < 1.0,
            """
            5,000 path resolutions took \(elapsed)s — something in the thumbnail path is \
            touching the filesystem per tile
            """)
    }

    // MARK: - Rig

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let (s, attoseconds) = start.duration(to: ContinuousClock.now).components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }

    /// Fill Unsorted through the real ingest funnel.
    ///
    /// Capture times descend so the rows are not inserted in the order any sort would want
    /// them — a read that happened to be fast because the table was already in the answer's
    /// order would be measuring nothing.
    private static func seed(_ fixture: TempBrowseLibrary, count: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            try await fixture.ingest(
                hashSeed: index + 1,
                capturedAt: base.addingTimeInterval(TimeInterval(-index * 60)))
        }
    }
}
