//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import AppKit
import AtelierCore
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
    // Window-level moodboard export state (052 · B3): the save panel + off-main
    // render live here so the Space board's Export button and the top-bar
    // progress ring share one observable, and the report toast surfaces here.
    @StateObject private var exportController = ExportController()

    // First-run onboarding gate (010 · Phase 2). Replayable from Settings (which
    // flips this back to false).
    @AppStorage("AtelierDidCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        AppShellView(model: model, nav: nav, gridPrefs: gridPrefs)
            // The moodboard export controller reaches the Space board's Export
            // button + the top-bar progress ring via the environment (052 · B3).
            .environmentObject(exportController)
            // Dark-studio identity (D1): commit to a dark appearance so the app's
            // system semantic colours resolve to their dark variants for free, and
            // the AppKit grid inherits the window appearance.
            .preferredColorScheme(.dark)
            // Keep the native translucent window (D1b): a behind-window material
            // ground so the desktop shows through the window's margins + the sidebar
            // rail. Opaque studio panels are drawn on top of this.
            .background(VisualEffectBackground().ignoresSafeArea())
            .onAppear { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // First-run setup guide — surfaces the (previously undiscoverable)
            // extension-pairing flow. Gated so it shows once, replayable from ⌘,.
            .sheet(isPresented: Binding(
                get: { !didCompleteOnboarding },
                set: { if !$0 { didCompleteOnboarding = true } })
            ) {
                OnboardingSheet(model: model) { didCompleteOnboarding = true }
            }
            // The toast stack floats over the whole shell (bottom-trailing), and
            // every model event that feeds it is routed in ONE modifier — the shell's
            // `body` is already at the type-checker's budget (see ``ExportReportToast``).
            .overlay { ToastHostView(center: toasts, onJump: handleJump, onUndo: handleUndo) }
            .modifier(ModelToastRouting(model: model, toasts: toasts))
            // A finished moodboard export raises ONE toast (052 · B3 · 7A): a
            // confirmation on success (noting any skipped media-less refs), an
            // error on failure. A user-cancelled export stays silent. Coalesced.
            .modifier(ExportReportToast(controller: exportController, toasts: toasts))
            // The 3-pane split's 960 minimum no longer applies — the new shell is
            // a single navigation column.
            .frame(minWidth: 860, minHeight: 600)
            // Reconcile route state whenever the folder list changes (043 · 3A):
            // validates the seeded restore at launch AND, after a delete removes a
            // subtree, drops a drill-down path / sidebar selection that points at a
            // now-gone collection back to a valid target. The common case (nothing
            // missing) mutates nothing, so launch performs no `nav.path` change and
            // the NavigationStack observer stays quiet.
            .onReceive(model.$folders) { folders in
                nav.reconcile(using: folders)
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

    /// Fire an Undo toast: reverse the destructive verb it describes, but only if
    /// it's still the top of the undo stack (034 P1 — the model re-checks `token`).
    private func handleUndo(_ token: Int) {
        model.undoLastAction(expecting: token)
    }

    /// The toast text for a finished export, or `nil` to stay silent (a user
    /// cancellation). Extracted from the `.onChange` so the type-checker doesn't
    /// choke on the nested string building (052 · B3).
    fileprivate static func exportToastMessage(for report: ExportController.Report) -> String? {
        switch report.outcome {
        case .success:
            let base = report.url.map { "Exported \($0.lastPathComponent)" } ?? "Export complete"
            guard report.skipped > 0 else { return base }
            let noun = report.skipped == 1 ? "ref" : "refs"
            return "\(base) — \(report.skipped) \(noun) had no image"
        case .failed(let message):
            return "Export failed — \(message)"
        case .cancelled:
            return nil
        }
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

/// Every toast the MODEL raises, routed in one place: the four publisher→toast
/// hops that used to sit inline in the shell's `body`. Split out for the same
/// reason as ``ExportReportToast`` — the chain had reached the type-checker's
/// budget, and adding the notice route tipped it over.
///
/// Each event owns its own `coalesceKey`, so the four kinds occupy independent
/// slots and a burst within one kind refreshes a single card.
private struct ModelToastRouting: ViewModifier {
    @ObservedObject var model: IngestionModel
    let toasts: ToastCenter

    func body(content: Content) -> some View {
        content
            // A reversible verb raises ONE "…— Undo" toast (034 P1). Coalesced into a
            // single slot so a rapid sequence refreshes the same card — and, since
            // UndoManager is a LIFO stack, the visible toast always describes the top
            // action its button will reverse. `handleUndo` re-checks the token first.
            .onChange(of: model.lastUndoableAction) { _, event in
                guard let event else { return }
                toasts.post(
                    message: event.message,
                    action: .undo(undoToken: event.undoToken),
                    coalesceKey: "undo-action")
            }
            // A plain notice (import outcome, restore, snapshot, an unreadable drop).
            // One shared slot, so a sequence describing one operation — "Downloading
            // image…" then "Imported 1." — refreshes a card instead of stacking,
            // exactly as the toolbar status line behaved before 006 removed its reader.
            .onChange(of: model.lastNotice) { _, notice in
                guard let notice else { return }
                toasts.post(message: notice.message, coalesceKey: "notice")
            }
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
            // A ⌘C that couldn't copy everything raises ONE partial-copy toast (052 ·
            // B1 · 7A). A fully-successful copy is silent — the pasteboard content is
            // the feedback, matching standard macOS Copy.
            .onChange(of: model.lastCopyReport) { _, report in
                guard let report, report.skipped > 0 else { return }
                let noun = report.skipped == 1 ? "item" : "items"
                toasts.post(
                    message: report.copied > 0
                        ? "Copied \(report.copied) — \(report.skipped) \(noun) had no image"
                        : "Nothing to copy — \(report.skipped) \(noun) had no image",
                    coalesceKey: "copy-report")
            }
    }
}

/// The finished-export toast, split into its own modifier so the shell's `body`
/// stays under the type-checker's budget (052 · B3).
private struct ExportReportToast: ViewModifier {
    @ObservedObject var controller: ExportController
    let toasts: ToastCenter

    func body(content: Content) -> some View {
        content.onChange(of: controller.lastReport) { _, report in
            guard let report, let message = ContentView.exportToastMessage(for: report) else { return }
            toasts.post(message: message, coalesceKey: "export-report")
        }
    }
}

#Preview {
    ContentView(model: IngestionModel())
}
