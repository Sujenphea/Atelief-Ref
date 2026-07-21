//
//  MasonryGridHost.swift
//  AtelierRefs
//
//  036 §2 A1 — the SwiftUI ↔ AppKit seam for the collection grid, behind the
//  `AtelierUseAppKitGrid` flag. An `NSViewRepresentable` over `NSScrollView` →
//  ``MasonryNSCollectionView`` with the ``MasonryCollectionLayout`` and layer-
//  backed ``MasonryGridItem`` cells, ported from the read-only spike measured in
//  038 §3.4. READ-ONLY in A1: `isSelectable = false` (native selection bypassed
//  entirely — the `GridSelection` reducer stays the only truth), no mouse /
//  hover / keyboard / drag / drop / context-menu / marquee routing. Those are
//  A2/A3; the coordinator subclass and the cell's inert seams exist so they slot
//  in without restructuring.
//
//  Data is an `NSCollectionViewDiffableDataSource<Int, UUID>` keyed on membership
//  `item.id`. A wholesale `items` republish (load / move / delete / reorder)
//  applies a snapshot with `animatingDifferences: false`; a same-id content edit
//  reconfigures the live cells in place (re-running `configure`, NEVER
//  `reloadItems` — reload flashes). Cells load through ``ThumbnailPipeline`` with a per-cell bucket
//  derived from the ANALYTIC frame (`thumbnailPixelBucket`), and the coordinator
//  adopts `NSCollectionViewPrefetching` onto the same pipeline.
//

import AppKit
import AtelierCore
import SwiftUI

// MARK: - Configuration

/// Everything the host needs, as a plain value struct rebuilt on every SwiftUI
/// body pass (036 §2 A1). The closure bundle carries no model object — the
/// coordinator holds it — so the struct stays cheap to diff. `updateNSView`
/// diffs `(itemsVersion, density)` and `collectionID`; width changes are observed
/// by the layout off the clip view, not here.
struct GridHostConfiguration {
    var items: [CollectionItemDetail]
    /// The model's monotonic items version — bumped on every republish, so it is
    /// the single "the item set changed" signal, including in-place content edits.
    var itemsVersion: Int
    /// The density notch (columns are derived at the live width by the layout).
    var density: GridDensity
    var spacing: CGFloat
    var topInset: CGFloat
    /// Which collection these items belong to — a change resets the scroll offset.
    var collectionID: UUID
    /// Backing scale for the thumbnail pixel bucket (the other half alongside the
    /// analytic frame — 036 §4 C3).
    var displayScale: CGFloat
    /// `IngestionModel.thumbnailURL(for:)`, forwarded as a closure so the config
    /// carries no model object. `nil` for media-less kinds.
    var thumbnailURL: (CollectionItemDetail) -> URL?
    /// `IngestionModel.blobURL(for:)` — the ORIGINAL bytes, for the A3 GIF overlay.
    /// Held for the A3 seam; unused in A1.
    var blobURL: (CollectionItemDetail) -> URL?
}

// MARK: - The collection view subclass (A2/A3 seam)

/// `NSCollectionView` subclass. In A1 it only turns native selection off; A2/A3
/// override `mouseDown` / `keyDown` / `menu(for:)` / dragging here so the SwiftUI
/// delivery hacks can die without touching the host.
final class MasonryNSCollectionView: NSCollectionView {}

// MARK: - The representable

struct MasonryGridHost: NSViewRepresentable {
    let configuration: GridHostConfiguration

