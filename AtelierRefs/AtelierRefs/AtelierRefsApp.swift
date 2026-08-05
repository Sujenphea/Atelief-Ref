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
            // Edit ▸ Favorite (⌘D, 011 · U5) — stars the grid selection through
            // the focused model. Placed after the pasteboard verbs so it sits with
            // the other selection-scoped actions rather than beside Undo.
            CommandGroup(after: .pasteboard) {
                FavoriteCommand()
                // Edit ▸ Remove / Delete (022 · D5) — the two verbs, named for the
                // surface that has focus, so both are discoverable and ⌘⌫ is visible
                // where macOS users look for it.
                DeleteCommands()
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
                // File ▸ Review Duplicates… (012 · I5) — opens the review sheet on
                // the main window. Review-only: it proposes, the user disposes.
                DuplicatesCommand()
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
            // Help ▸ Keyboard Shortcuts (⌘/, 024 · K2) — the app's ~30 bindings had
            // no listing anywhere in the UI. AFTER the default Help item rather than
            // replacing it: this phase adds a menu item, it does not remove one.
            CommandGroup(after: .help) {
                KeyboardShortcutsCommand()
            }
        }

        // The standard macOS Settings window (010 · Phase 2 · group 4): capture
        // token, library location, setup-guide replay.
        Settings {
            SettingsView(
                model: model, backup: model.backup, restore: model.restore,
                verify: model.verify,
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

/// Edit ▸ Favorite / Remove from Favorites (⌘D, 011 · U5).
///
/// A focused OBJECT, not a `@FocusedValue`, for the same reason as
/// ``UndoRedoCommands``: the title and enabled state track the model's selection
/// and its loaded rows, and only an observed object re-renders the menu item when
/// those change.
///
/// The title states the ⌘D rule out loud: it says "Favorite" whenever the press
/// would star something — including over a MIXED selection, which stars the rest
/// rather than flipping each item — and "Remove from Favorites" only when every
/// target is already starred.
private struct FavoriteCommand: View {
    @FocusedObject private var model: IngestionModel?

    var body: some View {
        Button(title) { model?.toggleFavoriteSelected() }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!(model?.canToggleFavorite ?? false))
    }

    private var title: String {
        (model?.favoriteActionWouldStar ?? true) ? "Favorite" : "Remove from Favorites"
    }
}

// MARK: - Edit ▸ Remove / Delete (022 · D5)

/// The two delete verbs as the FOCUSED surface means them.
///
/// A focused VALUE published by each pane rather than a read of the shared model,
/// because "where you are looking" is exactly what the model does not know: it holds
/// the collection grid's selection, so a menu command reading it would remove a board's
/// tiles from a collection, or destroy the grid's selection while a board had focus.
/// Every pane that owns a delete verb publishes one of these; a pane that has none
/// (Capture) publishes nothing and both items disable.
///
/// Home publishes one too, with `canRemove: false` — a collection has no container to
/// be removed from, so ⌫ there explains itself and Delete does the work. Home is the
/// one surface whose ⌫ reaches nothing at all rather than a lesser verb (345).
struct DeleteVerbs {
    /// What ⌫ removes FROM, in words — "Remove from Collection" on a grid, "Remove
    /// from Board" on a canvas. The menu says where, because that is the only part of
    /// the rule that changes between surfaces.
    let removeTitle: String
    /// Whether the remove verb applies here at all. `false` in search (a hit has no
    /// container) and in Unsorted (the fallback every removal re-homes into).
    let canRemove: Bool
    let remove: () -> Void
    let destroy: () -> Void
}

private struct DeleteVerbsKey: FocusedValueKey {
    typealias Value = DeleteVerbs
}

extension FocusedValues {
    var deleteVerbs: DeleteVerbs? {
        get { self[DeleteVerbsKey.self] }
        set { self[DeleteVerbsKey.self] = newValue }
    }
}

/// Edit ▸ Remove … / Delete — the menu half of **⌫ removes, ⌘⌫ destroys** (022 · D5).
///
/// **Only Delete carries a key equivalent, and that is deliberate.** A menu key
/// equivalent is matched by `NSMenu` before the event ever reaches the first
/// responder, and it cannot see that the responder is a text view — the platform
/// behaviour that killed the canvas's V/F/T shortcuts (269) and the detail page's
/// arrows (069). Registering a BARE ⌫ here would therefore swallow Backspace in every
/// text field in the app: the sidebar's rename row, the search field, the detail
/// page's Name and Note. So ⌫ is delivered by the surfaces themselves — the grid's
/// `deleteBackward:`, the canvas's `keyDown`, the detail page's key catcher — each of
/// which knows whether a field has the keyboard. The menu item still names the verb
/// and performs it on click; it just is not the thing that listens for the key.
///
/// ⌘⌫ is safe to register (it is nobody's text-entry key) and is the one that most
/// needs to be visible: it is the destructive one, and it always raises the shared
/// confirmation before anything is deleted.
private struct DeleteCommands: View {
    @FocusedValue(\.deleteVerbs) private var verbs

    var body: some View {
        Button(verbs?.removeTitle ?? "Remove from Collection") { verbs?.remove() }
            .disabled(!(verbs?.canRemove ?? false))
        Button("Delete") { verbs?.destroy() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(verbs == nil)
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

/// File ▸ Review Duplicates… (012 · I5) — opens the near-duplicate review sheet.
/// Disabled until the library is open, since there is nothing to compare before
/// then. It only ever OPENS the surface; no scan and no delete happens from a menu.
private struct DuplicatesCommand: View {
    @FocusedValue(\.ingestionModel) private var model

    var body: some View {
        Button("Review Duplicates…") { model?.showDuplicates = true }
            .disabled(model?.services == nil)
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

/// Help ▸ Keyboard Shortcuts (⌘/, 024 · K2).
///
/// ⌘/ is the chord users arrive with, and [024] · D verified it was bound nowhere
/// (`?` is free too; ⌘/ is the convention). The title comes from ``KeyMap/pageTitle``
/// so the menu item and the sheet's own heading cannot drift apart.
///
/// Observes ``NavModel`` as a focused OBJECT — the same reason ``NewItemCommand``
/// does. The sheet is raised by flipping `nav.showShortcuts`, which ``AppShellView``
/// presents from, because a sheet needs a view to hang on and a `Scene`-level command
/// has none.
private struct KeyboardShortcutsCommand: View {
    @FocusedObject private var nav: NavModel?

    var body: some View {
        Button(KeyMap.pageTitle) { nav?.showShortcuts = true }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(nav == nil)
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
