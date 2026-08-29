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

/// The laziness gate's instrument (093 § 3).
///
/// Off unless `-atelier-log-tile-bodies` is on the command line, so it costs one
/// already-computed `Bool` per cell in a normal run. It counts tiles that actually came
/// on screen: if the stacks are lazy, a 2,000-item collection reports tens at launch;
/// if they are not, it reports 2,000 before a finger has touched the glass.
enum TileBodyLog {
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()

    static let isEnabled = CommandLine.arguments.contains("-atelier-log-tile-bodies")

    static func record() {
        guard isEnabled else { return }
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        print("atelier.tile-body \(current)")
    }
}
