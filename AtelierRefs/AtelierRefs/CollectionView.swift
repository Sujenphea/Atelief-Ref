//
//  CollectionView.swift
//  AtelierRefs
//
//  004-P1 — one collection's screen, extracted from the old `LibraryView`
//  detail. Header + drop target + navigable subfolder chips + a thumbnail grid
//  of the collection's DIRECT items, plus the import affordances (drop + ⌘V)
//  targeting this collection. Drilling into a subfolder pushes another
//  `CollectionView` (via `NavModel`) rather than mutating a shared selection.
//  The full-window item detail overlay keeps a LOCAL flag until 006 wires
//  `NavModel.presentedItemID`.
//

import AppKit
import AtelierCore
import AtelierIngestion
import SwiftUI
import UniformTypeIdentifiers

struct CollectionView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @ObservedObject var gridPrefs: GridViewPreferences
    // Selection moved off `IngestionModel` onto its own store (036 §2 A0). This
    // screen reads `model.selection` at ~nine body sites and must still repaint on
    // a selection change; since `model.selection` is no longer `@Published`, this
    // explicit subscription is what invalidates the body now (its former path —
    // `IngestionModel.objectWillChange` — no longer fires on selection). Every
    // OTHER `IngestionModel` observer is spared the selection fan-out. Moving the
    // nine reads down into per-cell views (so this too stops re-running) is the
    // later A1–A2 work, deliberately NOT part of A0.
    @ObservedObject private var selectionStore: GridSelectionStore
    let collectionID: UUID

    init(model: IngestionModel, nav: NavModel, gridPrefs: GridViewPreferences, collectionID: UUID) {
        _model = ObservedObject(wrappedValue: model)
        _nav = ObservedObject(wrappedValue: nav)
        _gridPrefs = ObservedObject(wrappedValue: gridPrefs)
        _selectionStore = ObservedObject(wrappedValue: model.selectionStore)
        self.collectionID = collectionID
    }

    @State private var isTargeted = false
    /// The live grid viewport width, captured from the grid's `GeometryReader`, so
    /// the toolbar / ⌘+/⌘− density controls can clamp against the current width
    /// (011-B2 · 16A) without their own geometry reader.
    @State private var gridWidth: CGFloat = 1

    // The marquee's per-tick state (009 · N6), a class in plain `@State` ON
    // PURPOSE: only the two layers in `GridMarquee.swift` observe it, so a
    // 120Hz drag re-renders those layers and NOT this whole screen. (`@State`
    // keeps the first instance across re-inits; `@StateObject` would subscribe
    // this view to every tick.)
    @State private var marquee = GridMarqueeState()
    // Programmatic scroll handle for the marquee's edge auto-scroll (offset-based
    // scrolling — `proxy.scrollTo` can only target whole cells).
    @State private var gridScroll = ScrollPosition()
    // The native Quick Look panel driver (011-B3): spacebar peeks the selection.
    @State private var quickLook = QuickLookController()
    // The hovered cell's id, hoisted OUT of `CollectionCell` so the selection
    // circle can be drawn as a sibling above the cell's `.draggable` surface
    // (else a press on the small circle is stolen by the drag gesture). Set from
    // the cell's `onHoverChanged`; drives `showsCircle` for the idle-hover case.
    @State private var hoveredItemID: UUID?

    // The container context menu's cursor + highlight state (036 §4 C4). A class
    // in plain `@State`, exactly like `marquee` above and for the same reason:
    // the cursor position is written on every mouse-moved event and must not
    // publish. Only `GridContextHighlightLayer` observes it.
    @State private var contextMenu = GridContextMenuState()

    private static let gridSpacing: CGFloat = 8
    private static let gridTopInset: CGFloat = 4
    private static let marqueeSpace = "collectionGridContent"

    // The masonry layout cache (011-B1 · 14A): frames recompute only when
    // (itemsVersion, width, columns) change — never on the marquee's per-tick
    // selection churn (which re-renders this screen), so a drag stays a memo hit.
    @State private var masonryCache = MasonryLayoutCache()

    // The windowing band (012): the grid renders only the cells near the viewport
    // (measured: eager rendering was ~7.4s layout + ~2.0s hit-testing on the main
    // thread, both scaling with item count). This is the QUANTIZED scroll position
    // — updated from `onScrollGeometryChange` but published ONLY when the band
    // changes, so a scroll re-materializes the grid a few times per screenful, not
    // once per tick (the churn the non-published marquee viewport avoids).
    @State private var window = GridWindow(band: 0, rect: .zero)

    // Move/copy targets, memoized (012 · CQ 1A): the drop rail and the eager
    // per-cell context menus share ONE computation instead of recomputing the
    // identical folder list per cell. Plain `@State`; not observed.
    @State private var moveTargetsCache = MoveTargetsCache()

    // Thumbnail prefetching for the band ahead (036 §4 C3). Plain (non-observed)
    // state on purpose — it is mutated from the band-change seam, and publishing
    // that mutation would re-render the grid on the very frame already doing the
    // most work. Mirrors `moveTargetsCache`'s discipline.
    @State private var thumbnailPrefetcher = ThumbnailWindowPrefetcher()

    /// The backing scale the grid draws at — the other half of the thumbnail
    /// pixel bucket, alongside each cell's analytic frame (036 §4 C3).
    @Environment(\.displayScale) private var displayScale

    /// 036 §2 A1 — the AppKit `NSCollectionView` grid feature flag. Defaults OFF:
    /// with it off, behavior is EXACTLY the SwiftUI `masonryWindow` path as today
    /// (the flag is the safety net). Toggle in Settings ▸ Experimental. Read via
    /// `@AppStorage` so a toggle re-renders `grid` and swaps the host in/out.
    @AppStorage("AtelierUseAppKitGrid") private var useAppKitGrid = false

    /// The round-robin column count for a viewport `width` — the ONE source both
    /// the masonry layout and keyboard nav read, so `nextGridIndex`'s `± columns`
    /// index math always matches the frames. Driven by the global density notch
    /// (011-B2), floored to the 512px cell cap ([16A]) by `GridDensity`.
    private func gridColumns(forWidth width: CGFloat) -> Int {
        gridPrefs.density.columns(forWidth: width)
    }

    /// Whether the shared `model.items` currently belong to THIS collection. The
    /// model holds a single shared items array, so a freshly-pushed view for a new
    /// collection would otherwise render the PREVIOUS collection's items during the
    /// async reload gap (the "flash of the last collection" on switch). Until the
    /// load for this `collectionID` resolves, the grid shows a loading skeleton
    /// instead of stale content. An in-place reload (move/delete within the same
    /// folder) keeps this true, so it never flashes a skeleton.
    private var isLoaded: Bool { model.loadedCollectionID == collectionID }

    var body: some View {
        LibrarySearchable(model: model, collectionID: collectionID) {
            ZStack {
                content
                // The floating drop rail (009 · N5) — every collection screen EXCEPT
                // Unsorted, and hidden while the detail page covers the grid.
                if collectionID != model.unsortedFolderID, nav.presentedItemID == nil {
                    dropRail
                }
                // Full-window detail page for the presented item. The overlay is
                // shared route state (`NavModel.presentedItemID`) so the grid, the
                // Return key, and the Space canvas can all open it; guarding also on
                // `selectedItem != nil` auto-dismisses back to the grid when the item
                // is removed/deleted from inside the page.
                if nav.presentedItemID != nil, let detail = model.leadItem {
                    detailOverlay(for: detail)
                        .transition(.opacity)
                }
            }
        }
        // Loading this collection's items into the shared model is owned by the
        // shell (`AppShellView.syncActiveCollection`), driven off the nav path so a
        // POP reloads too — a per-view `.task(id:)` fires only on a fresh push, so
        // on back the reappearing view's `model.items` used to stay on the deeper
        // folder even though the title updated (the "back shows wrong items" bug).
        // This task only refreshes the covers the drop rail's mini thumbnails need.
        .task(id: collectionID) {
            await model.refreshCollectionCovers()
        }
        .navigationTitle(model.name(for: collectionID))
        .toolbar {
            ToolbarItem { densityControls }
            ToolbarItem { sortMenu }
            ToolbarItem { AddColorButton { model.addColor(hex: $0) } }
            ToolbarItem { AddLinkButton { model.addLink(url: $0) } }
            ToolbarItem {
                Button {
                    Task {
                        if let id = await model.newSpaceFromCollection(collectionID) {
                            nav.openSpace(id)
                        }
                    }
                } label: {
                    Label("New Space from Collection", systemImage: "square.on.square.dashed")
                }
                .help("Create a space seeded from this collection's arrangement")
                .disabled(model.items.isEmpty)
            }
        }
    }

    /// The grid density control (011-B2): step the global column-count notch
    /// smaller / larger. Clamped against the live `gridWidth` so a wide window
    /// can't zoom cells past the 512px tier ([16A]); disabled at each end. The
    /// ⌘+/⌘− keys drive the same steps from the focused grid.
    private var densityControls: some View {
        let width = gridWidth
        let current = gridPrefs.density.columns(forWidth: width)
        return ControlGroup {
            Button {
                gridPrefs.zoomIn(forWidth: width)
            } label: {
                Label("Larger Thumbnails", systemImage: "plus.magnifyingglass")
            }
            .help("Larger thumbnails (⌘+)")
            .disabled(current <= GridDensity.minColumns(forWidth: width))

            Button {
                gridPrefs.zoomOut(forWidth: width)
            } label: {
                Label("Smaller Thumbnails", systemImage: "minus.magnifyingglass")
            }
            .help("Smaller thumbnails (⌘−)")
            .disabled(current >= GridDensity.maxColumns)
        }
    }

    /// The grid sort control (007 G4). Explicit checkmarked buttons (clearer +
    /// more reliable than a picker-in-menu): each persists the mode and reloads
    /// the grid; a checkmark marks the active one and the label names it.
    private var sortMenu: some View {
        let current = model.sortMode(for: collectionID)
        return Menu {
            sortButton(.manual, "Manual", "hand.draw", current)
            sortButton(.newest, "Newest", "clock", current)
            sortButton(.mostViewed, "Most Viewed", "eye", current)
        } label: {
            Label("Sort: \(Self.sortLabel(current))", systemImage: "arrow.up.arrow.down")
        }
        .help("Choose how this collection's grid is ordered")
    }

    @ViewBuilder
    private func sortButton(
        _ mode: SortMode, _ title: String, _ symbol: String, _ current: SortMode
    ) -> some View {
        Button {
            model.setSortMode(mode, for: collectionID)
        } label: {
            Label(title, systemImage: current == mode ? "checkmark" : symbol)
        }
    }

    private static func sortLabel(_ mode: SortMode) -> String {
        switch mode {
        case .manual: "Manual"
        case .newest: "Newest"
        case .mostViewed: "Most Viewed"
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // The stack row is the Unsorted screen's triage surface (009 · N4):
            // drop the selection onto a root collection to move it out of Unsorted.
            // Gate the data-bearing rows on `isLoaded` too: they read the same
            // shared model state as the grid, so showing them mid-switch would flash
            // the PREVIOUS collection's stacks / subfolders alongside the grid.
            if isLoaded, collectionID == model.unsortedFolderID, !model.stackPreviews.isEmpty {
                stackRow
            }
            if isLoaded, !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
        // The whole collection pane is the drop target (the explicit dropzone is
        // gone): a Finder file, a browser image, or a dragged web URL dropped
        // anywhere here imports into this collection. Internal reorder drags carry
        // `AssetDragPayload` (a `.json` UTI), which isn't in this accepted set, so a
        // reorder dropped on an empty gap simply no-ops rather than importing.
        .onDrop(of: [.image, .fileURL, .url], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        // Targeting highlight as an OVERLAY border so only this layer redraws on
        // drag hover — the grid subtree and its cells are untouched (perf).
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The Unsorted-only horizontal row of collection stacks (009 · N4). Each card
    /// is a drop target that MOVES (⌥ copies) the dragged selection out of Unsorted
    /// into that collection, and navigates into it on a plain click.
    private var stackRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.stackPreviews, id: \.collection.id) { preview in
                    StackDropTarget(
                        preview: preview,
                        thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                        onNavigate: { nav.openCollection(preview.collection.id) },
                        onDrop: { handleCollectionDrop($0, into: preview.collection.id) })
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// This screen's move/copy targets, memoized (012 · CQ 1A) so the drop rail and
    /// every eager per-cell context menu share ONE computation, not N.
    private var moveTargets: MoveTargets {
        moveTargetsCache.targets(
            from: collectionID, folders: model.folders, unsortedID: model.unsortedFolderID)
    }

    /// The floating trailing drop rail (009 · N5), materialized only when there
    /// are reachable targets. Aligned to the trailing edge over the grid.
    @ViewBuilder
    private var dropRail: some View {
        let dests = moveTargets
        if !dests.isEmpty {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CollectionDropRail(
                    targets: dests,
                    coverHash: { model.collectionCovers[$0] },
                    thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                    onNavigate: { nav.openCollection($0) },
                    onDrop: { handleCollectionDrop($0, into: $1) })
            }
        }
    }

    /// Route a payload dropped onto a collection target (stack card / rail row)
    /// and apply the move or copy. Shared by the stack row and the drop rail.
    private func handleCollectionDrop(_ payload: AssetDragPayload, into targetID: UUID) -> Bool {
        switch routeDrop(
            payload, onto: .collection(targetID), optionDown: Self.modifierReader.isOptionDown) {
        case let .move(assetIDs, _, to):
            model.moveToCollection(assetIDs: assetIDs, to: to)
            return true
        case let .copy(assetIDs, to):
            model.copyToCollection(assetIDs: assetIDs, to: to)
            return true
        case .reject, .reorder:
            return false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.name(for: collectionID)).font(.title2).bold()
            // The title tracks `collectionID` and is always correct, but the count
            // reads the shared `items` — redact it until this collection's load
            // resolves so it can't show the previous collection's count on switch.
            Text("\(isLoaded ? model.items.count : 0) items")
                .font(.callout).foregroundStyle(.secondary)
                .redacted(reason: isLoaded ? [] : .placeholder)
            importStatus
            Spacer()
            Button {
                paste()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!model.isReady)
        }
    }

    /// Live import feedback, re-homed from the old dropzone (3A): a compact
    /// progress bar + count while a drop/paste batch runs, else the latest status
    /// line. Browser/Instagram sweeps report separately via `BulkSweepsView`.
    @ViewBuilder
    private var importStatus: some View {
        if let progress = model.progress {
            HStack(spacing: 6) {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1)))
                .frame(width: 120)
                Text("\(progress.completed) / \(progress.total)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if let status = model.status {
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var subfolderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.subfolders) { folder in
                    Button {
                        nav.openCollection(folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            Group {
                if isLoaded {
                    // 036 §2 A1 — the AppKit grid behind the flag; otherwise the
                    // unchanged SwiftUI windowed path. Everything OUTSIDE `grid`
                    // (header, toolbar, drop rail, stack row, chips, detail
                    // overlay, pane `.onDrop`) is identical either way.
                    if useAppKitGrid {
                        appKitGrid(geo: geo)
                    } else {
                        loadedGrid(geo: geo)
                    }
                } else {
                    // This collection's load hasn't resolved — show a masonry
                    // skeleton, never the previous collection's items.
                    ScrollView { gridSkeleton(width: geo.size.width) }
                }
            }
            // Capture the width for the toolbar/⌘ density clamp. Guarded to a real
            // change (not subpixel wobble) so a geometry read inside a ScrollView
            // can't feed a re-render → re-measure loop.
            .onChange(of: geo.size.width, initial: true) { _, w in
                if abs(gridWidth - w) > 0.5 { gridWidth = w }
            }
        }
        .overlay {
            if isLoaded, model.items.isEmpty {
                Text("No items in this collection yet.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The masonry-shaped loading skeleton shown while THIS collection's items are
    /// still being read — the shared `items` array belongs to another collection
    /// until the load resolves. Fixed-count tiles with varied heights so it reads
    /// as "content loading", with no dependency on the (stale) item data.
    @ViewBuilder
    private func gridSkeleton(width: CGFloat) -> some View {
        let cols = max(gridColumns(forWidth: width), 1)
        let columnWidth = max((width - CGFloat(cols - 1) * Self.gridSpacing) / CGFloat(cols), 1)
        // Deterministic aspects so the skeleton reads as masonry, not a uniform
        // grid, and stays stable across redraws (indexed by col/row, no RNG).
        let aspects: [CGFloat] = [1.0, 0.72, 1.3, 0.88, 1.15, 0.8, 1.25, 0.95]
        HStack(alignment: .top, spacing: Self.gridSpacing) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: Self.gridSpacing) {
                    ForEach(0..<5, id: \.self) { row in
                        let aspect = aspects[(col * 5 + row) % aspects.count]
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: columnWidth, height: columnWidth / aspect)
                    }
                }
            }
        }
        .padding(.top, Self.gridTopInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Loading collection")
        .allowsHitTesting(false)
    }

    /// The AppKit `NSCollectionView` grid (036 §2 A1 · §4 A2), behind
    /// `AtelierUseAppKitGrid`. A1 rendered read-only; A2 wires live selection /
    /// mouse / hover / keyboard / scroll / density through the coordinator, which
    /// subscribes to `selectionStore` directly and reconciles cell layers WITHOUT a
    /// body republish (the whole point — the SwiftUI grid's per-cell `selection`
    /// reads and `.onKeyPress`/`.onHover` chain live in `loadedGrid`, which is not
    /// rendered on this path). The config is a plain value rebuilt each body pass;
    /// the coordinator diffs `(itemsVersion, density)` + `collectionID` for layout
    /// and takes selection from the store, so a selection republish never relayouts.
    /// The interaction effect closures forward to the same seams the SwiftUI path
    /// used (`open`, `requestDeleteSelected`, `presentQuickLook`, density zoom).
    @ViewBuilder
    private func appKitGrid(geo: GeometryProxy) -> some View {
        MasonryGridHost(configuration: GridHostConfiguration(
            items: model.items,
            itemsVersion: model.itemsVersion,
            density: gridPrefs.density,
            spacing: Self.gridSpacing,
            topInset: Self.gridTopInset,
            collectionID: collectionID,
            displayScale: displayScale,
            thumbnailURL: { model.thumbnailURL(for: $0) },
            blobURL: { model.blobURL(for: $0) },
            selectionStore: model.selectionStore,
            onOpenDetail: { id in
                if let detail = model.items.first(where: { $0.item.id == id }) { open(detail) }
            },
            onRequestDelete: { model.requestDeleteSelected() },
            onQuickLook: { presentQuickLook() },
            onZoomIn: { gridPrefs.zoomIn(forWidth: geo.size.width) },
            onZoomOut: { gridPrefs.zoomOut(forWidth: geo.size.width) },
            // A3 — drag out / drop / context menu. Every closure forwards to the
            // SAME model/view seams the SwiftUI grid used, so parity is structural.
            dragPayload: { model.dragPayload(forCellItemID: $0) },
            dragImage: { id in
                guard let detail = model.items.first(where: { $0.item.id == id }) else { return nil }
                let renderer = ImageRenderer(content: dragPreview(for: detail))
                renderer.scale = displayScale
                return renderer.nsImage
            },
            onCellDrop: { payload, targetAssetID in
                handleCellDrop([payload], onto: targetAssetID)
            },
            actionTargets: { model.actionTargets(forCellItemID: $0) },
            moveTargets: moveTargets,
            onMoveToCollection: { model.moveToCollection(assetIDs: $0, to: $1) },
            onCopyToCollection: { model.copyToCollection(assetIDs: $0, to: $1) },
            onSetCover: { model.setCollectionCover(collectionID: collectionID, assetID: $0) },
            onRemoveFromCollection: { model.removeFromFolder(assetIDs: $0) },
            onDelete: { model.requestDelete(assetIDs: $0) }))
    }

    /// The real, loaded masonry grid for this collection — extracted so `grid` can
    /// swap in the skeleton while the shared `items` still belong to another
    /// collection. Memoized on (itemsVersion, width, columns) so it recomputes only
    /// when one of those changes — not on selection churn.
    @ViewBuilder
    private func loadedGrid(geo: GeometryProxy) -> some View {
            // Round-robin masonry (011-B1): fixed C columns, aspect-sized cells.
            let cols = gridColumns(forWidth: geo.size.width)
            let layout = masonryCache.frames(
                version: model.itemsVersion, width: geo.size.width, columns: cols,
                spacing: Self.gridSpacing, topInset: Self.gridTopInset,
                aspects: { model.items.map { aspect(for: $0) } })
            // The windowed slice (012): the cells whose frames fall within the
            // band's quantized viewport, plus a one-viewport overscan buffer so a
            // fast flick never outruns the materialized region. Reads the PUBLISHED
            // band rect (stable per screenful), not the live scroll offset, so the
            // body re-renders only when the band changes. Before the first scroll
            // geometry lands, fall back to a top-of-content viewport.
            let viewportHeight = max(geo.size.height, 1)
            let queryRect = window.rect.height > 0
                ? window.rect
                : CGRect(x: 0, y: 0, width: geo.size.width, height: viewportHeight)
            let visible = masonryVisibleIndices(
                in: queryRect, frames: layout.frames, columns: layout.columns,
                overscan: viewportHeight)
            // The windowed cells, resolved ONCE (index → frame) and shared by the
            // render and the hover reconciliation below, so there's a single
            // materialized set — never two that could disagree.
            let cells = windowedCells(
                visible: visible, itemCount: model.items.count, frames: layout.frames)
            let contentHeight = max(layout.contentHeight, viewportHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Background capture layer (009 · N6): a drag on EMPTY space
                        // is a marquee (image-drags hit the cells above and mean
                        // move/copy); a plain click clears the selection. Fills the
                        // full content rect (the frame below), in a named space so
                        // drag locations match the computed masonry frames.
                        MarqueeCaptureLayer(
                            state: marquee,
                            itemIDs: model.items.map { $0.item.id },
                            frames: layout.frames,
                            columns: layout.columns,
                            spaceName: Self.marqueeSpace,
                            selectionIDs: model.selection.ids,
                            onMarquee: { hits, base in
                                model.applySelection(.marquee(hits: hits, base: base))
                            },
                            onClear: { model.applySelection(.clear) },
                            onAutoScroll: { gridScroll.scrollTo(y: $0) })
                        // Only the visible cells, absolutely placed at their analytic
                        // frames (012). The frames already include the top inset, so
                        // the offset IS the frame origin — no extra padding.
                        masonryWindow(cells: cells, proxy: proxy)
                        // "The menu will act on THIS cell" — the outline AppKit
                        // used to draw for free under the per-cell context menus
                        // (036 §4 C4). Drawn from the analytic frames in the same
                        // content space, above the cells.
                        GridContextHighlightLayer(state: contextMenu)
                        // The live marquee rectangle, drawn in the same space.
                        MarqueeRectangleLayer(state: marquee)
                    }
                    // Explicit content size: with only a window of cells rendered,
                    // the cells no longer establish the scrollable height — this
                    // frame does, so the scrollbar and the marquee hit-area span the
                    // WHOLE collection, not just the materialized slice.
                    .frame(width: geo.size.width, height: contentHeight, alignment: .topLeading)
                    .coordinateSpace(name: Self.marqueeSpace)
                    // Track the pointer for the container context menu (036 §4
                    // C4). Stored VIEWPORT-relative, not content-relative: a
                    // wheel/trackpad scroll moves content under a stationary
                    // pointer without firing a mouse-moved event, so a stored
                    // content point would silently go stale and the menu would
                    // target the wrong cell. Writes a non-published var — this
                    // fires per pointer pixel and must not re-render the grid.
                    .onContinuousHover(coordinateSpace: .named(Self.marqueeSpace)) { phase in
                        if case let .active(point) = phase {
                            let offset = marquee.visibleRect.origin
                            contextMenu.cursorViewport = CGPoint(
                                x: point.x - offset.x, y: point.y - offset.y)
                        } else {
                            contextMenu.cursorViewport = nil
                        }
                    }
                    // ONE context menu for the whole grid instead of one per cell
                    // (036 §4 C4). The target is hit-tested from the cursor
                    // against the ANALYTIC frames; the menu body is the unchanged
                    // `cellMenu`, so contents and action scope are identical to
                    // the per-cell version. No target (cursor in a gap) emits
                    // nothing, which is what right-clicking empty space did
                    // before.
                    .contextMenu { containerMenu(layout: layout) }
                    // The targeted-cell outline's lifetime. NSMenu's tracking
                    // notifications are global (the toolbar and main menus post
                    // them too) — "the pointer is over the grid" is the
                    // discriminator, which also means a keyboard-invoked menu
                    // draws no extra outline; the lead cell already carries its
                    // own cursor ring / selection fill in that case.
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSMenu.didBeginTrackingNotification)
                    ) { _ in
                        guard contextMenu.cursorViewport != nil,
                              let index = contextTargetIndex(layout: layout),
                              index < layout.frames.count else { return }
                        contextMenu.highlightFrame = layout.frames[index]
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSMenu.didEndTrackingNotification)
                    ) { _ in
                        contextMenu.highlightFrame = nil
                    }
                }
                .scrollPosition($gridScroll)
                // Feed the live viewport (scroll offset + container size) and
                // content height to the marquee's edge auto-scroll. Written to
                // plain (non-published) vars on purpose: this fires every scroll
                // tick and must not re-render this screen.
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geo in
                    // Non-published marquee viewport — every tick, must not re-render.
                    marquee.visibleRect = CGRect(
                        x: geo.contentOffset.x, y: geo.contentOffset.y,
                        width: geo.containerSize.width, height: geo.containerSize.height)
                    marquee.contentHeight = geo.contentSize.height
                    // Windowing band (012 · Perf 4A): ONE observer, one guarded
                    // publish. The band is quantized to the viewport height, so this
                    // assignment fires only when the scroll crosses a band boundary —
                    // a few times per screenful, not once per tick.
                    let next = gridWindow(
                        offsetY: geo.contentOffset.y,
                        viewportHeight: geo.containerSize.height,
                        contentHeight: geo.contentSize.height,
                        width: geo.containerSize.width,
                        bandHeight: geo.containerSize.height)
                    if next != window { window = next }
                }
                // Hover reconciliation (012 · CQ 3A): when the band changes, the
                // hovered cell may have UNMOUNTED (scrolled out) without firing its
                // `.onHover(false)` — which would strand a phantom selection circle.
                // Drop the hovered id if its cell is no longer in the window. (The
                // GIF slot is freed by the cell's own `.onDisappear`, whose release
                // is idempotent, so only the hover needs reconciling here.)
                .onChange(of: window) { _, _ in
                    let visibleIDs = Set(cells.map { model.items[$0.index].item.id })
                    hoveredItemID = hoverAfterWindowChange(
                        current: hoveredItemID, visibleIDs: visibleIDs)
                    // Thumbnail prefetch for the ring beyond the materialized
                    // window (036 §4 C3). The band seam is the right trigger: it
                    // fires a few times per screenful, and it is exactly when the
                    // set of "cells about to exist" changes.
                    prefetchThumbnails(cells: cells, layout: layout, queryRect: queryRect,
                                       viewportHeight: viewportHeight)
                }
                .onDisappear { thumbnailPrefetcher.cancelAll() }
                .focusable()
                .focusEffectDisabled()
                .onDeleteCommand { model.requestDeleteSelected() }
                .onKeyPress(.return) {
                    let effect = model.applySelection(.openLead)
                    execute(effect, proxy: proxy)
                    return effect == .none ? .ignored : .handled
                }
                .onKeyPress(.escape) {
                    guard model.selection.isSelecting else { return .ignored }
                    model.applySelection(.clear)
                    return .handled
                }
                // Spacebar Quick Look (011-B3): peek the selection (or the cursor
                // item when nothing is multi-selected). Independent of the detail
                // overlay — QL is an ephemeral peek, detail is the work surface.
                .onKeyPress(.space) {
                    presentQuickLook()
                    return .handled
                }
                .onKeyPress(keys: ["a"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.applySelection(.selectAll)
                    return .handled
                }
                // X toggles the keyboard cursor's cell in/out of the selection —
                // arrows move the cursor without disturbing the set, so this builds
                // a SCATTERED multi-selection from the keyboard (034 P1). Space is
                // Quick Look, so X is the free, mnemonic (✕-a-box) toggle. Ignored
                // under a modifier so it never eats ⌘X etc.
                .onKeyPress(keys: ["x"]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    model.applySelection(.toggleLead)
                    return .handled
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    handleArrow(press, width: geo.size.width, proxy: proxy)
                }
                // ⌘+ / ⌘= zoom in (bigger cells, fewer columns); ⌘− zoom out
                // (011-B2). Accept ⇧ too so ⌘+ works on layouts where "+" needs it.
                .onKeyPress(keys: ["=", "+", "-"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if press.key.character == "-" {
                        gridPrefs.zoomOut(forWidth: geo.size.width)
                    } else {
                        gridPrefs.zoomIn(forWidth: geo.size.width)
                    }
                    return .handled
                }
            }
    }

    /// The windowed masonry body (012): only the cells in `visible` (near the
    /// viewport), each ABSOLUTELY placed at its analytic ``MasonryLayout`` frame —
    /// one shared source of truth for geometry, so the render and the marquee hit
    /// math can never drift.
    ///
    /// This replaces the old eager `HStack`-of-`VStack`s. Those columns were eager
    /// (not `LazyVStack`s) because a lazy stack in an `HStack` cross-axis only
    /// ESTIMATES its height and the `.top` alignment then never settles — but that
    /// materialized EVERY cell, which is the ~9.4s main-thread scroll cost (layout
    /// + hit-testing, both scaling with item count) this windowing removes. Absolute
    /// placement needs no per-column height at all: each cell carries its own frame,
    /// and the content's scrollable height is set explicitly on the container.
    /// ``windowedCells`` is a pure FILTER (never a re-map), so cell `index` always
    /// binds `items[index]` to `frames[index]`. (Cells still decode thumbnails
    /// lazily/async via `AsyncThumbnail` + ``ThumbnailPipeline``, at the pixel
    /// bucket their own analytic frame implies.)
    @ViewBuilder
    private func masonryWindow(cells: [WindowedCell], proxy: ScrollViewProxy) -> some View {
        ForEach(cells) { cell in
            masonryCell(model.items[cell.index], frame: cell.frame, proxy: proxy)
                .offset(x: cell.frame.minX, y: cell.frame.minY)
        }
    }

    /// Hand the ring of cells just BEYOND the materialized window to
    /// ``ThumbnailPipeline``'s prefetch gate, and cancel whatever fell out of it
    /// (036 §4 C3).
    ///
    /// The prefetch overscan is twice the render overscan, so the ring is the
    /// screenful on either side of what is materialized — enough lead time for a
    /// `.utility` decode to land before the band crossing that needs it, without
    /// speculatively decoding a whole 2000-item collection. Each request carries
    /// the SAME bucket the cell will ask for (its analytic frame), because a
    /// prefetch at the wrong bucket is a decode the visible cell then has to
    /// repeat.
    private func prefetchThumbnails(
        cells: [WindowedCell], layout: MasonryFrames, queryRect: CGRect, viewportHeight: CGFloat
    ) {
        let ring = masonryPrefetchIndices(
            in: queryRect, frames: layout.frames, columns: layout.columns,
            overscan: viewportHeight * 2, rendered: cells.map(\.index))
        let requests: [ThumbnailRequest] = ring.compactMap { index in
            guard index < model.items.count else { return nil }
            let detail = model.items[index]
            // Media-less kinds (color / bare link / text-only tweet) have no blob
            // and no thumbnail to prefetch.
            guard let hash = detail.asset.blobHash,
                  let url = model.thumbnailURL(for: detail),
                  index < layout.frames.count else { return nil }
            let frame = layout.frames[index]
            return ThumbnailRequest(
                hash: hash, url: url,
                bucket: thumbnailPixelBucket(
                    pointLongSide: max(frame.width, frame.height), scale: displayScale))
        }
        // `keep` = the rendered cells' hashes: they drive their own visible loads
        // and must never be cancelled out from under (see `update(requests:keep:)`).
        let rendered = Set(cells.compactMap { model.items[$0.index].asset.blobHash })
        thumbnailPrefetcher.update(requests: requests, keep: rendered)
    }

    /// One masonry cell: the shared ``CollectionCell`` sized to its analytic
    /// `frame` (012 — the SAME frame the marquee hit-test reads, so there is one
    /// source of geometry, not a matching-by-luck inline recompute). The caller
    /// offsets it to `frame.origin`.
    private func masonryCell(
        _ detail: CollectionItemDetail, frame: CGRect, proxy: ScrollViewProxy
    ) -> some View {
        // The circle shows on every cell while selecting (all are toggleable) or,
        // when idle, only on the hovered cell. It is a ZStack SIBLING of the cell,
        // outside the `.draggable`, so its press can't be stolen by the drag.
        let showsCircle = model.selection.isSelecting || hoveredItemID == detail.item.id
        return ZStack(alignment: .topTrailing) {
            CollectionCell(
                detail: detail,
                url: model.thumbnailURL(for: detail),
                isSelected: model.selection.ids.contains(detail.item.id),
                isCursor: model.selection.lead == detail.item.id,
                isSelecting: model.selection.isSelecting,
                fill: true,
                gifURL: detail.asset.mimeType == GifMotion.gifMimeType
                    ? model.blobURL(for: detail) : nil,
                // The bucket comes from the cell's ANALYTIC masonry frame — the
                // same `frame` the marquee hit-test and the offset read, so the
                // pixels requested and the pixels drawn can't drift (036 §4 C3).
                // Long side, because the tile crop-FILLS its rect.
                bucket: thumbnailPixelBucket(
                    pointLongSide: max(frame.width, frame.height), scale: displayScale),
                onImagePress: { shift, command in
                    handleImagePress(detail, shift: shift, command: command, proxy: proxy)
                },
                onImageClick: { shift, command in
                    handleImageClick(detail, shift: shift, command: command, proxy: proxy)
                },
                // The cell's own hover stays LOCAL to it (GIF dwell only). Circle
                // visibility is driven by the ZStack's `.onHover` below instead:
                // the circle is a sibling ON TOP of the cell, so moving onto it to
                // click occludes the cell and fires its hover FALSE — which used to
                // hide the circle mid-reach (flicker), dropping the click onto the
                // image underneath (it opened the item instead of multi-selecting).
                onHoverChanged: { _ in })
                .equatable()
                .frame(width: frame.width, height: frame.height)
                .draggable(dragPayload(for: detail)) { dragPreview(for: detail) }
                .dropDestination(for: AssetDragPayload.self) { payloads, _ in
                    handleCellDrop(payloads, onto: detail.asset.id)
                }
                // NO per-cell `.contextMenu` (036 §4 C4) — one container-level
                // menu on the grid content resolves its target by hit-testing the
                // cursor, so a band crossing no longer builds ~100 full menu
                // trees for a click that lands on at most one cell.
            if showsCircle {
                selectionCircle(for: detail).transition(.opacity)
            }
        }
        .id(detail.item.id)
        // Hover the WHOLE cell region (cell + circle): the circle sits on top of the
        // cell, so keying visibility off the container keeps it stable while the
        // pointer travels onto it — no flicker, and the click lands on the circle.
        .onHover { hovering in
            if hovering { hoveredItemID = detail.item.id }
            else if hoveredItemID == detail.item.id { hoveredItemID = nil }
        }
        .animation(.easeInOut(duration: 0.12), value: showsCircle)
    }

    /// The hover/selection circle — the toggle that ENTERS/exits selection mode.
    /// Rendered by the parent, outside the cell's `.draggable`, so a press lands as
    /// a clean `Button` click instead of racing (and losing to) the drag gesture —
    /// the bug where hover-clicking the circle did nothing. Hidden from VoiceOver:
    /// the cell already announces + toggles selection (it was a children-ignored
    /// child before the lift), so exposing it again would double up.
    private func selectionCircle(for detail: CollectionItemDetail) -> some View {
        let isSelected = model.selection.ids.contains(detail.item.id)
        return Button {
            model.applySelection(.tapCircle(detail.item.id))
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? Color.white : Color.white.opacity(0.95),
                    isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.15)).padding(1))
                .padding(6)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Deselect" : "Select")
        .accessibilityHidden(true)
    }

    // MARK: - Container context menu (036 §4 C4)

    /// The grid's ONE context menu: the unchanged ``cellMenu(for:)`` built for
    /// whichever cell the cursor resolved to, or nothing at all when it resolved
    /// to none — an empty `@ViewBuilder` result presents no menu, which is what a
    /// right-click on empty space did when the menus were per-cell.
    @ViewBuilder
    private func containerMenu(layout: MasonryFrames) -> some View {
        if let index = contextTargetIndex(layout: layout) {
            cellMenu(for: model.items[index])
        }
    }

    /// The item index a right-click should act on, shared by the menu body and
    /// the targeted-cell outline so the two can never name different cells.
    ///
    /// Resolution rides the ANALYTIC ``MasonryLayout`` frames (038 §6): a
    /// zero-size-rect ``masonryMarqueeIndices`` query at the cursor, exactly the
    /// call the marquee runs per drag tick. Live cell frames are never consulted.
    ///
    /// A cursor over a GAP between cells resolves to `nil` (no menu) — parity
    /// with the per-cell version. NO cursor at all means the menu was invoked
    /// from the keyboard (the Menu key), which carries no position; 036 §4 C4
    /// specifies falling back to the keyboard cursor (`lead`) cell.
    private func contextTargetIndex(layout: MasonryFrames) -> Int? {
        let point = gridCursorContentPoint(
            viewport: contextMenu.cursorViewport, contentOffset: marquee.visibleRect.origin)
        if let index = masonryContextTargetIndex(
            at: point, frames: layout.frames, columns: layout.columns),
           model.items.indices.contains(index) {
            return index
        }
        guard contextMenu.cursorViewport == nil, let lead = model.selection.lead else {
            return nil
        }
        return model.items.firstIndex { $0.item.id == lead }
    }

    /// The batch context menu (009 · N2/N6). Finder scope (7A): a right-click on a
    /// SELECTED cell acts on the whole selection; on an UNSELECTED cell it acts on
    /// that one cell and leaves the selection untouched. Counts are shown in the
    /// destructive verbs so the scope is never ambiguous.
    @ViewBuilder
    private func cellMenu(for detail: CollectionItemDetail) -> some View {
        let targets = model.actionTargets(forCellItemID: detail.item.id)
        let n = targets.count
        let dests = moveTargets

        Menu("Move to") {
            targetButtons(dests) { model.moveToCollection(assetIDs: targets, to: $0) }
        }
        Menu("Add to") {
            targetButtons(dests) { model.copyToCollection(assetIDs: targets, to: $0) }
        }
        if n == 1 {
            Button("Set as Cover") {
                model.setCollectionCover(collectionID: collectionID, assetID: targets[0])
            }
        }
        Divider()
        Button("Remove from Collection\(Self.countSuffix(n))") {
            model.removeFromFolder(assetIDs: targets)
        }
        Button("Delete\(Self.countSuffix(n))", role: .destructive) {
            model.requestDelete(assetIDs: targets)
        }
    }

    /// A Move-to / Add-to submenu: subfolders first, a divider, then roots.
    @ViewBuilder
    private func targetButtons(
        _ dests: MoveTargets, action: @escaping (UUID) -> Void
    ) -> some View {
        ForEach(dests.subfolders) { c in Button(c.name) { action(c.id) } }
        if !dests.subfolders.isEmpty && !dests.roots.isEmpty { Divider() }
        ForEach(dests.roots) { c in Button(c.name) { action(c.id) } }
    }

    /// " (N)" for a multi-item action, empty for a single — keeps the verb scope
    /// explicit ("Delete (34)") without noise on the common one-item case.
    private static func countSuffix(_ n: Int) -> String { n > 1 ? " (\(n))" : "" }

    /// Build the full-window detail overlay for `detail`, feeding the
    /// presentation-only ``ItemDetailView`` from this collection's `IngestionModel`
    /// context — full folder actions plus prev/next across `model.items`.
    private func detailOverlay(for detail: CollectionItemDetail) -> some View {
        let hasSource = !(detail.source.originalURL ?? "").isEmpty
        // A media-less kind (003 · O1) has no blob on disk — disable the blob
        // actions rather than wiring them to a no-op.
        let hasBlob = model.blobURL(for: detail) != nil
        let index = model.items.firstIndex { $0.item.id == detail.item.id }
        return ItemDetailView(
            asset: detail.asset,
            source: detail.source,
            blobURL: model.blobURL(for: detail),
            previewImage: model.previewImage,
            tags: model.selectedTags,
            onAddTag: { model.addTag($0) },
            onRemoveTag: { model.removeTag($0) },
            actions: ItemDetailActions(
                openSource: hasSource ? { model.openSource(detail) } : nil,
                openBlob: hasBlob ? { model.openBlob(detail) } : nil,
                revealInFinder: hasBlob ? { model.revealInFinder(detail) } : nil,
                copySourceLink: hasSource ? { model.copySourceLink(detail) } : nil,
                removeFromFolder: { model.removeFromFolder(assetIDs: [detail.asset.id]) },
                requestDelete: { model.requestDelete(assetIDs: [detail.asset.id]) }),
            navigator: index.map { i in
                ItemDetailNavigator(index: i, count: model.items.count) { delta in
                    let target = i + delta
                    if model.items.indices.contains(target) {
                        model.openItem(model.items[target])
                        // Stepping to a new item in the detail page is a view.
                        model.recordView(assetID: model.items[target].asset.id)
                    }
                }
            },
            onClose: {
                model.flushViewBumps()
                withAnimation { nav.presentedItemID = nil }
            })
    }

    /// Open the full-window detail page for `detail`: make it the lead (loading
    /// its preview + tags, 009 · 8A) and raise the overlay via
    /// `NavModel.presentedItemID` (the routing seam the grid click, the Return
    /// key, and the Space canvas all funnel through). The open is the deliberate
    /// "view" signal (007 G4).
    private func open(_ detail: CollectionItemDetail) {
        model.openItem(detail)
        model.recordView(assetID: detail.asset.id)
        withAnimation { nav.presentedItemID = detail.item.id }
    }

    /// Toggle the native Quick Look panel (011-B3) over the current preview set:
    /// the whole selection when selecting, else the keyboard-cursor (`lead`) item.
    /// Media-less items are skipped by `quickLookPlan`; an all-media-less set is a
    /// no-op. Flipping starts at the lead item.
    private func presentQuickLook() {
        let details: [CollectionItemDetail]
        if model.selection.isSelecting {
            details = model.items.filter { model.selection.ids.contains($0.item.id) }
        } else if let lead = model.leadItem {
            details = [lead]
        } else {
            details = []
        }
        let plan = quickLookPlan(
            for: details, leadID: model.selection.lead,
            blobURL: { model.blobURL(for: $0) })
        guard !plan.isEmpty else { return }
        quickLook.toggle(urls: plan.urls, startIndex: plan.startIndex)
    }

    // MARK: - Selection input routing (009 · N2)

    /// The mouse-DOWN edge on a cell's image: apply the down-edge cases (⇧/⌘,
    /// toggle-on of an unselected cell while selecting) so a drag activation
    /// can't swallow them, and report whether the press consumed the interaction
    /// (the cell then ignores the matching mouse-up click). The decision table
    /// is the pure ``gridPressRouting(imageID:isSelecting:isSelected:shift:command:)``.
    private func handleImagePress(
        _ detail: CollectionItemDetail, shift: Bool, command: Bool, proxy: ScrollViewProxy
    ) -> Bool {
        let routing = gridPressRouting(
            imageID: detail.item.id,
            isSelecting: model.selection.isSelecting,
            isSelected: model.selection.ids.contains(detail.item.id),
            shift: shift, command: command)
        if let action = routing.pressAction {
            execute(model.applySelection(action), proxy: proxy)
        }
        return routing.consumesRelease
    }

    /// A plain/⇧/⌘ click on a cell's image: build the reducer action from the live
    /// modifiers and execute the returned effect. The reducer owns the
    /// mode-dependent "open vs toggle" decision — this only routes.
    private func handleImageClick(
        _ detail: CollectionItemDetail, shift: Bool, command: Bool, proxy: ScrollViewProxy
    ) {
        let action = gridClickAction(imageID: detail.item.id, shift: shift, command: command)
        execute(model.applySelection(action), proxy: proxy)
    }

    /// Route an arrow key (with ⇧ = extend) through the reducer, feeding it the
    /// live column count so Up/Down step a whole row.
    private func handleArrow(
        _ press: KeyPress, width: CGFloat, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let key: GridArrowKey
        switch press.key {
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .upArrow: key = .up
        case .downArrow: key = .down
        default: return .ignored
        }
        let columns = gridColumns(forWidth: width)
        let effect = model.applySelection(
            .arrow(key, extend: press.modifiers.contains(.shift)), columns: columns)
        execute(effect, proxy: proxy)
        return .handled
    }

    /// Carry out a reducer ``GridSelectionEffect``: open a detail page or scroll a
    /// cell into view (Q4 — ⇧-arrow reuses the existing `scrollTo` path).
    private func execute(_ effect: GridSelectionEffect, proxy: ScrollViewProxy) {
        switch effect {
        case .none:
            break
        case let .scrollTo(id):
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        case let .openDetail(id):
            if let detail = model.items.first(where: { $0.item.id == id }) { open(detail) }
        }
    }

    // MARK: - Drag & drop (009 · N3)

    /// The ⌥-at-drop-time reader, isolated behind a protocol so move-vs-copy
    /// routing stays unit-testable (the routing itself lives in `routeDrop`).
    private static let modifierReader: ModifierReading = LiveModifierReader()

    /// The payload for a drag starting on `detail`: the whole selection when the
    /// cell is selected, else the cell alone (which it also selects). Falls back
    /// to a lone-cell payload if the model can't build one (cell vanished).
    private func dragPayload(for detail: CollectionItemDetail) -> AssetDragPayload {
        model.dragPayload(forCellItemID: detail.item.id)
            ?? AssetDragPayload(assetIDs: [detail.asset.id], sourceCollectionID: collectionID)
    }

    /// The drag image: the cell's thumbnail with a count badge when more than one
    /// item travels (Q3 — count badge on the lead thumbnail).
    @ViewBuilder
    private func dragPreview(for detail: CollectionItemDetail) -> some View {
        let count = model.selection.ids.contains(detail.item.id)
            ? max(model.selection.ids.count, 1) : 1
        // 84 pt → 168 px at 2× → the 192 bucket (036 §4 C3).
        AssetContentThumbnail(
            asset: detail.asset, url: model.thumbnailURL(for: detail),
            bucket: thumbnailPixelBucket(pointLongSide: 84, scale: displayScale))
            .frame(width: 84, height: 84)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.caption2).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(4)
                }
            }
    }

    /// Handle a payload dropped onto the cell for `targetAssetID`: route it (only
    /// a same-collection, manual-sort drop is a reorder) and apply the multi-block
    /// move. Cross-collection / non-manual drops are refused here — those moves go
    /// through the stack row / rail.
    private func handleCellDrop(_ payloads: [AssetDragPayload], onto targetAssetID: UUID) -> Bool {
        guard let payload = payloads.first else { return false }
        let target = DropTarget.cell(
            collectionID: collectionID, sortMode: model.sortMode(for: collectionID))
        switch routeDrop(payload, onto: target, optionDown: Self.modifierReader.isOptionDown) {
        case let .reorder(assetIDs):
            model.reorderItems(movingAssetIDs: assetIDs, toIndexOf: targetAssetID)
            return true
        case .reject, .move, .copy:
            return false
        }
    }

    // MARK: - Import actions

    /// The shared disposition for both import surfaces (paste + drop): decoded
    /// inputs win; else a web URL is downloaded/resolved; else the drop is reported
    /// as unreadable. `undecoded` (drag path only) rides into the batch so its
    /// completion status can note how many items couldn't be read (7A).
    private func dispatch(inputs: [IngestInput], webURL: URL?, undecoded: Int = 0) {
        if !inputs.isEmpty {
            model.run(inputs: inputs, undecoded: undecoded)
        } else if let webURL {
            model.ingestRemoteImage(from: webURL)
        } else {
            model.reportUnreadableDrop()
        }
    }

    private func paste() {
        guard model.isReady else { return }
        let pasteboard = NSPasteboard.general
        let inputs = DirectInputReader.inputs(
            from: pasteboard, into: collectionID, now: Date())
        dispatch(inputs: inputs, webURL: Self.firstWebURL(on: pasteboard))
    }

    private static func firstWebURL(on pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = objects.first(where: { !$0.isFileURL && DirectInputReader.isWebURL($0) }) {
            return url
        }
        if let string = pasteboard.string(forType: .URL),
           let url = URL(string: string), DirectInputReader.isWebURL(url) {
            return url
        }
        // A URL copied as PLAIN TEXT (the address bar, a message, a doc) carries only
        // `public.utf8-plain-text` — not `.URL` or an NSURL — so parse that too, with a
        // dotted-host guard so arbitrary text isn't mistaken for a link (001 · C2b).
        if let text = pasteboard.string(forType: .string),
           let url = IngestionModel.webURL(fromPastedText: text) {
            return url
        }
        return nil
    }

    /// Decode a drag drop's providers off-main through the shared
    /// ``DirectInputReader`` seam (the same decision order as the pasteboard path),
    /// then dispatch. Returns `true` synchronously to claim the drop.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isReady else { return false }
        let target = collectionID
        Task {
            let decoded = await DirectInputReader.inputs(
                from: providers, into: target, now: Date())
            dispatch(
                inputs: decoded.inputs,
                webURL: decoded.webURL,
                undecoded: decoded.undecodedCount)
        }
        return true
    }
}
