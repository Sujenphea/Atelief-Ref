//
//  AppShellView.swift
//  AtelierRefs
//
//  004-P1 — the app shell that replaces the old 3-tab `TabView`. A
//  `NavigationStack` whose root is the Collections gallery and whose routes are
//  `.collection` / `.spaces` / `.space` (driven by `NavModel`). The app-level
//  affordances that used to be tabs — Spaces, Browser Capture, Sweeps — move to
//  the window toolbar so they're reachable from every screen. Native back /
//  ⌘[ / window title come for free.
//

import AtelierCore
import AtelierIngestion
import SwiftUI

struct AppShellView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @ObservedObject var gridPrefs: GridViewPreferences

    @State private var showCaptureInfo = false
    @State private var showSweeps = false

    var body: some View {
        NavigationStack(path: $nav.path) {
            CollectionsGalleryView(model: model, nav: nav)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .toolbar { appToolbar }
        .focusedSceneValue(\.navModel, nav)
        .focusedSceneValue(\.ingestionModel, model)
        // Publish the model as a focused OBJECT too (010 · Phase 1 undo): the Edit
        // menu observes it via `@FocusedObject` so Undo/Redo enablement + titles
        // refresh reactively as actions register/fire. `@FocusedValue` (above)
        // does NOT observe changes, so it alone left ⌘Z stuck disabled.
        .focusedSceneObject(model)
        .sheet(isPresented: $showSweeps) {
            sweepsSheet
        }
        .sheet(isPresented: $model.showSnapshots) {
            SnapshotsSheet(model: model)
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
        // The nav path is the single owner of "which collection is live": load the
        // top collection's contents on EVERY path change — push and pop alike. The
        // per-view `.task` only fires on a fresh push, so on back the shared
        // `model.items` used to stay on the deeper folder while the title updated
        // (the "back button shows the wrong items" bug). No `initial:` — the path
        // always starts empty and relaunch-restore populates it as a *change* this
        // catches, so firing on the initial frame would only add nav-lifecycle churn.
        .onChange(of: nav.path) { _, path in
            // Deferred to the NEXT runloop turn. `destination(for:)` reads `model`,
            // so publishing a model change while SwiftUI is mid-nav-update makes the
            // navigation observer re-fire in the same frame ("tried to update
            // multiple times per frame"). A `Task { @MainActor }` still drains
            // inside that transaction; `DispatchQueue.main.async` runs after the
            // current CATransaction commits, landing the publish on a clean frame.
            DispatchQueue.main.async { syncActiveCollection(path) }
        }
    }

    /// Point the shared model at whatever collection is on top of the nav stack and
    /// (re)load its contents. A no-op when the top route isn't a collection (spaces
    /// / the root gallery keep the last-loaded folder as the import target).
    private func syncActiveCollection(_ path: [AppRoute]) {
        guard case .collection(let id)? = path.last else { return }
        if model.selectedFolderID != id { model.selectedFolderID = id }
        model.loadContents(of: id)
    }

    // MARK: - Routing

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .collection(let id):
            CollectionView(model: model, nav: nav, gridPrefs: gridPrefs, collectionID: id)
        case .spaces:
            SpacesListView(model: model, nav: nav)
        case .space(let id):
            if let services = model.services, let store = model.store {
                SpaceView(model: model, nav: nav, spaceID: id, services: services, store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - App-level toolbar

    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { nav.openSpaces() } label: {
                Label("Spaces", systemImage: "square.on.square.dashed")
            }
            .help("Open your spaces")
        }
        ToolbarItem {
            Button { showSweeps = true } label: {
                Label("Sweeps", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Bulk import sweeps")
        }
        ToolbarItem {
            Button { showCaptureInfo.toggle() } label: {
                Label("Browser Capture", systemImage: "puzzlepiece.extension")
            }
            .popover(isPresented: $showCaptureInfo, arrowEdge: .bottom) {
                captureInfo
            }
        }
    }

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

    /// The capture endpoint status + the token to paste into the Chrome extension
    /// (relocated from the old `LibraryView` toolbar).
    private var captureInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Browser Capture", systemImage: "puzzlepiece.extension")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(model.captureEndpointRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.captureEndpointRunning
                     ? "Listening on 127.0.0.1:\(model.capturePort)"
                     : "Endpoint unavailable (port \(model.capturePort) in use)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Extension token")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.captureToken.isEmpty ? "—" : model.captureToken)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.copyCaptureToken()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.captureToken.isEmpty)
            }

            Text("Paste this token into the Atelier Chrome extension's options to authorize captures.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 320)
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
