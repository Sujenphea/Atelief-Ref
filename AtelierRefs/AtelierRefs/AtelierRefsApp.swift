//
//  AtelierRefsApp.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import AtelierCore
import SwiftUI

@main
struct AtelierRefsApp: App {
    // The single shared model, lifted to App level (010 · Phase 2) so BOTH the
    // main window and the Settings scene (⌘,) drive the same Library instance.
    @StateObject private var model = IngestionModel()
    // 037 — opens the grid bake-off window under `-grid-bakeoff`, and does
    // nothing otherwise. The whole spike lives in `Debug/`; this line is its
    // only footprint outside that folder.
    @NSApplicationDelegateAdaptor(GridBakeoffAppDelegate.self) private var bakeoffDelegate
    // 052 · A3 — the app-global Sparkle updater. `startingUpdater: true` boots the
    // updater at launch; the App menu's "Check for Updates…" command reads it.
    /// Grid view preferences (density, carousel grouping), lifted here for the same
    /// reason as `model`: Settings (⌘,) is a SEPARATE scene, so a `@StateObject` owned
    /// by `ContentView` would give the settings toggle its own instance and the grid
    /// would never see the change.
    @StateObject private var gridPrefs = GridViewPreferences()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, gridPrefs: gridPrefs)
        }
        // 006 — content runs full-height with the traffic lights overlaying the
        // sidebar rail (Figma); the standard title bar is hidden.
        .windowStyle(.hiddenTitleBar)
        // 004-P1 — a menu Back command (⌘[) that pops the current NavModel,
        // reaching it through the focused-scene value the shell publishes.
        .commands {
            // App-menu "Check for Updates…" (052 · A3), placed right after the
            // "About AtelierRefs" item. Observes the app-global updater so it
            // disables while a check is already in flight.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            // Standard Edit-menu undo/redo (010 · Phase 1), wired to the shared
            // model's app-level UndoManager via the focused scene value — the
            // default group targets the responder chain, which never sees our
            // model-owned manager, so we replace it.
            CommandGroup(replacing: .undoRedo) {
                UndoRedoCommands()
            }
            // View ▸ Sort (010 · Phase 2) — sort modes (007) act on the current
            // collection through the focused model.
            CommandGroup(after: .toolbar) {
                SortCommands()
            }
            // File ▸ New (⌘N, 214) — begins an inline draft in the sidebar: a new
            // collection when one is active, a new space when a space is active,
            // disabled otherwise. Replaces the default "New Window".
            CommandGroup(replacing: .newItem) {
                NewItemCommand()
            }
            CommandGroup(after: .sidebar) {
                BackCommand()
            }
            CommandGroup(after: .saveItem) {
                SnapshotCommands()
                // File ▸ Export Moodboard… (052 · B3) — exports the focused Space
                // board; disabled elsewhere.
                ExportMoodboardCommand()
                // File ▸ Export Contact Sheet… (052 · B4) — exports the focused
                // collection; disabled elsewhere.
                ExportContactSheetCommand()
                // File ▸ Export Web Page… (014 · S3) — exports the focused
                // collection as a self-contained index.html + assets folder;
                // disabled elsewhere, and while the collection is empty.
                ExportWebPageCommand()
            }
        }

        // The standard macOS Settings window (010 · Phase 2 · group 4): capture
        // token, library location, setup-guide replay.
        Settings {
            SettingsView(
                model: model, backup: model.backup, restore: model.restore,
                archive: model.archive, archiveImport: model.archiveImport,
                libraryStats: model.libraryStats,
                gridPrefs: gridPrefs, clipboard: model.clipboard)
        }
    }
}

/// View ▸ Sort commands — set the current collection's sort mode (007) via the
/// focused model. A checkmark marks the active mode.
private struct SortCommands: View {
    @FocusedValue(\.ingestionModel) private var model

    var body: some View {
        Menu("Sort By") {
            sortButton("Manual", .manual)
            sortButton("Newest", .newest)
            sortButton("Most Viewed", .mostViewed)
        }
        .disabled(model == nil)
    }

    private func sortButton(_ title: String, _ mode: SortMode) -> some View {
        Button {
            if let model { model.setSortMode(mode, for: model.selectedFolderID) }
        } label: {
            let active = model.map { $0.sortMode(for: $0.selectedFolderID) == mode } ?? false
            // A menu Button reserves the checkmark gutter itself, so show the
            // checkmark only when active — an empty `systemImage` string logs
            // "No symbol named '' found in system symbol set" on every render.
            if active {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Edit-menu Undo / Redo (⌘Z · ⇧⌘Z), reaching the shared model as a focused
/// OBJECT so the view re-renders on the model's `objectWillChange` — the enabled
/// state + titles then track `undoToken` as actions register / fire. (`@FocusedValue`
/// does not observe the object, which left the items stuck disabled.)
private struct UndoRedoCommands: View {
    @FocusedObject private var model: IngestionModel?

    var body: some View {
        Button(undoTitle) { model?.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(model?.canUndo ?? false))
        Button(redoTitle) { model?.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(model?.canRedo ?? false))
    }

    private var undoTitle: String {
        let name = model?.undoActionName ?? ""
        return name.isEmpty ? "Undo" : "Undo \(name)"
    }

    private var redoTitle: String {
        let name = model?.redoActionName ?? ""
        return name.isEmpty ? "Redo" : "Redo \(name)"
    }
}

/// File-menu backup commands (008 H3) — reach the shared model via the focused
/// scene value the shell publishes.
private struct SnapshotCommands: View {
    @FocusedValue(\.ingestionModel) private var model

    var body: some View {
        Button("Snapshot Now") { model?.snapshotNow() }
            .disabled(model?.snapshotManager == nil)
        Button("Restore from Snapshot…") { model?.showSnapshots = true }
            .disabled(model?.snapshotManager == nil)
    }
}

/// File ▸ New (⌘N, 214) — starts an inline sidebar draft keyed to the active
/// sidebar destination. Observes ``NavModel`` as a focused OBJECT so its title and
/// enabled state track `sidebarSelection` (a `@FocusedValue` wouldn't re-render).
private struct NewItemCommand: View {
    @FocusedObject private var nav: NavModel?

    var body: some View {
        Button(title) { begin() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!enabled)
    }

    /// Enabled only when a collection or a space is the active sidebar destination.
    private var enabled: Bool {
        switch nav?.sidebarSelection {
        case .collection, .space: return true
        default: return false
        }
    }

    private var title: String {
        switch nav?.sidebarSelection {
        case .space: return "New Space"
        default: return "New Collection"
        }
    }

    private func begin() {
        guard let nav else { return }
        // Reveal the sidebar first so the draft row is visible when the rail is
        // collapsed (e.g. while the item-detail overlay is up).
        nav.sidebarCollapsed = false
        switch nav.sidebarSelection {
        case .space:
            nav.sidebarDraft = .space
        case .collection:
            nav.sidebarDraft = .collection(parent: nil)
        default:
            break
        }
    }
}

/// The "Back" menu item — enabled only when there's somewhere to go back to.
private struct BackCommand: View {
    @FocusedValue(\.navModel) private var nav

    var body: some View {
        Button("Back") { nav?.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(nav?.path.isEmpty ?? true)
    }
}
