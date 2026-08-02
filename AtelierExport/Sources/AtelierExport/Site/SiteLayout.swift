// AtelierExport — static-site column grouping (014 · S3)
//
// The one piece of layout arithmetic the HTML export needs, and it is small on
// purpose. Neither shipped layout engine fits here:
//
//   • `MoodboardLayout` converts world rects to PAGE POINTS for a fixed-size
//     sheet. A web page has no page size and no y-flip.
//   • `MasonryLayout` (app target) computes absolute `CGRect`s for a known
//     viewport width. Baking pixel frames into HTML would freeze the page at one
//     width — the opposite of what a shareable page should do, since CSS already
//     stacks and sizes cells for whatever viewport opens it.
//
// What DOES carry over is `MasonryLayout`'s placement RULE: item `i` lives in
// column `i % C`, round-robin, so feed order reads left-to-right exactly as it
// does in the app's grid. That rule is reproduced here as a pure grouping, and
// `CollectionSiteExportTests` pins it against `MasonryLayout.layout` so the two
// can never drift. The heights CSS then derives from each image's intrinsic
// aspect are the same `columnWidth / aspect` the app computes — flexbox does
// that arithmetic in the browser instead of in Swift.

/// Column assignment for the exported page's masonry.
public enum SiteLayout {
    /// The widest grid the popover offers. Beyond this, columns are narrower
    /// than a legible thumbnail on a laptop.
    public static let maxColumns = 8

    /// The column count actually used for `itemCount` items: the request
    /// clamped to `1...maxColumns`, and never more columns than there are
    /// items — four flex columns holding two images would leave two empty
    /// tracks eating half the width.
    public static func columnCount(itemCount: Int, requested: Int) -> Int {
        let clamped = min(max(1, requested), maxColumns)
        return max(1, min(clamped, itemCount))
    }

    /// Item indices grouped by column, round-robin (`i % C`) — the app grid's
    /// rule. Column `c` holds `c, c + C, c + 2C, …`; every returned column is
    /// non-empty, and concatenating the groups in column order visits every
    /// index exactly once.
    public static func columnGroups(itemCount: Int, columns: Int) -> [[Int]] {
        guard itemCount > 0 else { return [] }
        let count = columnCount(itemCount: itemCount, requested: columns)
        var groups = [[Int]](repeating: [], count: count)
        for index in 0..<itemCount {
            groups[index % count].append(index)
        }
        return groups
    }
}
