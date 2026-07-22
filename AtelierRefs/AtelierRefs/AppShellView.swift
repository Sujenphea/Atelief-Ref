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
//  sidebar destinations; Sweeps / Snapshots stay as sheets.
//

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
        .padding(.trailing, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.lg)
        .overlay(alignment: .bottomTrailing) { floatingAdd }
    }

    /// The panel root for the current sidebar selection. Browsing surfaces (Home +
    /// a Collection) wrap in `LibrarySearchable`, so the search field sits at the TOP
    /// of the panel persistently (Search is no longer a sidebar row) — global on Home,
    /// collection-scoped on a Collection.
    @ViewBuilder
    private var rootContent: some View {
        // Every pane is wrapped in `LibrarySearchable`, so the native `.searchable`
        // field is ALWAYS in the toolbar — the toolbar height (and thus the traffic
        // lights) then never shifts between panes. Search is global (`collectionID:
        // nil`) except on a Collection, which scopes it.
        switch nav.sidebarSelection {
        case .home, .search:
            LibrarySearchable(model: model, collectionID: nil) {
                CollectionsGalleryView(model: model, nav: nav)
            }
        case .capture:
            LibrarySearchable(model: model, collectionID: nil) {
                CapturePane(model: model, onOpenSweeps: { showSweeps = true })
            }
        case .settings:
            LibrarySearchable(model: model, collectionID: nil) {
                SettingsView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .collection(id):
            LibrarySearchable(model: model, collectionID: id) {
                CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
            }
        case let .space(id):
            LibrarySearchable(model: model, collectionID: nil) {
                spaceDestination(id)
            }
        }
    }

    /// The floating circular add affordance (Figma) — white glyph on ink.
    private var floatingAdd: some View {
        Menu {
            if case .collection(let id) = nav.sidebarSelection {
                Button("New Space from Collection") {
                    Task {
                        if let sid = await model.newSpaceFromCollection(id) { nav.openSpace(sid) }
                    }
                }
            }
            Button("Add Color…") {
                // Adds a neutral placeholder swatch to the active collection; the
                // detail/inspector edits the hex. (Add-Color/Link pickers relocate
                // here from the old toolbar — a follow-up wires the pickers.)
                model.addColor(hex: "#2C2C30")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(hex: 0x141416))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.Colors.inkPrimary))
                .elevation(.hover)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Routing

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .collection(let id):
            CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
        case .spaces:
            EmptyView()  // legacy route — Spaces now lives in the sidebar
        case .space(let id):
            spaceDestination(id)
        }
    }

    @ViewBuilder
    private func spaceDestination(_ id: UUID) -> some View {
        if let services = model.services, let store = model.store {
            SpaceView(model: model, nav: nav, spaceID: id, services: services, store: store)
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
                Text(model.captureEndpointRunning
                     ? "Listening on 127.0.0.1:\(model.capturePort)"
                     : "Endpoint unavailable (port \(model.capturePort) in use)")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Extension token").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.captureToken.isEmpty ? "—" : model.captureToken)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button { model.copyCaptureToken() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.captureToken.isEmpty)
            }

            Text("Paste this token into the AtelierRefs Chrome extension's options to "
                 + "authorize captures. It never leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
