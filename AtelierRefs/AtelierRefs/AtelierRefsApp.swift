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
            CommandGroup(after: .sidebar) {
                BackCommand()
            }
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
