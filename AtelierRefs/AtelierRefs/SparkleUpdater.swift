//
//  SparkleUpdater.swift
//  AtelierRefs
//
//  052 · A3 — Sparkle 2 auto-update wiring.
//

import Combine
import Sparkle
import SwiftUI

/// The app-global Sparkle updater (decision 1A: Developer ID + Sparkle channel).
///
/// Owns a single ``SPUStandardUpdaterController`` for the whole app lifetime and
/// republishes Sparkle's `canCheckForUpdates` so the "Check for Updates…" menu
/// item's enabled state tracks it (Sparkle flips the flag off while a check is
/// already in flight). Held as a `@StateObject` on ``AtelierRefsApp`` — the menu
/// command lives in the App scene's `.commands`, which cannot observe a
/// `ContentView`-owned `@StateObject` without extra focused-value plumbing, so the
/// updater sits on the App alongside where the command is wired (this mirrors
/// Sparkle's own SwiftUI sample, which stores the controller on the `App`).
///
/// Sandboxed integration (decision 2A): `startingUpdater: true` boots the updater,
/// which drives Sparkle's Installer/Downloader XPC services embedded inside
/// `Sparkle.framework`. The host reaches them via the `-spks` / `-spki`
/// mach-lookup temporary-exception entitlements (`AtelierRefs.entitlements`) and
/// the `SUEnableInstallerLauncherService` Info.plist key.
@MainActor
final class UpdaterController: ObservableObject {
    /// Sparkle's standard controller (updater + standard user-facing UI driver).
    let updaterController: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` for menu-item validation.
    @Published var canCheckForUpdates = false

    init() {
        // Default delegates: the stock updater + standard user driver behaviour.
        // Feed URL + public EdDSA key come from Info.plist (SUFeedURL / SUPublicEDKey).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        // Sparkle publishes `canCheckForUpdates` via KVO; bridge it to @Published.
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Begin a user-initiated update check; Sparkle's standard UI drives the rest.
    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}

/// The application-menu "Check for Updates…" item (placed via
/// `CommandGroup(after: .appInfo)`). Observes ``UpdaterController`` as an
/// `@ObservedObject` so the item disables itself while a check is in flight —
/// the same observed-command pattern `UndoRedoCommands` uses for undo/redo.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
