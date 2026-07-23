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
    /// Drives the selection bar's `…` overflow, shown as a popover so it opens
    /// ABOVE the bar (a plain `Menu` opens downward and off the floating bar).
    @State private var showMoreActions = false
    /// The live grid viewport width, captured from the grid's `GeometryReader`, so
    /// the toolbar / ⌘+/⌘− density controls can clamp against the current width
    /// (011-B2 · 16A) without their own geometry reader.
    @State private var gridWidth: CGFloat = 1

    // The native Quick Look panel driver (011-B3): spacebar peeks the selection.
    @State private var quickLook = QuickLookController()

    // Subfolder create / rename from this screen (043). `newSubfolderParentID` is
    // this collection for the header action, or a chip's folder for its menu.
    @State private var showNewSubfolder = false
    @State private var newSubfolderName = ""
    @State private var newSubfolderParentID: UUID?
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    private static let gridSpacing: CGFloat = 8
    private static let gridTopInset: CGFloat = 4

    // Move/copy targets, memoized (012 · CQ 1A): the eager per-cell context menus
    // share ONE computation instead of recomputing the identical folder list per
    // cell. Plain `@State`; not observed.
    @State private var moveTargetsCache = MoveTargetsCache()

    /// The backing scale the grid draws at — the other half of the thumbnail
    /// pixel bucket, alongside each cell's analytic frame (036 §4 C3).
    @Environment(\.displayScale) private var displayScale

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
        // 006 shell — the grid fills the detail panel; the old `.searchable` field +
        // toolbar (density / sort / add / new-space) are gone. Sort lives in the
        // sidebar rail, add / new-space in the floating "+", density on ⌘± / ⌘−.
        ZStack {
            content
            // Full-window detail page for the presented item, hosted in its own
            // child (036 §3 B1). The host owns the `DetailSession` + tag store, so
            // opening / prev-next / tag edits publish only to the host — this
            // `CollectionView` body (and the grid it renders) never observes that
            // state. The host raises the overlay off `NavModel.presentedItemID`.
            if let services = model.services {
                CollectionDetailHost(model: model, nav: nav, services: services)
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
            // Gate the subfolder chips on `isLoaded`: they read the same shared model
            // state as the grid, so showing them mid-switch would flash the PREVIOUS
            // collection's subfolders alongside the grid. (Drops route out of a
            // collection via the sidebar rows and per-cell "Add to" context menus.)
            if isLoaded, !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
        // New subfolder (from the header action or a chip's context menu).
        .nameEntryAlert(
            "New Subfolder",
            isPresented: $showNewSubfolder, text: $newSubfolderName, confirmLabel: "Create",
            onConfirm: { model.createFolder(name: $0, parent: newSubfolderParentID ?? collectionID) })
        // Rename a subfolder.
        .nameEntryAlert(
            "Rename Collection",
            isPresented: renameBinding, text: $renameText, confirmLabel: "Rename",
            onConfirm: { name in
                if let id = renameTargetID { model.renameFolder(id: id, to: name) }
                renameTargetID = nil
            },
            onCancel: { renameTargetID = nil })
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
        // Floating multi-select action bar (042). Sits BENEATH the full-window
        // detail overlay (hosted later in `body`'s ZStack), so it's hidden while a
        // detail page is open. Shown whenever the grid has a selection.
        .overlay(alignment: .bottom) {
            if model.selection.isSelecting { selectionBar }
        }
    }

    /// This screen's move/copy targets, memoized (012 · CQ 1A) so every eager
    /// per-cell context menu shares ONE computation, not N.
    private var moveTargets: MoveTargets {
        moveTargetsCache.targets(
            from: collectionID, folders: model.folders, unsortedID: model.unsortedFolderID)
    }

    /// The ASSET ids the selection bar's batch actions act on. `selection.ids` are
    /// membership ids (`CollectionItem.id`); the model methods take asset ids, so
    /// map through the current feed — the same lookup the detail / Quick Look path
    /// (`presentQuickLook`) does.
    private var selectedAssetIDs: [UUID] {
        model.items
            .filter { model.selection.ids.contains($0.item.id) }
            .map(\.asset.id)
    }

    /// The floating bottom "N selected" action bar (042), shown whenever the grid
    /// has a selection. An ADDITIVE second path to the grid's right-click menu:
    /// Clear, an overflow (`…`) menu carrying Move to / Add to / Set as Cover, and
    /// direct Remove / Delete buttons. Every button calls the SAME `IngestionModel`
    /// method the native `buildContextMenu` does, so the two paths never diverge.
    /// Styled to match Home / Search (`CollectionsGalleryView` / `LibrarySearch`).
    private var selectionBar: some View {
        let count = model.selection.ids.count
        return HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
            Button("Clear") { model.selectionStore.apply(.clear) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            // Overflow as a popover so it opens ABOVE the bar (`arrowEdge: .top`),
            // not clipped below the floating capsule the way a `Menu` would.
            Button { showMoreActions.toggle() } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .help("More actions")
            .popover(isPresented: $showMoreActions, arrowEdge: .top) {
                moreActionsMenu(count: count)
            }
            Button {
                model.removeFromFolder(assetIDs: selectedAssetIDs)
            } label: {
                Label("Remove \(count)", systemImage: "folder.badge.minus")
            }
            .labelStyle(.iconOnly)
            .help("Remove \(count) from collection")
            // `requestDelete` runs its own confirmation, so no extra dialog here.
            Button(role: .destructive) {
                model.requestDelete(assetIDs: selectedAssetIDs)
            } label: {
                Label("Delete \(count)", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Delete \(count)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 16)
    }

    /// The `…` overflow contents: Move to / Add to (nested destination menus) and
    /// Set as Cover (single-item only). Each action dismisses the popover.
    private func moreActionsMenu(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu("Move to") {
                destinationButtons {
                    model.moveToCollection(assetIDs: selectedAssetIDs, to: $0)
                    showMoreActions = false
                }
            }
            Menu("Add to") {
                destinationButtons {
                    model.copyToCollection(assetIDs: selectedAssetIDs, to: $0)
                    showMoreActions = false
                }
            }
            // Set as Cover is a single-item action (parity with the context menu's
            // `n == 1` gate).
            if count == 1, let assetID = selectedAssetIDs.first {
                Button("Set as Cover") {
                    model.setCollectionCover(collectionID: collectionID, assetID: assetID)
                    showMoreActions = false
                }
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(8)
        .frame(minWidth: 160, alignment: .leading)
    }

    /// The Move-to / Add-to destination buttons for the overflow menu: subfolders
    /// first, a divider, then roots — the same order as the native
    /// `targetSubmenu` in `MasonryGridHost`.
    @ViewBuilder
    private func destinationButtons(_ action: @escaping (UUID) -> Void) -> some View {
        let dests = moveTargets
        ForEach(dests.subfolders) { c in Button(c.name) { action(c.id) } }
        if !dests.subfolders.isEmpty, !dests.roots.isEmpty { Divider() }
        ForEach(dests.roots) { c in Button(c.name) { action(c.id) } }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } })
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
            // Create a subfolder under THIS collection (043) — the always-available
            // entry point (the chips only render once subfolders exist).
            Button {
                newSubfolderName = ""
                newSubfolderParentID = collectionID
                showNewSubfolder = true
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New subfolder in this collection")
        }
        // The visible Paste button was removed; ⌘V still pastes into this collection
        // via this hidden shortcut-only button.
        .background {
            Button("Paste", action: paste)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!model.isReady)
                .hidden()
        }
    }

    /// Live import feedback, re-homed from the old dropzone (3A): a compact progress
    /// bar + count while a drop/paste batch runs. The idle status line ("Library
    /// ready…") was removed — only active-batch progress shows now. Browser/Instagram
    /// sweeps report separately via `BulkSweepsView`.
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
        }
    }

    private var subfolderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.subfolders) { folder in
                    Button {
                        nav.drillIntoCollection(folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { subfolderMenu(folder) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The context menu for a subfolder chip (043): manage the subfolder without
    /// leaving this screen. A subfolder is never Unsorted, so all actions apply.
    @ViewBuilder
    private func subfolderMenu(_ folder: Collection) -> some View {
        Button("New Subfolder…") {
            newSubfolderName = ""
            newSubfolderParentID = folder.id
            showNewSubfolder = true
        }
        Button("Rename…") {
            renameText = folder.name
            renameTargetID = folder.id
        }
        CollectionMoveToMenu(
            folderID: folder.id, folders: model.folders, unsortedID: model.unsortedFolderID
        ) { model.moveFolder(id: folder.id, toParent: $0) }
        Divider()
        Button("Delete", role: .destructive) { model.deleteFolder(id: folder.id) }
    }

    private var grid: some View {
        GeometryReader { geo in
            Group {
                if isLoaded {
                    // 036 §2 A4 — the AppKit `NSCollectionView` grid, now the
                    // ONLY grid path: the old SwiftUI windowed path was deleted
                    // once AppKit became the default (`AtelierUseAppKitGrid`).
                    // Everything OUTSIDE `grid` (header, toolbar, chips, detail
                    // overlay, pane `.onDrop`) is unchanged.
                    appKitGrid(geo: geo)
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

    /// The AppKit `NSCollectionView` grid (036 §2 A1 · §4 A2), now the only grid
    /// path (§4 A4 deleted the old SwiftUI windowed path). A2 wires live selection
    /// / mouse / hover / keyboard / scroll / density through the coordinator, which
    /// subscribes to `selectionStore` directly and reconciles cell layers WITHOUT a
    /// body republish (the whole point). The config is a plain value rebuilt each
    /// body pass; the coordinator diffs `(itemsVersion, density)` + `collectionID`
    /// for layout and takes selection from the store, so a selection republish
    /// never relayouts. The interaction effect closures forward to the same
    /// model/view seams (`open`, `requestDeleteSelected`, `presentQuickLook`,
    /// density zoom).
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
            canReorder: model.sortMode(for: collectionID) == .manual,
            onReorderCommit: { payload, slot in
                handleSlotDrop(payload, insertAt: slot)
            },
            actionTargets: { model.actionTargets(forCellItemID: $0) },
            moveTargets: moveTargets,
            onMoveToCollection: { model.moveToCollection(assetIDs: $0, to: $1) },
            onCopyToCollection: { model.copyToCollection(assetIDs: $0, to: $1) },
            onSetCover: { model.setCollectionCover(collectionID: collectionID, assetID: $0) },
            onRemoveFromCollection: { model.removeFromFolder(assetIDs: $0) },
            onDelete: { model.requestDelete(assetIDs: $0) }))
    }

    /// Open the full-window detail page for `detail`: make it the grid lead cursor
    /// (so the ring / QuickLook / next-open align with it — 009 · 8A) and raise the
    /// overlay via `NavModel.presentedItemID` (the routing seam the grid click, the
    /// Return key, and the Space canvas all funnel through). The `CollectionDetailHost`
    /// picks up the id change and presents its `DetailSession` — the preview + tag
    /// loads happen there now, NOT on this model (036 §3 B1). The open is the
    /// deliberate "view" signal (007 G4).
    private func open(_ detail: CollectionItemDetail) {
        model.applySelection(.setLead(detail.item.id))
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

    // MARK: - Drag & drop (009 · N3)

    /// The ⌥-at-drop-time reader, isolated behind a protocol so move-vs-copy
    /// routing stays unit-testable (the routing itself lives in `routeDrop`).
    private static let modifierReader: ModifierReading = LiveModifierReader()

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

    /// Commit a reorder previewed on the grid (040): route the payload to the
    /// `slot` chosen by the live preview and apply the multi-block move. Only a
    /// same-collection, manual-sort drop is a reorder; cross-collection /
    /// non-manual drops are refused here — those moves go through the sidebar rows
    /// / "Move to" menus.
    private func handleSlotDrop(_ payload: AssetDragPayload, insertAt slot: Int) -> Bool {
        let target = DropTarget.slot(
            collectionID: collectionID, sortMode: model.sortMode(for: collectionID), index: slot)
        switch routeDrop(payload, onto: target, optionDown: Self.modifierReader.isOptionDown) {
        case let .reorder(assetIDs, insertAt):
            model.reorderItems(movingAssetIDs: assetIDs, insertAt: insertAt)
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
        // An INTERNAL drag also carries file promises since drag-out (011 ·
        // Cluster A), so it now matches this import target's [.image, .fileURL,
        // .url] via the promise machinery — importing our own promised file
        // would duplicate the asset. Anything carrying the app-private
        // `.assetIDs` payload is an internal drag: refuse it here. Checked on
        // BOTH channels because a promise drag's bridged provider registers no
        // types at all (193): the drag pasteboard catches the AppKit grid drag,
        // the provider check catches a SwiftUI-native `.assetIDs` drag.
        guard AssetDragPayload.fromDragPasteboard() == nil,
              !providers.contains(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.assetIDs.identifier)
              }) else { return false }
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

// MARK: - Detail overlay host (036 §3 B1)

/// Hosts the full-window item-detail overlay in its own view so the overlay's
/// state — the shown item, its preview placeholder, its tags — is observed HERE,
/// not by ``CollectionView``. That is the whole point of B1: opening the page and
/// stepping prev/next publish only to this host (via ``DetailSession`` +
/// ``AssetTagsStore``), so the grid `CollectionView` renders is never re-run per
/// step. (Before B1 those lived as `@Published` on `IngestionModel`, so every open
/// / step / tag edit re-ran the whole screen — root cause 3.)
///
/// Ownership note (deviation from the 036 §3 text, which put the `@StateObject` on
/// `CollectionView`): a classic `ObservableObject` `@StateObject`/`@ObservedObject`
/// subscribes its OWNER to `objectWillChange` regardless of which properties the
/// body reads — so holding the session on `CollectionView` would re-run the grid
/// on every step, the exact opposite of the goal. The session therefore lives on
/// this child; `CollectionView` renders the child but does not observe it.
private struct CollectionDetailHost: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    /// The overlay's state — one `@Published` for the shown item + its preview.
    @StateObject private var session: DetailSession
    /// The detail page's tags, on the shared asset-scoped store (the Space board +
    /// search overlays' path). Observed here so a chip edit repaints the overlay.
    @StateObject private var tags: AssetTagsStore

    init(model: IngestionModel, nav: NavModel, services: AppServices) {
        _model = ObservedObject(wrappedValue: model)
        _nav = ObservedObject(wrappedValue: nav)
        let tagStore = AssetTagsStore(services: services)
        // Collection chips mutate through the shared store, not `model` — bridge
        // the change back so the grid + counts refresh (041 · not just the chips).
        tagStore.onMembershipChanged = { [weak model] in model?.reloadAfterMembershipChange() }
        _tags = StateObject(wrappedValue: tagStore)
        _session = StateObject(wrappedValue: DetailSession(
            tags: tagStore,
            previewURL: { model.previewImageURL(forAsset: $0) },
            // 036 §3 B2: full-res source (content hash + on-disk blob URL) for the
            // LRU loader; `nil` for a media-less kind (no blob to decode).
            displaySource: { asset in
                guard let hash = asset.blobHash,
                      let url = model.blobURL(forAsset: asset) else { return nil }
                return (hash, url)
            }))
    }

    var body: some View {
        ZStack {
            if let state = session.state {
                detailOverlay(for: state)
                    .transition(.opacity)
            }
        }
        // Raise / drop the overlay off the shared route. `open(_:)` sets the id
        // AFTER this host exists, so `onChange` (not `initial`) fires: resolve the
        // item and present the session. Clearing the id (Back / auto-dismiss) tears
        // it down. The animation mirrors the old `withAnimation { presentedItemID }`.
        .onChange(of: nav.presentedItemID) { _, newID in
            // Track the overlay's lifecycle so a view-bump flush that fires on the
            // 3s debounce WHILE the overlay is up defers the Most-Viewed reorder
            // instead of reflowing the grid under the fade (036 §3 B4). Covers every
            // open source (all funnel through `presentedItemID`) and both close +
            // auto-dismiss.
            model.isDetailPresented = newID != nil
            if let newID {
                if let detail = model.items.first(where: { $0.item.id == newID }) {
                    withAnimation { session.present(detail, in: model.items) }
                }
            } else {
                withAnimation { session.dismiss() }
            }
        }
        // Auto-dismiss on delete (parity with the old `leadItem == nil` gate): a
        // content reload that removes the shown item closes the page. `contentsVersion`
        // is `@Published` and bumps on every load / move / reorder / delete.
        .onChange(of: model.contentsVersion) { _, _ in
            if let id = session.currentID,
               !model.items.contains(where: { $0.item.id == id }) {
                nav.presentedItemID = nil
            }
        }
        // Surface a tag write/read failure on the model's alert (mirrors the old
        // `IngestionModel` tag methods routing errors through `lastError`).
        .onChange(of: tags.lastError) { _, message in
            if let message {
                model.lastError = message
                tags.lastError = nil
            }
        }
    }

    /// Build the presentation-only ``ItemDetailView`` from the session state +
    /// this collection's `IngestionModel` context — full folder actions plus
    /// prev/next across `model.items`.
    @ViewBuilder
    private func detailOverlay(for state: DetailSession.State) -> some View {
        let detail = state.detail
        let hasSource = !(detail.source.originalURL ?? "").isEmpty
        // A media-less kind (003 · O1) has no blob on disk — disable the blob
        // actions rather than wiring them to a no-op.
        let hasBlob = model.blobURL(for: detail) != nil
        let index = model.items.firstIndex { $0.item.id == detail.item.id }
        ItemDetailView(
            asset: detail.asset,
            source: detail.source,
            blobURL: model.blobURL(for: detail),
            // The real internal identity (192): this host KNOWS the shown item's
            // collection, so its drag-out is a first-class internal drag (the
            // import guard refuses it; routing rules see the true source).
            dragPayload: AssetDragPayload(
                assetIDs: [detail.asset.id], sourceCollectionID: detail.item.collectionID),
            previewImage: state.previewImage,
            // 036 §3 B2: consume the loader's LRU-cached full-res image instead of
            // decoding our own per-step — `usesExternalImageLoader` suppresses
            // `ItemDetailView`'s internal decode (still used by Space / search).
            displayImage: state.displayImage,
            usesExternalImageLoader: true,
            // 036 §3 B3: feed the measured media-area size + zoom back so the session
            // decodes at the right tier (preview ≤1280 / FIT downsample / native on
            // zoom) instead of always materializing native.
            onDisplayTarget: { fit, zoom in
                session.updateDisplayTarget(fitLongSidePx: fit, zoom: zoom)
            },
            tags: tags.tags,
            onAddTag: { tags.add($0) },
            onRemoveTag: { tags.remove($0) },
            collections: tags.collections,
            allCollections: tags.allCollections,
            onAddToCollection: { tags.addToCollection($0) },
            onRemoveFromCollection: { tags.removeFromCollection($0) },
            onSetName: { tags.setName($0) },
            onSetNote: { tags.setNote($0) },
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
                        // Stepping mutates ONLY the session — no `IngestionModel`
                        // lead/selection write, so the grid does not re-render per
                        // step. The lead is synced back once on close.
                        session.step(to: model.items[target], in: model.items)
                        model.recordView(assetID: model.items[target].asset.id)
                    }
                }
            },
            onClose: { close() })
    }

    /// Close the page (Back / Escape): flush the coalesced view bumps, sync the
    /// grid lead once to wherever the user stepped to (prev/next kept it off the
    /// model), then drop the route — which tears down the session via the
    /// `presentedItemID` observer. The `.setLead` effect (a scroll) is discarded:
    /// the grid didn't scroll on close before B1 either — the store publish just
    /// reconciles the lead ring — and there is no scroll seam from this parent.
    ///
    /// The final `flushViewBumps()` runs while the overlay is still up, so its
    /// Most-Viewed reorder is DEFERRED into ``pendingReorderBumps`` rather than
    /// churning the grid mid-fade. Dropping the route flips `isDetailPresented`
    /// off (via the `onChange` above), and the animation's completion applies the
    /// reorder in place — the just-viewed item rises AFTER the fade, not under it
    /// (036 §3 B4). Was a full `loadContents` reload that blew the grid away.
    private func close() {
        model.flushViewBumps()
        if let id = session.currentID {
            model.applySelection(.setLead(id))
        }
        withAnimation { nav.presentedItemID = nil } completion: {
            model.applyDeferredMostViewedReorder()
        }
    }
}
