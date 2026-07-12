//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import SwiftUI

// Two tabs over ONE shared ``IngestionModel`` (owned here): the infinite Canvas
// and the Library (nested folder tree + browsing + import). Both show the SAME
// selected folder — pick a folder in the Library, switch to Canvas, see it.
struct ContentView: View {
    @StateObject private var model = IngestionModel()

    var body: some View {
        TabView {
            CanvasScreen(model: model)
                .tabItem { Label("Canvas", systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("tab.canvas")
            LibraryView(model: model)
                .tabItem { Label("Library", systemImage: "folder") }
                .accessibilityIdentifier("tab.library")
            BulkSweepsView(model: model)
                .tabItem { Label("Sweeps", systemImage: "square.and.arrow.down.on.square") }
                .accessibilityIdentifier("tab.sweeps")
        }
        .accessibilityIdentifier("app.tabView")
        // 960 fits the Library's three panes at their minimums (sidebar 200 +
        // detail 480 + inspector 260) — at 800 the split view broke its
        // constraints and squeezed/clipped the panes.
        .frame(minWidth: 960, minHeight: 600)
        // App-shell alert so bootstrap / Canvas / Sweeps errors surface even when
        // Library isn't the selected tab (default tab is Canvas).
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        // One confirmation for the destructive delete, shared by all three
        // surfaces (inspector / grid / canvas).
        .confirmationDialog(
            "Delete \(model.pendingDeletion?.count ?? 0) item"
                + ((model.pendingDeletion?.count ?? 0) == 1 ? "" : "s") + "?",
            isPresented: deletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmPendingDeletion() }
            Button("Cancel", role: .cancel) { model.cancelPendingDeletion() }
        } message: {
            Text("The image and its files move to the Trash, and it's removed from "
                 + "every folder. You can restore the files from the Trash.")
        }
    }

    /// Bridges the model's optional ``PendingDeletion`` to the dialog's `Bool`
    /// binding; dismissing (Cancel / Esc) clears the pending state.
    private var deletionConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelPendingDeletion() } })
    }
}

#Preview {
    ContentView()
}