    func makeCoordinator() -> MasonryGridCoordinator {
        MasonryGridCoordinator(configuration: configuration)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(configuration: configuration)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: MasonryGridCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - The coordinator

/// Owns the AppKit objects, the diffable data source, and the prefetch bridge.
/// Read-only in A1: no selection / mouse / hover / keyboard / drag delegate
/// methods are implemented, by specification.
@MainActor
final class MasonryGridCoordinator: NSObject, NSCollectionViewPrefetching {
    private var configuration: GridHostConfiguration
    private let layout = MasonryCollectionLayout()

    private var scrollView: NSScrollView?
    private var collectionView: MasonryNSCollectionView?
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?

    /// The rendered item set, index-aligned to the snapshot order.
    private(set) var items: [CollectionItemDetail] = []
    /// Membership id → row, kept for the A2 coordinator's selection reconciliation
    /// (and unit-tested via ``gridIDToIndex(for:)``).
    private(set) var idToIndex: [UUID: Int] = [:]

    init(configuration: GridHostConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Construction

    func makeScrollView() -> NSScrollView {
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset

        let collectionView = MasonryNSCollectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Native selection bypassed entirely (036 §2 A1) — and A1 is read-only.
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = layout
        collectionView.register(
            MasonryGridItem.self, forItemWithIdentifier: MasonryGridItem.identifier)
        collectionView.prefetchDataSource = self

        let scrollView = NSScrollView(frame: collectionView.frame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = collectionView

        let dataSource = NSCollectionViewDiffableDataSource<Int, UUID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, _ in
            let item = collectionView.makeItem(
                withIdentifier: MasonryGridItem.identifier, for: indexPath)
            if let self, let cell = item as? MasonryGridItem {
                self.configure(cell, at: indexPath.item)
            }
            return item
        }
        collectionView.dataSource = dataSource

        self.scrollView = scrollView
        self.collectionView = collectionView
        self.dataSource = dataSource

        observeClipView(scrollView.contentView)

        // Initial data.
        applyItems(configuration.items, resetScroll: true)

        return scrollView
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        // Drop any outstanding prefetches for this grid's hashes (visible loads
        // are never prefetch-tagged, so this cannot blank an on-screen cell).
        let hashes = items.compactMap { $0.asset.blobHash }
        if !hashes.isEmpty { ThumbnailPipeline.shared.cancelPrefetch(hashes: hashes) }
    }

    // MARK: Updates

    /// Push the config's inputs into the layout + data source. Diffs
    /// `(itemsVersion, density)` and `collectionID`; a scroll never reaches here,
    /// and a width change is handled by the clip-view observer, not this method.
    func update(configuration: GridHostConfiguration) {
        let old = self.configuration
        self.configuration = configuration
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset

        let collectionChanged = old.collectionID != configuration.collectionID
        let versionChanged = old.itemsVersion != configuration.itemsVersion

        if collectionChanged || versionChanged || items.count != configuration.items.count {
            applyItems(configuration.items, resetScroll: collectionChanged)
        } else if old.density != configuration.density {
            // A density step (⌘±) at an unchanged item set: re-solve the masonry,
            // reconfigure the visible cells so their thumbnail bucket tracks the
            // new cell size.
            layout.invalidateLayout()
            reconfigureVisibleItems()
        }
    }

    /// Apply a new item set. Same-id, same-order republishes reconfigure in place
    /// (a content edit); anything else applies a fresh snapshot. `resetScroll`
    /// returns to the top on a collection switch.
    private func applyItems(_ newItems: [CollectionItemDetail], resetScroll: Bool) {
        let oldIDs = gridSnapshotIDs(for: items)
        let newIDs = gridSnapshotIDs(for: newItems)

        items = newItems
        idToIndex = gridIDToIndex(for: newItems)
        layout.itemsVersion = configuration.itemsVersion
        layout.aspects = newItems.map { aspect(for: $0) }
        layout.invalidateLayout()

        switch gridApplyStrategy(oldIDs: oldIDs, newIDs: newIDs, collectionChanged: resetScroll) {
        case .reconfigure:
            // Same membership + order — a content edit. Re-run `configure` on the
            // live cells directly: no snapshot, and NEVER `reloadItems` (it
            // flashes — 036 §2 A1). `NSCollectionViewDiffableDataSource` has no
            // `reconfigureItems` on this SDK, so the in-place reconfigure IS this
            // visible-cell pass; recycled cells reconfigure through the item
            // provider when they next scroll in.
            reconfigureVisibleItems()
        case .snapshot:
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs, toSection: 0)
            dataSource?.apply(snapshot, animatingDifferences: false)
            if resetScroll { scrollToTop() }
        }
    }

    /// Re-run `configure` on every materialized cell in place — no snapshot, no
    /// reload. Used for a same-id content edit and a density step (the thumbnail
    /// bucket tracks the new cell size). Offscreen cells reconfigure through the
    /// item provider when they next scroll into view.
    private func reconfigureVisibleItems() {
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: indexPath) as? MasonryGridItem else { continue }
            configure(cell, at: indexPath.item)
        }
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Cell configuration

    private func configure(_ cell: MasonryGridItem, at index: Int) {
        guard items.indices.contains(index) else { return }
        let detail = items[index]
        cell.configure(
            detail: detail,
            url: configuration.thumbnailURL(detail),
            bucket: bucket(at: index))
        // Read-only in A1 — always the inert state (A2 drives real selection).
        cell.applySelectionState(.inert)
    }

    /// The pixel bucket for a cell, from its ANALYTIC frame (the cell never
    /// guesses its own size — 036 §4 C3). Falls back to the solved column width
    /// before a frame exists.
    private func bucket(at index: Int) -> Int {
        gridThumbnailBucket(
            frame: layout.analyticFrame(at: index),
            columnWidth: layout.solvedColumnWidth,
            scale: configuration.displayScale)
    }

    // MARK: Clip-view observation (width → invalidate)

    private func observeClipView(_ clipView: NSClipView) {
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView)
    }

