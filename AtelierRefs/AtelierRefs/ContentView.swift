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
    // Injected from the App scene (010 · Phase 2) so the Settings window shares it.
    @ObservedObject var model: IngestionModel
    @StateObject private var nav = NavModel()
    // Global grid-view preferences (011-B2 density) — persisted, one muscle memory
    // across every collection.
    @StateObject private var gridPrefs = GridViewPreferences()
    // Shell-level capture-feedback toasts (011-B4), overlaid over every screen.
    @StateObject private var toasts = ToastCenter()

    // First-run onboarding gate (010 · Phase 2). Replayable from Settings (which
    // flips this back to false).
    @AppStorage("AtelierDidCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        AppShellView(model: model, nav: nav, gridPrefs: gridPrefs)
            // First-run setup guide — surfaces the (previously undiscoverable)
            // extension-pairing flow. Gated so it shows once, replayable from ⌘,.
            .sheet(isPresented: Binding(
                get: { !didCompleteOnboarding },
                set: { if !$0 { didCompleteOnboarding = true } })
            ) {
                OnboardingSheet(model: model) { didCompleteOnboarding = true }
            }
            // The toast stack floats over the whole shell (bottom-trailing).
            .overlay { ToastHostView(center: toasts, onJump: handleJump) }
            // A landed browser-capture batch raises ONE "Saved — Jump" toast,
            // coalesced per target folder so a burst never spams one-per-item.
            .onChange(of: model.lastCaptureBatch) { _, batch in
                guard let batch else { return }
                toasts.post(
                    message: "Saved \(batch.importedCount) to \(batch.collectionName)",
                    action: .jump(JumpTarget(
                        collectionID: batch.collectionID, assetIDs: batch.assetIDs)),
                    coalesceKey: "capture-\(batch.collectionID.uuidString)")
            }
            // The 3-pane split's 960 minimum no longer applies — the new shell is
            // a single navigation column.
            .frame(minWidth: 860, minHeight: 600)
            // The last-opened collection is restored by seeding `NavModel.path`'s
            // INITIAL value (004 Q3) — no launch-time push. Here we only VALIDATE it
            // once folders load: drop the seeded path if that collection was deleted
            // since last launch. The common case (it still exists) mutates nothing,
            // so launch performs no `nav.path` change and the NavigationStack observer
            // stays quiet.
            .onReceive(model.$folders) { folders in
                nav.pruneRestoredPathIfMissing(using: folders)
            }
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
            // Space delete is confirmed + undoable, matching asset delete (a board
            // can hold hundreds of placements). Triggered from the Spaces list.
            .confirmationDialog(
                "Delete “\(model.pendingSpaceDeletion?.name ?? "")”?",
                isPresented: spaceDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { model.confirmSpaceDeletion() }
                Button("Cancel", role: .cancel) { model.cancelSpaceDeletion() }
            } message: {
                Text("The board and its arrangement are removed. Your images stay in "
                     + "their collections, and you can undo this with ⌘Z.")
            }
    }

    /// Perform a toast's Jump (011-B4): ignore it if the target collection is
    /// gone (a stale toast — `resolveJump` no-ops), else navigate there and stage
    /// the post-load selection of the captured items.
    private func handleJump(_ target: JumpTarget) {
        let existing = Set(model.folders.map(\.id))
        guard let resolved = resolveJump(target, existingCollectionIDs: existing) else { return }
        nav.openCollection(resolved.collectionID)
        model.requestJumpSelection(assetIDs: resolved.assetIDs, in: resolved.collectionID)
    }

    /// Bridges the model's optional ``PendingDeletion`` to the dialog's `Bool`
    /// binding; dismissing (Cancel / Esc) clears the pending state.
    private var deletionConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelPendingDeletion() } })
    }

    /// Bridges the model's optional ``PendingSpaceDeletion`` to the dialog's `Bool`
    /// binding; dismissing (Cancel / Esc) clears the pending state.
    private var spaceDeletionConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingSpaceDeletion != nil },
            set: { if !$0 { model.cancelSpaceDeletion() } })
    }
}

#Preview {
    ContentView(model: IngestionModel())
}
