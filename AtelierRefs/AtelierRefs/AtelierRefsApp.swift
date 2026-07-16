//
//  AtelierRefsApp.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import SwiftUI

@main
struct AtelierRefsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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
            CommandGroup(after: .sidebar) {
                BackCommand()
            }
            CommandGroup(after: .saveItem) {
                SnapshotCommands()
            }
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
