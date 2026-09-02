// AtelierRefsMobile — the grid (093 § 3).
//
// An `HStack` of `C` `LazyVStack`s inside one `ScrollView`. That is the entire port of
// the Mac's masonry, and it is only possible because `MasonryLayout` is ROUND-ROBIN
// fixed-column: item `i` is in column `i % C` regardless of how tall anything above it
// turned out, so the layout decomposes into `C` independent vertical stacks
// (`MasonryColumns`, and 093 § 3 for the argument). No solver is ported, no custom
// `Layout` is written — a `Layout` receives `Subviews` and therefore instantiates every
// one of them, which is the shape the desktop measured losing at 2,000 items
// ([038](../../.docs/038-grid-bakeoff-results.md) § 2) — and no `UICollectionView`
// bridge appears, which 092 · S5 forbids outright.
//
// **The laziness gate.** That `LazyVStack`s nested in an `HStack` inside a `ScrollView`
// stay lazy is the standard recipe and 093 § 3 explicitly does not take it on faith: S5
// is told to check it the cheap way and, if it fails, fall back to a uniform
// `LazyVGrid`. `-atelier-log-tile-bodies` is that check — it prints one line per tile
// body build, so a 2,000-item collection either prints a screenful or prints 2,000.
// The fallback would be a rollback of a layout container, not a bake-off.

import AtelierBrowse
import AtelierCore
import SwiftUI

struct MasonryGridView: View {
    let items: [CollectionItemDetail]
    /// The collection these items belong to — half of an item's navigation value, for
    /// the reason ``BrowseRoute`` gives.
    let collectionID: UUID
    /// Resolves a tile's thumbnail path. A closure rather than the store, so this view
    /// has no opinion about where a library lives.
    let thumbnailURL: (Asset) -> URL?

    var body: some View {
        GeometryReader { geometry in
            let columns = MasonryColumns.phoneColumns(
                isLandscape: geometry.size.width > geometry.size.height)
            let width = MasonryColumns.columnWidth(
                availableWidth: geometry.size.width - 2 * MobileTheme.Spacing.lg,
                columns: columns,
                spacing: MobileTheme.gridSpacing)
            ScrollView {
                HStack(alignment: .top, spacing: MobileTheme.gridSpacing) {
                    ForEach(
                        Array(MasonryColumns.distribute(items, columns: columns).enumerated()),
                        id: \.offset
                    ) { _, column in
                        LazyVStack(spacing: MobileTheme.gridSpacing) {
                            ForEach(column, id: \.item.id) { detail in
                                NavigationLink(
                                    value: BrowseRoute.item(
                                        collection: collectionID, item: detail.item.id)
                                ) {
                                    GridTile(
                                        detail: detail,
                                        width: CGFloat(width),
                                        thumbnailURL: thumbnailURL(detail.asset))
                                }
                                .buttonStyle(.plain)
                                .onAppear { TileBodyLog.record() }
                            }
                        }
                        // Each column takes exactly its share; without this an empty
                        // trailing column collapses and the others reflow.
                        .frame(width: CGFloat(width), alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.vertical, MobileTheme.Spacing.md)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The laziness gate's instrument (093 § 3), and since 098 · P3 the decode counter too.
///
/// **Entirely `#if DEBUG`.** The state, the lock and the `print` were not, which put a
/// `nonisolated(unsafe)` static, an `NSLock` and a `print` per tile into a shipping
/// binary for the sake of a diagnostic nobody can turn on there. The type keeps its shape
/// in Release — the two calls compile to nothing — so the call sites stay readable rather
/// than being wrapped in `#if` at every use.
///
/// Off unless ``argument`` is on the command line, so a debug run costs one
/// already-computed `Bool` per cell.
///
/// `nonisolated` because this target defaults its isolation to the main actor and the
/// decode counter is called from inside the cache's detached decode. The lock is what
/// makes that safe and is the reason there is one.
nonisolated enum TileBodyLog {
    #if DEBUG
    /// The launch argument that turns both counters on. Named, following
    /// `FixtureLibrary.argument` and `LibraryLocation.overrideArgument`, because a
    /// launch-argument string spelled at its one use site is a string nothing can find.
    static let argument = "-atelier-log-tile-bodies"

    static let isEnabled = CommandLine.arguments.contains(argument)

    nonisolated(unsafe) private static var bodies = 0
    nonisolated(unsafe) private static var decodes = 0
    private static let lock = NSLock()

    /// A tile came on screen. If the stacks are lazy, a 2,000-item collection reports tens
    /// at launch; if they are not, it reports 2,000 before a finger has touched the glass.
    static func record() {
        guard isEnabled else { return }
        lock.lock()
        bodies += 1
        let current = bodies
        lock.unlock()
        print("atelier.tile-body \(current)")
    }

    /// A thumbnail was actually DECODED — a cache miss that was not coalesced into another
    /// viewer's decode (098 · finding 15).
    ///
    /// The number 098 leaves to a device: a fling over the 2,010-item fixture with this on
    /// says whether the coalescing the `DecodeCache` provides is ever hit, and what a
    /// scroll really costs in decodes rather than in tile bodies. The two lines are
    /// interleaved on purpose — bodies against decodes over the same fling is the ratio,
    /// and reading it off one log is what makes it one measurement.
    static func recordDecode() {
        guard isEnabled else { return }
        lock.lock()
        decodes += 1
        let current = decodes
        lock.unlock()
        print("atelier.tile-decode \(current)")
    }
    #else
    static func record() {}
    static func recordDecode() {}
    #endif
}
