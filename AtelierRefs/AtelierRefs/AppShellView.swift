//
//  AppShellView.swift
//  AtelierRefs
//
//  006 — the split-view shell (Figma nodes 1:3 / 5:92 / 6:4). A custom two-column
//  layout: the ``SidebarView`` leading column (273pt expanded ↔ 60pt rail) + the
//  detail `panel` (an opaque `#212121` rounded inset the grid / detail live inside).
//  Replaces the 004-P1 `NavigationStack`-of-cover-cards. The sidebar owns the
//  top-level ``NavModel/sidebarSelection``; a `NavigationStack` inside the panel
//  keeps within-collection subfolder drill-down (⌘[ back) + the item-detail overlay.
//
//  App-level affordances that used to be toolbar tabs — Spaces, Capture — are now
//  sidebar destinations; Sweeps / Snapshots stay as sheets. Settings is NOT a
//  destination: the sidebar's gear opens the standard ⌘, window (the app's single
//  settings surface), so nothing here routes to ``SettingsView``.
//

import AppKit
import AtelierCore
import AtelierIngestion
import SwiftUI

struct AppShellView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @ObservedObject var gridPrefs: GridViewPreferences

    @State private var showSweeps = false
    /// Guards the one-shot load of the relaunch-seeded collection.
    @State private var didLoadSeededCollection = false

    var body: some View {
        VStack(spacing: 0) {
            if model.hasPendingRestore { pendingRestoreBanner }
            HStack(spacing: 0) {
                SidebarView(model: model, nav: nav)
                detailPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusedSceneValue(\.navModel, nav)
        .focusedSceneValue(\.ingestionModel, model)
        // Publish the model as a focused OBJECT too (010 · Phase 1 undo): the Edit
        // menu observes it via `@FocusedObject`.
        .focusedSceneObject(model)
        // Publish the nav model as a focused OBJECT (214) so the File ▸ New command
        // re-renders its enabled state / title as the sidebar selection changes —
        // `@FocusedValue` doesn't observe (same reason undo/redo uses the object).
        .focusedSceneObject(nav)
        .sheet(isPresented: $showSweeps) { sweepsSheet }
        .sheet(isPresented: $model.showSnapshots) { SnapshotsSheet(model: model) }
        // 012 · I5 — near-duplicate review. A sheet on the MAIN window, not a
        // Settings pane: its only action is a delete, and ⌘Z has to reach the same
        // undo stack the grid's delete registers on.
        .sheet(isPresented: $model.showDuplicates) { DuplicateReviewSheet(model: model) }
        // 024 · K2 — Help ▸ Keyboard Shortcuts (⌘/). The scope is resolved HERE, at
        // presentation, off the two pieces of route state that already say where the
        // user is; the sheet itself takes a plain value and knows nothing about `nav`.
        .sheet(isPresented: $nav.showShortcuts) {
            KeyboardShortcutsSheet(
                currentScope: KeyMap.scope(
                    forSidebar: nav.sidebarSelection,
                    isShowingItemDetail: nav.presentedItemID != nil)
            ) { nav.showShortcuts = false }
        }
        .alert(
            "Restore staged",
            isPresented: Binding(
                get: { model.restoreStagedMessage != nil },
                set: { if !$0 { model.restoreStagedMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.restoreStagedMessage = nil }
        } message: {
            Text(model.restoreStagedMessage ?? "")
        }
        .task { await model.refreshSweeps() }
        // Collapse the sidebar to the rail while the item-detail overlay is up
        // (frame 6:4), and restore it on close.
        .onChange(of: nav.presentedItemID) { _, id in
            withAnimation(Theme.Motion.snappy) { nav.sidebarCollapsed = id != nil }
        }
        // Load the relaunch-SEEDED collection's items once the folder list is known,
        // but only if it still exists (mirrors the 004 nav-restore one-shot).
        .onChange(of: model.folders, initial: true) { _, folders in
            guard !didLoadSeededCollection, !folders.isEmpty else { return }
            guard case .collection(let id) = nav.sidebarSelection else {
                didLoadSeededCollection = true
                return
            }
            guard folders.contains(where: { $0.id == id }) else { return }
            didLoadSeededCollection = true
            syncActiveCollection()
        }
        // Fall back to Home when the selected space disappears (deleting the open
        // space): nothing else resets a dangling `.space` selection, which left the
        // sidebar highlight-less and the panel on a zombie board. The last guard
        // skips the pre-first-load empty list — prune only when the space was just
        // removed, or a real (non-empty) load shows it missing.
        .onChange(of: model.spaces) { old, spaces in
            guard case .space(let id) = nav.sidebarSelection,
                  !spaces.contains(where: { $0.id == id }),
                  old.contains(where: { $0.id == id }) || !spaces.isEmpty
            else { return }
            nav.selectSidebar(.home)
        }
        // The active collection = the drilled-into subfolder (path) or the selected
        // one (sidebar). Load its contents on every change of either — push and pop
        // alike — deferred a runloop turn so a publish doesn't land mid-nav-update.
        .onChange(of: nav.path) { _, _ in
            DispatchQueue.main.async { syncActiveCollection() }
        }
        .onChange(of: nav.sidebarSelection) { _, _ in
            DispatchQueue.main.async { syncActiveCollection() }
        }
        // A write asked to be LOOKED at (099 · P3 / 6A). The undo inverses used to
        // assign `model.selectedFolderID` themselves, which is this view's decision,
        // not the model's: undoing a move raised in another collection repointed the
        // shared feed at the move's source, so the grid on screen fell back to its
        // "Loading collection" skeleton (`CollectionView.isLoaded`) and the next
        // paste landed somewhere nobody was looking. The model now publishes an
        // intent and the window honours it by NAVIGATING — which is what the user
        // asked for when they pressed ⌘Z, and what makes the restored items visible.
        //
        // The model already suppresses an intent for the collection it has loaded, so
        // the ordinary undo (same collection, same window) publishes nothing and this
        // never fires.
        .onChange(of: model.focusIntent) { _, intent in
            guard let intent else { return }
            guard nav.sidebarSelection != .collection(intent.collectionID) else { return }
            nav.openCollection(intent.collectionID)
        }
    }

    // MARK: - Pending restore

    /// The standing warning while a restore waits for a relaunch (008 · H5c).
    ///
    /// On the MAIN window rather than in Settings, because the window is where
    /// the discardable work happens — captures land, items get dragged, notes get
    /// typed — and the Settings label only reaches someone who already went
    /// looking. It stays until the app is relaunched: there is no dismiss, since
    /// the condition it describes doesn't go away by being acknowledged.
    private var pendingRestoreBanner: some View {
        Label(BackupTarget.restorePending, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 8)
            .background(Theme.Colors.warning.opacity(0.12))
            .accessibilityElement(children: .combine)
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        NavigationStack(path: $nav.path) {
            rootContent
                .navigationDestination(for: AppRoute.self) { destination(for: $0) }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .padding(.trailing, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
    }

    /// The panel root for the current sidebar selection. Browsing surfaces (Home +
    /// a Collection) wrap in `LibrarySearchable`, so the search field sits at the TOP
    /// of the panel persistently (Search is no longer a sidebar row) — global on Home,
    /// collection-scoped on a Collection.
    @ViewBuilder
    private var rootContent: some View {
        // Every pane is wrapped in `LibrarySearchable`, so the custom
        // `SearchToolbarField` is ALWAYS in the window toolbar (trailing) — the
        // toolbar height (and thus the traffic lights) then never shifts between
        // panes. Search is global (`collectionID: nil`) except on a Collection,
        // which scopes it.
        switch nav.sidebarSelection {
        case .home:
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: nil) {
                CollectionsGalleryView(model: model, nav: nav)
            }
        case .capture:
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: nil) {
                CapturePane(model: model, onOpenSweeps: { showSweeps = true })
            }
        // The shelf IS wrapped in `LibrarySearchable`, like every other pane, so
        // the toolbar height never shifts between panes — but a search run from
        // here is global and will never return an archived item (023 · A1). That
        // is the intended reading: searching leaves the shelf, it does not
        // search within it.
        case .shelf:
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: nil) {
                shelfDestination
            }
        case let .collection(id):
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: id) {
                CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
            }
        case let .space(id):
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: nil) {
                spaceDestination(id)
            }
        #if DEBUG
        // The token specimen sheet (see ``ThemeGalleryView``). Deliberately NOT wrapped
        // in `LibrarySearchable`: a search field over a page of swatches would be dead
        // chrome, and this pane is the one place where every other pane's chrome is the
        // subject rather than the frame.
        case .theme:
            ThemeGalleryView()
        #endif
        }
    }

    // The floating "+" is no longer here. A single shell-level button had to guess ONE
    // menu for whatever pane was showing: it offered "Add Color…" on Settings and
    // Capture, floated over the full-window item detail, and could never reach a Space
    // at all — `SpaceModel`, the only writer that reloads an open board, lives inside
    // `SpaceView`, below this. Each pane now floats its own via `.floatingAdd(...)`;
    // see `FloatingAddControl`.

    // MARK: - Routing

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .collection(let id):
            CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
        case .space(let id):
            spaceDestination(id)
        }
    }

    @ViewBuilder
    private var shelfDestination: some View {
        if let services = model.services {
            ShelfView(model: model, nav: nav, gridPrefs: gridPrefs, services: services)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func spaceDestination(_ id: UUID) -> some View {
        if let services = model.services, let store = model.store {
            SpaceView(model: model, nav: nav, spaceID: id, services: services, store: store)
                // Identity keyed to the space: `.space(A)` → `.space(B)` stays in the
                // same ViewBuilder branch, and the `@StateObject` `SpaceModel` only
                // builds on a fresh identity — without this the panel keeps showing
                // the previous space.
                .id(id)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Point the shared model at the active collection (drilled subfolder, else the
    /// sidebar selection) and (re)load its contents.
    private func syncActiveCollection() {
        let id: UUID
        if case .collection(let drilled)? = nav.path.last {
            id = drilled
        } else if case .collection(let selected) = nav.sidebarSelection {
            id = selected
        } else {
            return
        }
        if model.selectedFolderID != id { model.selectedFolderID = id }
        model.loadContents(of: id)
    }

    // MARK: - Sheets

    /// The Sweeps sheet's own header. `pageTitle` + `Spacing.md` + a
    /// ``DialogButtonStyle`` Done, matching ``DuplicateReviewSheet`` — the two sheets
    /// had titled themselves at different sizes (`bodyEmphasis` here, `pageTitle`
    /// there) and this one padded with a raw `12`.
    private var sweepsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sweeps").font(Theme.Typography.pageTitle)
                Spacer()
                Button("Done") { showSweeps = false }
                    .buttonStyle(DialogButtonStyle(width: .hug))
            }
            .padding(Theme.Spacing.md)
            Divider()
            BulkSweepsView(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

// MARK: - Capture pane

/// The sidebar's Capture destination — the browser-capture endpoint status + the
/// pairing token to paste into the Chrome extension (relocated from the old toolbar
/// popover), plus an entry into the bulk-import Sweeps sheet.
///
/// The pane kept the LOOK of that popover long after it stopped being one: a
/// `pageTitle` heading, system `Divider()`s, `.secondary` greys, stock push buttons
/// (the default one renders accent-filled, which was the most coloured chrome in an
/// app whose theme states it has no accent) and a 40pt inset no other pane used. It
/// now wears the same tokens as its three sibling panes:
///
///  · ``Theme/Typography/sectionTitle`` for the title, like Home / Collection / Space.
///  · Two `surface` cards at `Radius.card` — the app's raised-group idiom (`FanCard`,
///    `DuplicateReviewSheet`) — instead of rules between flat text.
///  · ``DialogRow`` labels and ``dialogFieldChrome()`` on the token, so the value you
///    are meant to copy looks like a value rather than a caption.
///  · ``DialogButtonStyle`` actions, which bring the `hoverControl` feedback every
///    other button in the panel gives.
private struct CapturePane: View {
    @ObservedObject var model: IngestionModel
    let onOpenSweeps: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Capture")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.inkPrimary)

                pairingCard
                sweepsCard
            }
            // Centred rather than pinned left: the column is narrower than the panel
            // by design (a token and two sentences do not want 900pt of measure), and
            // pinned to `topLeading` it read as content that had been cut off.
            .frame(maxWidth: CaptureLayout.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.xl)
        }
    }

    /// Endpoint + token — the two facts you need to pair a browser, in one card.
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Browser Capture")
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(Theme.Colors.inkPrimary)

            CaptureEndpointStatus(
                port: model.capturePort, running: model.captureEndpointRunning)

            DialogRow("Pairing token") {
                CaptureTokenText(token: model.captureToken)
                    .dialogFieldChrome()
                CaptureTokenCopyButton(model: model, icon: true, tokenised: true)
            }

            CaptureTokenExplainer()
        }
        .captureCardChrome()
    }

    /// The entry into the bulk-import sheet.
    private var sweepsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Bulk Import")
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(Theme.Colors.inkPrimary)

            Text("Sweep a Pinterest board you own, or your X bookmarks, from a "
                 + "session you're already logged into.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onOpenSweeps()
            } label: {
                Label("Bulk Import Sweeps…", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(DialogButtonStyle(width: .hug))
        }
        .captureCardChrome()
    }
}