    /// The viewport RESIZED — the one event that legitimately re-solves the
    /// masonry. AppKit does not necessarily ask `shouldInvalidateLayout` for this
    /// (the collection view's own width is derived from the content size, so
    /// waiting for its bounds to move is circular), hence the explicit
    /// invalidation off the clip view.
    @objc private func clipFrameChanged() {
        guard let width = scrollView?.contentSize.width, width > 0 else { return }
        if abs(width - layout.preparedWidth) > 0.5 {
            layout.invalidateLayout()
        }
    }

    // MARK: Prefetching (036 §4 C3 → ThumbnailPipeline)

    func collectionView(
        _ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let requests = indexPaths.compactMap { request(at: $0.item) }
        if !requests.isEmpty { ThumbnailPipeline.shared.prefetch(requests) }
    }

    func collectionView(
        _ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        // A visible request JOINS an in-flight prefetch task, so a hash that
        // crossed into the visible window must NOT be cancelled or the on-screen
        // cell awaiting that decode blanks (036 §4 C1). AppKit already stops
        // treating a now-visible item as a prefetch candidate; excluding the live
        // set here is the belt-and-braces guard.
        let visible = Set(collectionView.indexPathsForVisibleItems().map(\.item))
        let hashes = indexPaths.compactMap { path -> String? in
            guard !visible.contains(path.item), items.indices.contains(path.item) else { return nil }
            return items[path.item].asset.blobHash
        }
        if !hashes.isEmpty { ThumbnailPipeline.shared.cancelPrefetch(hashes: hashes) }
    }

    private func request(at index: Int) -> ThumbnailRequest? {
        guard items.indices.contains(index) else { return nil }
        let detail = items[index]
        guard let hash = detail.asset.blobHash,
              let url = configuration.thumbnailURL(detail) else { return nil }
        return ThumbnailRequest(hash: hash, url: url, bucket: bucket(at: index))
    }
}

// MARK: - Pure coordinator helpers (unit-tested)

/// The thumbnail pixel bucket for a cell from its ANALYTIC masonry `frame` (036
/// §4 C3 — the cell never guesses its own size). The long side, because the tile
/// crop-FILLS its rect; a `nil` frame (before the layout has solved) falls back
/// to the solved `columnWidth`. Shared by the coordinator's visible-cell path
/// and its prefetch requests so the pixels prefetched and the pixels drawn agree.
func gridThumbnailBucket(frame: CGRect?, columnWidth: CGFloat, scale: CGFloat) -> Int {
    let longSide = max(frame?.width ?? columnWidth, frame?.height ?? 0)
    return thumbnailPixelBucket(pointLongSide: longSide, scale: scale)
}

/// The snapshot's item identifiers: membership `item.id` in display order.
func gridSnapshotIDs(for items: [CollectionItemDetail]) -> [UUID] {
    items.map { $0.item.id }
}

/// The id → row index map the coordinator keeps for A2 selection reconciliation.
/// A later duplicate id (which should not occur — memberships are unique) keeps
/// its LAST position, matching the snapshot's own last-wins behavior.
func gridIDToIndex(for items: [CollectionItemDetail]) -> [UUID: Int] {
    var map: [UUID: Int] = [:]
    map.reserveCapacity(items.count)
    for (index, detail) in items.enumerated() { map[detail.item.id] = index }
    return map
}

/// How to push a new item set to the diffable data source.
enum GridApplyStrategy: Equatable {
    /// Same membership + order, same collection → reconfigure in place (a content
    /// edit such as a resolved thumbnail or a rename). Avoids the snapshot churn
    /// and the `reloadItems` flash.
    case reconfigure
    /// New / reordered membership, or a collection switch → apply a fresh snapshot.
    case snapshot
}

/// Choose the apply strategy from the id order before/after and whether the
/// collection changed. A collection switch always snapshots (and resets scroll);
/// otherwise identical id order reconfigures, any other change snapshots.
func gridApplyStrategy(
    oldIDs: [UUID], newIDs: [UUID], collectionChanged: Bool
) -> GridApplyStrategy {
    (!collectionChanged && oldIDs == newIDs) ? .reconfigure : .snapshot
}
