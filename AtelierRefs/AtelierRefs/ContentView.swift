//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import SwiftUI

// The app root: owns the shared ``IngestionModel`` and ``NavModel`` and hosts the
// top-bar ``AppShellView`` (Collections gallery → Collection → Spaces → Space).
// The shared error alert + destructive-delete confirmation live HERE, wrapping
// the whole shell, so they surface from any screen (the G1 "errors visible
// anywhere" property preserved across the 004 nav redesign).
struct ContentView: View {
    @StateObject private var model = IngestionModel()
    @StateObject private var nav = NavModel()

    var body: some View {
        AppShellView(model: model, nav: nav)
            // The 3-pane split's 960 minimum no longer applies — the new shell is
            // a single navigation column.
            .frame(minWidth: 860, minHeight: 600)
            // Restore the last-opened collection once the folder list loads
            // (004 Q3 — restore last collection only).
            .onReceive(model.$folders) { nav.restoreIfNeeded(using: $0) }
            // App-shell alert so bootstrap / capture / space errors surface from
            // any screen.
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
            // One confirmation for the destructive delete, shared by all surfaces
            // (collection grid / item detail / space).
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
                     + "every collection. You can restore the files from the Trash.")
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
