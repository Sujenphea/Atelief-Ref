// AtelierExport — static-site column grouping (014 · S3)
//
// Pure arithmetic. The one rule under test is the app grid's: item `i` lives in
// column `i % C`. `CollectionSiteExportTests` (app target) pins that same rule
// against `MasonryLayout.layout`, which is the code the grid actually runs.

import Testing
@testable import AtelierExport

@Suite("Site layout: column grouping")
struct SiteLayoutTests {

    // MARK: - Column count

    @Test("The requested count is clamped to 1…maxColumns")
    func clampsRequest() {
        #expect(SiteLayout.columnCount(itemCount: 100, requested: 4) == 4)
        #expect(SiteLayout.columnCount(itemCount: 100, requested: 0) == 1)
        #expect(SiteLayout.columnCount(itemCount: 100, requested: -3) == 1)
        #expect(SiteLayout.columnCount(itemCount: 100, requested: 99) == SiteLayout.maxColumns)
    }

    @Test("Never more columns than items — empty flex tracks would eat the width")
    func neverMoreColumnsThanItems() {
        #expect(SiteLayout.columnCount(itemCount: 2, requested: 4) == 2)
        #expect(SiteLayout.columnCount(itemCount: 1, requested: 6) == 1)
        // Zero items still reports a legal column count; grouping returns [].
        #expect(SiteLayout.columnCount(itemCount: 0, requested: 4) == 1)
    }

    // MARK: - Grouping

    @Test("Items land round-robin: column c holds c, c+C, c+2C…")
    func roundRobin() {
        #expect(SiteLayout.columnGroups(itemCount: 7, columns: 3)
            == [[0, 3, 6], [1, 4], [2, 5]])
    }

    @Test("An empty gallery has no columns at all")
    func empty() {
        #expect(SiteLayout.columnGroups(itemCount: 0, columns: 4).isEmpty)
    }

    @Test("Every index appears exactly once, and no column is empty")
    func partitionsExactly() {
        for count in 1...25 {
            for requested in 1...9 {
                let groups = SiteLayout.columnGroups(itemCount: count, columns: requested)
                #expect(groups.allSatisfy { !$0.isEmpty })
                #expect(groups.flatMap { $0 }.sorted() == Array(0..<count))
            }
        }
    }

    @Test("Concatenating columns in order recovers the app's reading order")
    func readingOrder() {
        // Column-major concatenation is NOT input order — that is the point of
        // round-robin: within a column the items keep their relative order, and
        // reading across the columns' first rows gives 0,1,2.
        let groups = SiteLayout.columnGroups(itemCount: 6, columns: 3)
        #expect(groups.map(\.first) == [0, 1, 2])
        #expect(groups.allSatisfy { $0 == $0.sorted() })
    }

    @Test("Column heights stay within one item of each other")
    func balanced() {
        let groups = SiteLayout.columnGroups(itemCount: 10, columns: 4)
        let counts = groups.map(\.count)
        #expect((counts.max() ?? 0) - (counts.min() ?? 0) <= 1)
    }
}