/// The Capture pane's geometry. A `*Layout` struct rather than a literal at the call
/// site, per ``Theme``'s header — the pane's width was a bare `520` in a `.frame`.
private enum CaptureLayout {
    /// The content column's measure. Wide enough for the explainer to break into two
    /// lines rather than five, narrow enough that a 78-character token still truncates
    /// in the middle instead of stretching the card to the window.
    static let columnWidth: CGFloat = 520
}

private extension View {
    /// One of the pane's two `surface` cards. Not ``popoverChrome()``: that recipe
    /// carries the `hover` ELEVATION, which is how a popover separates itself from
    /// content it floats over. These cards sit IN the panel's own layout and cast no
    /// shadow — the `surface` fill over `panel` is already the separation.
    func captureCardChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline))
    }
}

// MARK: - Focused value (⌘[ Back reaches the current NavModel)

private struct NavModelFocusedKey: FocusedValueKey {
    typealias Value = NavModel
}

private struct IngestionModelFocusedKey: FocusedValueKey {
    typealias Value = IngestionModel
}

extension FocusedValues {
    var navModel: NavModel? {
        get { self[NavModelFocusedKey.self] }
        set { self[NavModelFocusedKey.self] = newValue }
    }

    /// The shared model, so menu commands (Snapshot Now / Restore…) reach it.
    var ingestionModel: IngestionModel? {
        get { self[IngestionModelFocusedKey.self] }
        set { self[IngestionModelFocusedKey.self] = newValue }
    }
}
