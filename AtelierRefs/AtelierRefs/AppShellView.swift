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
        HStack(spacing: 0) {
            SidebarView(model: model, nav: nav)
            detailPanel
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
        case let .collection(id):
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: id) {
                CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
            }
        case let .space(id):
            LibrarySearchable(model: model, gridPrefs: gridPrefs, nav: nav, collectionID: nil) {
                spaceDestination(id)
            }
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

    private var sweepsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sweeps").font(.headline)
                Spacer()
                Button("Done") { showSweeps = false }
            }
            .padding(12)
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
private struct CapturePane: View {
    @ObservedObject var model: IngestionModel
    let onOpenSweeps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Browser Capture", systemImage: "puzzlepiece.extension")
                .font(.title2).bold()

            HStack(spacing: 6) {
                Circle()
                    .fill(model.captureEndpointRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(CaptureCopy.endpointStatus(
                        port: model.capturePort, running: model.captureEndpointRunning))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Extension token").font(.caption).foregroundStyle(.secondary)
            HStack {
                CaptureTokenText(token: model.captureToken, style: .callout)
                Spacer()
                CaptureTokenCopyButton(model: model, icon: true)
            }

            CaptureTokenExplainer()

            Divider()

            Button {
                onOpenSweeps()
            } label: {
                Label("Bulk Import Sweeps…", systemImage: "square.and.arrow.down.on.square")
            }

            Spacer()
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
