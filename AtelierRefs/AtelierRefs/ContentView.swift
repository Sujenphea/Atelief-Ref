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
            LibraryView(model: model)
                .tabItem { Label("Library", systemImage: "folder") }
        }
        .frame(minWidth: 800, minHeight: 600)
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
