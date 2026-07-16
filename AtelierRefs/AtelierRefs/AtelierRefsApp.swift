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

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        // 004-P1 — a menu Back command (⌘[) that pops the current NavModel,
        // reaching it through the focused-scene value the shell publishes.
        .commands {
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
            CommandGroup(after: .sidebar) {
                BackCommand()
            }
            CommandGroup(after: .saveItem) {
                SnapshotCommands()
            }
        }

        // The standard macOS Settings window (010 · Phase 2 · group 4): capture
        // token, library location, setup-guide replay.
        Settings {
            SettingsView(model: model)
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
            Label(title, systemImage: active ? "checkmark" : "")
        }
    }
}

/// Edit-menu Undo / Redo (⌘Z · ⇧⌘Z), reaching the shared model through the
/// focused scene value. Titles reflect the pending action ("Undo Rename"); the
/// items disable when the stack is empty. `undoToken` is observed so the enabled
/// state refreshes as actions register / fire.
private struct UndoRedoCommands: View {
    @FocusedValue(\.ingestionModel) private var model

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

/// The "Back" menu item — enabled only when there's somewhere to go back to.
private struct BackCommand: View {
    @FocusedValue(\.navModel) private var nav

    var body: some View {
        Button("Back") { nav?.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(nav?.path.isEmpty ?? true)
    }
}
