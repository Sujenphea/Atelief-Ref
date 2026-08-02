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
    /// The app-wide export controller (052 · B4), injected on `AppShellView`.
    /// Drives the File-menu contact-sheet export; the selection-bar button reads
    /// it from the environment directly.
    @EnvironmentObject private var exportController: ExportController
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
    /// Which overflow section is expanded (accordion — at most one). `nil` = both
    /// collapsed, the state the popover reopens in.
    @State private var expandedMoreSection: MoreSection?
    /// The natural height of the currently-expanded destination list, measured so
    /// the capped `ScrollView` can size to `min(content, 240)` — a bare `ScrollView`
    /// reports no ideal height in a content-sized popover and collapses to zero.
    @State private var destListHeight: CGFloat = 0
    /// The live grid viewport width, captured from the grid's `GeometryReader`, so
    /// the toolbar / ⌘+/⌘− density controls can clamp against the current width
    /// (011-B2 · 16A) without their own geometry reader.
    @State private var gridWidth: CGFloat = 1

    // The native Quick Look panel driver (011-B3): spacebar peeks the selection.
    @State private var quickLook = QuickLookController()

    // Subfolder RENAME from this screen (043). Create now lives only in the sidebar
    // collection tree's "New Subfolder…" (222) — the header button was removed (200).
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    private static let gridSpacing: CGFloat = Theme.Spacing.sm
    // The gap between the scroll-away header band and the first row (222) — the
    // layout solves items at `topInset + headerHeight`, so this IS the header→grid
    // spacing, restored to the pre-222 12pt.
    private static let gridTopInset: CGFloat = Theme.Spacing.md
    // The 24pt content margin (200), folded into the grid layout as `contentInsets`
    // (not a SwiftUI `.padding`) so the collection view spans the panel edge-to-edge
    // and the marquee background covers the margins + the empty area below the grid.
    // The skeleton path re-applies it as a plain padding; the width-keyed density /
    // zoom clamps subtract it so column math is unchanged from the pre-200 inset.
    private static let contentMargin: CGFloat = Theme.Spacing.xl

    /// The measured natural height of the header content (222), fed to the grid so
    /// the reserved header band hugs the row instead of a fixed guess. Seeded near
    /// the real value so the first solve doesn't overlap the top row before the
    /// measurement settles.
    @State private var headerHeight: CGFloat = 24

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

    /// The collection an import triggered RIGHT NOW must target.
    ///
    /// Not simply `collectionID`: this screen has no collection-keyed `.id(...)`
    /// (deliberately — the AppKit grid host is reused across switches rather than
    /// torn down), so SwiftUI keeps ONE view identity for every collection. The
    /// hidden ⌘V button's action closure is registered against that identity and is
    /// NOT re-registered when the struct is rebuilt with a new `collectionID` — it
    /// stays bound to whichever collection was showing when the shortcut was first
    /// installed. A paste then imported into the collection open at LAUNCH, no
    /// matter what the sidebar said (verified in the running app: `paste()` saw a
    /// stale `collectionID` while `selectedFolderID` was already correct).
    ///
    /// `nav` is a reference type, so even a stale closure holds the LIVE nav model:
    /// reading the selection here — at invocation, not at capture — is always
    /// current. Falls back to `collectionID` if the selection isn't a collection.
    private var importTargetID: UUID {
        Self.resolveImportTarget(
            path: nav.path, sidebar: nav.sidebarSelection, fallback: collectionID)
    }

    /// The pure half of ``importTargetID``, so the resolution order is unit-tested
    /// rather than only observable in a running app. Mirrors
    /// `AppShellView.syncActiveCollection`: a drilled subfolder wins over the
    /// sidebar selection, and anything that isn't a collection (Home / a Space /
    /// Settings) leaves `fallback` in charge.
    static func resolveImportTarget(
        path: [AppRoute], sidebar: SidebarItem, fallback: UUID
    ) -> UUID {
        if case .collection(let drilled)? = path.last { return drilled }
        if case .collection(let selected) = sidebar { return selected }
        return fallback
    }

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
        // Expose this collection's contact-sheet export to the File-menu command
        // (052 · B4), enabled only while a collection is focused.
        .focusedSceneValue(\.exportContactSheet, ExportContactSheetAction(run: runContactSheetExport))
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
        // The title row now lives INSIDE the grid so it scrolls away with the
        // content (222); subfolder navigation lives in the sidebar's collection tree
        // (the in-page chip row was a duplicate, so it's gone).
        //
        // No outer `.padding` here (200): the 24pt content margin is folded INTO the
        // grid layout (`contentInsets`) so the collection view spans the panel edge-
        // to-edge and the marquee background covers the margins + the empty area
        // below a short grid. The skeleton path keeps an explicit padding of its own.
        grid
            // ⌘V pastes into this collection — a hidden shortcut-only button, kept in
            // the SwiftUI key path (the header's create button is the other entry).
            .background {
                Button("Paste", action: paste)
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(!model.isReady)
                    .hidden()
            }
            // Measure the header's natural height off-screen so the AppKit header
            // band (222) hugs the row; hidden + non-interactive.
            .background(alignment: .topLeading) {
                headerContent
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        let next = h.rounded(.up)
                        if abs(headerHeight - next) > 0.5 { headerHeight = next }
                    }
            }
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
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(
                        Theme.Colors.selectionMark,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(Theme.Spacing.xs)
                    .allowsHitTesting(false)
            }
        }
        // Floating multi-select action bar (042). Sits BENEATH the full-window
        // detail overlay (hosted later in `body`'s ZStack), so it's hidden while a
        // detail page is open. The import indicator floats just above it, so an
        // in-flight batch never reflows the header (222).
        .overlay(alignment: .bottom) {
            VStack(spacing: Theme.Spacing.sm) {
                importIndicator
                if model.selection.isSelecting { selectionBar }
            }
            // The selection bar's own chrome supplies the bottom inset when it's up;
            // otherwise the lone import pill needs its own.
            .padding(.bottom, model.selection.isSelecting ? 0 : Theme.Spacing.lg)
        }
        // The floating "+" (moved down from the shell). Hidden while the full-window
        // item detail is up: this is an overlay on the PANE, and the detail host is a
        // later sibling in `body`'s ZStack, so a visible "+" would float over a page
        // it can add nothing to.
        .floatingAdd(isPresented: nav.presentedItemID == nil, items: addItems)
    }

    /// What "+" offers on a collection: the three ways content enters it, then — below
    /// a rule, because it's a different kind of act — promoting the whole collection to
    /// a board.
    ///
    /// Every entry resolves its target through `resolve()` AT INVOCATION rather than
    /// capturing `importTargetID` when the menu is built, for the reason
    /// ``importTargetID`` documents at length: this screen has one view identity across
    /// every collection, so a closure can outlive the `collectionID` it was built with.
    /// `nav` is a reference type, so reading it inside the closure is always current.
    private var addItems: [FloatingAddItem] {
        let nav = self.nav
        let fallback = collectionID
        let resolve = {
            Self.resolveImportTarget(
                path: nav.path, sidebar: nav.sidebarSelection, fallback: fallback)
        }
        return [
            .action("Import Images…", systemImage: "photo.badge.plus") {
                let target = resolve()
                ImportFilesPanel.present { urls in
                    model.run(inputs: IngestionModel.fileInputs(urls, into: target))
                }
            },
            .popover("Add Link…", systemImage: "link.badge.plus") { dismiss in
                AddLinkForm(
                    onAdd: { model.addLink(url: $0, into: resolve()) }, onDismiss: dismiss)
            },
            .popover("Add Color…", systemImage: "paintpalette") { dismiss in
                AddColorForm(
                    onAdd: { model.addColor(hex: $0, into: resolve()) }, onDismiss: dismiss)
            },
            .separator,
            .action("New Space from Collection", systemImage: "square.on.square") {
                let target = resolve()
                Task {
                    if let sid = await model.newSpaceFromCollection(target) { nav.openSpace(sid) }
                }
            },
        ]
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

    /// Copy the current selection to the pasteboard (Edit ▸ Copy / ⌘C, 052 · B1) in
    /// GRID order, via the shared grid-copy path.
    private func copySelectionToPasteboard() {
        model.copySelectedToPasteboard(from: model.items, selection: model.selection.ids)
    }

    /// The File-menu contact-sheet export (052 · B4): selection-or-whole-collection
    /// with default settings (PDF single page, captions). The popover in the
    /// selection bar is where format / columns change.
    private func runContactSheetExport() {
        let mapping = ContactSheetExport.map(
            details: ContactSheetExport.rows(items: model.items, selectedIDs: model.selection.ids),
            config: ContactSheetConfig(),
            imageURL: { model.previewImageURL(forAsset: $0) })
        exportController.requestExport(
            mapping: mapping, config: ExportConfig(), suggestedName: model.name(for: collectionID))
    }

    /// The floating bottom "N selected" action bar (042), shown whenever the grid
    /// has a selection. An ADDITIVE second path to the grid's right-click menu:
    /// Clear, an overflow (`…`) menu carrying Move to / Add to / Set as Cover, and
    /// direct Remove / Delete buttons. Every button calls the SAME `IngestionModel`
    /// method the native `buildContextMenu` does, so the two paths never diverge.
    /// Styled to match Home / Search (`CollectionsGalleryView` / `LibrarySearch`).
    private var selectionBar: some View {
        let count = model.selection.ids.count
        return HStack(spacing: 2) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .padding(.trailing, 10)
            SelectionBarButton("xmark", help: "Clear selection") {
                model.selectionStore.apply(.clear)
            }
            // `requestDelete` runs its own confirmation, so no extra dialog here.
            SelectionBarButton("trash", help: "Delete \(count)", role: .destructive) {
                model.requestDelete(assetIDs: selectedAssetIDs)
            }
            SelectionBarButton("folder.badge.minus",
                               help: "Remove \(count) from collection") {
                model.removeFromFolder(assetIDs: selectedAssetIDs)
            }
            // Contact-sheet export of the selection (052 · B4) — its own config
            // popover, opening ABOVE the floating bar like the overflow. The ring
            // shows progress + Cancel while a sheet renders.
            ContactSheetExportButton(model: model, collectionID: collectionID)
            ExportProgressRing()
            // Overflow as a popover so it opens ABOVE the bar (`arrowEdge: .top`),
            // not clipped below the floating capsule the way a `Menu` would.
            Button {
                // Reopen collapsed every time (accordion resets on open).
                if !showMoreActions { expandedMoreSection = nil }
                showMoreActions.toggle()
            } label: {
                SelectionBarIcon(systemName: "ellipsis")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("More actions")
            .popover(isPresented: $showMoreActions, arrowEdge: .top) {
                moreActionsMenu(count: count)
            }
        }
        .selectionBarChrome()
    }

    /// Which overflow destination section is open. Accordion — at most one.
    private enum MoreSection { case move, add }

    /// The `…` overflow contents: collapsible Move to / Add to accordion sections
    /// (each a scrollable, height-capped destination list) and a single-item Set as
    /// Cover. Both sections start collapsed; opening one collapses the other. Every
    /// action still calls the SAME `IngestionModel` method as the context menu.
    private func moreActionsMenu(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SelectionMenuSectionHeader(
                "Move to", isExpanded: expandedMoreSection == .move) { toggleSection(.move) }
            if expandedMoreSection == .move { destinationList(copy: false) }

            SelectionMenuSectionHeader(
                "Add to", isExpanded: expandedMoreSection == .add) { toggleSection(.add) }
            if expandedMoreSection == .add { destinationList(copy: true) }

            // Set as Cover is a single-item action (parity with the context menu's
            // `n == 1` gate) — a leaf row, always visible, never collapsed.
            if count == 1, let assetID = selectedAssetIDs.first {
                Rectangle().fill(Theme.Colors.hairline)
                    .frame(height: 1).padding(.vertical, 3)
                SelectionMenuRow("Set as Cover", systemImage: "photo") {
                    model.setCollectionCover(collectionID: collectionID, assetID: assetID)
                    showMoreActions = false
                }
            }
        }
        .selectionMenuChrome()
    }

    /// Accordion toggle: collapse if already open, else open this one (which closes
    /// the other). Animated with the app's standard expand/collapse spring.
    private func toggleSection(_ section: MoreSection) {
        withAnimation(Theme.Motion.snappy) {
            expandedMoreSection = expandedMoreSection == section ? nil : section
        }
    }

    /// The whole collection hierarchy, flattened + indented — every collection is a
    /// Move to / Add to target (roots in gallery order, children in manual order).
    /// The current collection is included but rendered disabled (greyed) below.
    private var moveTargetTree: [MoveTargetNode] {
        CollectionTargets.moveTargetTree(
            folders: model.folders, unsortedID: model.unsortedFolderID)
    }

    /// One section's destination list: the full collection tree as indented rows.
    /// Capped at 240pt and scrolled, since the library's collection count is
    /// unbounded.
    @ViewBuilder
    private func destinationList(copy: Bool) -> some View {
        let nodes = moveTargetTree
        if nodes.isEmpty {
            SelectionMenuRow("No collections", isEnabled: false)
        } else {
            // A bare `ScrollView` reports no ideal height in a content-sized popover
            // and collapses to zero (no rows show). Measure the content's natural
            // height (it lays out full-size on the unbounded scroll axis regardless
            // of the ScrollView's own frame) and pin the ScrollView to
            // `min(content, 240)` — shrink-to-fit for short lists, scroll past 240.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(nodes) { node in
                        SelectionMenuRow(
                            node.collection.name, indent: node.depth,
                            isEnabled: node.collection.id != collectionID) {
                            moveOrCopy(copy: copy, to: node.collection.id)
                        }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: MenuListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(destListHeight, 240))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(MenuListHeightKey.self) { destListHeight = $0 }
        }
    }

    /// Run the chosen destination action on the current selection and dismiss.
    private func moveOrCopy(copy: Bool, to id: UUID) {
        if copy {
            model.copyToCollection(assetIDs: selectedAssetIDs, to: id, from: collectionID)
        } else {
            model.moveToCollection(assetIDs: selectedAssetIDs, to: id)
        }
        showMoreActions = false
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } })
    }

    /// The title row. Hosted INSIDE the grid's scroll region (222) so it scrolls
    /// away with the content like Home, instead of pinning above the grid. Natural
    /// height — the band is sized to it (see `headerHeight`), not a fixed guess.
    ///
    /// PURELY non-interactive display content (title + count): the New Subfolder
    /// button was removed (200) so the whole header band can fall through to the
    /// grid's marquee background (`MasonryHeaderContainer.hitTest` → nil). Subfolder
    /// creation lives in the sidebar collection tree's "New Subfolder…" (222).
    private var headerContent: some View {
        HStack(spacing: 10) {
            Text(model.name(for: collectionID))
                .font(Theme.Typography.sectionTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            // The title tracks `collectionID` and is always correct, but the count
            // reads the shared `items` — redact it until this collection's load
            // resolves so it can't show the previous collection's count on switch.
            Text("\(isLoaded ? model.items.count : 0) items")
                .font(Theme.Typography.body).foregroundStyle(.secondary)
                .redacted(reason: isLoaded ? [] : .placeholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live import feedback as a FLOATING pill (222), so a drop/paste batch's
    /// progress no longer reflows the header. Only active-batch progress shows;
    /// browser/Instagram sweeps report separately via `BulkSweepsView`.
    @ViewBuilder
    private var importIndicator: some View {
        // The pill is shared with the Space board (059 · SP3 / 5A) so both surfaces
        // report a drop/paste batch identically.
        ImportProgressPill(progress: model.progress)
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
                    // skeleton, never the previous collection's items. The header
                    // rides above it (in SwiftUI here; it moves into the grid's own
                    // scroll region once loaded) so the title never blinks out on a
                    // collection switch (222).
                    ScrollView {
                        VStack(alignment: .leading, spacing: Self.gridTopInset) {
                            headerContent
                            gridSkeleton(width: geo.size.width - 2 * Self.contentMargin)
                        }
                        // The loaded grid folds the 24pt margin into its layout (200);
                        // the skeleton is plain SwiftUI, so it re-applies it here to
                        // match the inset content position.
                        .padding(.horizontal, Self.contentMargin)
                        .padding(.top, Self.contentMargin)
                    }
                }
            }
            // Capture the CONTENT width (panel minus the 200 margins) for the toolbar
            // / ⌘ density clamp, so it matches the width the grid lays columns out in.
            // Guarded to a real change (not subpixel wobble) so a geometry read inside
            // a ScrollView can't feed a re-render → re-measure loop.
            .onChange(of: geo.size.width, initial: true) { _, w in
                let contentW = w - 2 * Self.contentMargin
                if abs(gridWidth - contentW) > 0.5 { gridWidth = contentW }
            }
        }
        .overlay {
            if isLoaded, model.items.isEmpty {
                ContentUnavailableView(
                    "No items yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Drop or paste images to add them to this collection."))
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
                        RoundedRectangle(cornerRadius: Theme.Radius.tile)
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
            // The DISPLAY list, not the raw feed: with carousel grouping on, each
            // multi-image post contributes one tile (307).
            items: model.displayItems,
            itemsVersion: model.itemsVersion,
            postGroups: model.postGroups,
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
            onCopy: { copySelectionToPasteboard() },
            onQuickLook: { presentQuickLook() },
            onZoomIn: { gridPrefs.zoomIn(forWidth: geo.size.width - 2 * Self.contentMargin) },
            onZoomOut: { gridPrefs.zoomOut(forWidth: geo.size.width - 2 * Self.contentMargin) },
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
            onCopyToCollection: { model.copyToCollection(assetIDs: $0, to: $1, from: collectionID) },
            onSetCover: { model.setCollectionCover(collectionID: collectionID, assetID: $0) },
            onRemoveFromCollection: { model.removeFromFolder(assetIDs: $0) },
            onDelete: { model.requestDelete(assetIDs: $0) },
            onToggleExpand: { model.toggleExpansion(forItem: $0) },
            expandedPosts: model.expandedPosts,
            // 069 — hand the keyboard to the detail page while it is up, so the grid
            // behind it stops eating the page's arrows. Off the ROUTE, not off
            // `model.isDetailPresented`: that flag is deliberately un-`@Published`
            // (036 §3 B4) and is written from `CollectionDetailHost`'s `onChange`, so a
            // body reading it could render before it was set. `nav.presentedItemID` is
            // the published truth this body already observes.
            isDetailPresented: nav.presentedItemID != nil,
            // 222 — the title row scrolls away inside the grid's own scroll region,
            // its band sized to the row's measured natural height.
            header: AnyView(headerContent),
            headerHeight: headerHeight,
            // 200 — the 24pt content margin lives in the layout (not a SwiftUI
            // `.padding`), so the collection view fills the panel and the marquee
            // background covers the margins + the empty area below the last row.
            contentInsets: NSEdgeInsets(
                top: Self.contentMargin, left: Self.contentMargin,
                bottom: Self.contentMargin, right: Self.contentMargin)))
        // The preference is persisted on `gridPrefs`, but the derivation lives where
        // `items` does, so mirror it onto the model (307). Setting it re-derives the
        // display list AND bumps `itemsVersion`, which is what invalidates the
        // masonry cache — the tile count changed even though the items did not.
        .onAppear { mirrorGroupCarousels() }
        .onChange(of: gridPrefs.groupCarousels) { _, _ in mirrorGroupCarousels() }
    }

    /// Copy the persisted grouping preference onto the model, but only when it
    /// actually differs. `model.groupCarousels` is `@Published` (that publish is what
    /// re-runs this body with the new display list), and `@Published` fires on every
    /// assignment regardless of equality — so an unguarded `onAppear` would invalidate
    /// the whole screen once per navigation to say nothing changed.
    private func mirrorGroupCarousels() {
        if model.groupCarousels != gridPrefs.groupCarousels {
            model.groupCarousels = gridPrefs.groupCarousels
        }
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
                        .font(Theme.Typography.caption).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        // NOT `selectionMark`: this is a count BADGE, and white-on-
                        // white would erase its own label. A raised dark chip is the
                        // monochrome equivalent of "stands off the artwork".
                        .background(Capsule().fill(Theme.Colors.surface))
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
            // The SAME target the decoded inputs above bake in, so both halves of a
            // paste/drop agree. This used to read `model.selectedFolderID` inside
            // `ingestRemoteImage`, which lags the sidebar by a runloop hop.
            model.ingestRemoteImage(from: webURL, into: importTargetID)
        } else {
            model.reportUnreadableDrop()
        }
    }

    private func paste() {
        guard model.isReady else { return }
        let pasteboard = NSPasteboard.general
        let inputs = DirectInputReader.inputs(
            from: pasteboard, into: importTargetID, now: Date())
        dispatch(inputs: inputs, webURL: ImportPasteboard.firstWebURL(on: pasteboard))
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
        let target = importTargetID
        // The array crosses to a background decode. `NSItemProvider`'s load APIs are
        // documented thread-safe, and SwiftUI hands this list over and never touches
        // it again — but neither fact is visible to the compiler through a closure
        // parameter it does not own, so the transfer is asserted here.
        nonisolated(unsafe) let toDecode = providers
        Task {
            let decoded = await DirectInputReader.inputs(
                from: toDecode, into: target, now: Date())
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
            //
            // Video is excluded even though it HAS a blob: the media area draws it
            // with `VideoPlayer` and never reads `displayImage`, so handing the
            // .mp4 to ImageIO is a guaranteed failed decode — one file open + probe
            // per video opened AND per video preloaded as a prev/next neighbour,
            // logged as `CGImageSourceCreateThumbnailAtIndex … 'n/a ' … [-50]`.
            // Link / tweet stay in: their blob is a still image (og:image, captured
            // card) that the media area does draw.
            displaySource: { asset in
                guard asset.kind != .video,
                      let hash = asset.blobHash,
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
                    // The RUN, not the raw feed (069): this list is both what the pager
                    // steps and what the session preloads around, so the two must be the
                    // same list or every step warms the wrong neighbour.
                    withAnimation { session.present(detail, in: model.detailRun) }
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
        // The page's position in the RUN (069) — one dictionary lookup, where this was a
        // linear scan of `items` on every body pass (and over the wrong list).
        let index = model.detailRunIndex(of: detail.item.id)
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
                ItemDetailNavigator(index: i, count: model.detailRun.count) { delta in
                    let run = model.detailRun
                    let target = i + delta
                    if run.indices.contains(target) {
                        // Stepping mutates ONLY the session — no `IngestionModel`
                        // lead/selection write, so the grid does not re-render per
                        // step. The lead is synced back once on close.
                        session.step(to: run[target], in: run)
                        model.recordView(assetID: run[target].asset.id)
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
            // The overlay steps through EVERY item, including members the grid is
            // collapsing, so the id it closes on may not be a tile (307). Land the
            // cursor on the tile that stands for it instead of on nothing.
            model.applySelection(.setLead(model.displayTile(for: id)))
        }
        withAnimation { nav.presentedItemID = nil } completion: {
            model.applyDeferredMostViewedReorder()
        }
    }
}
