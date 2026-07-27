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
        // Only boot Sparkle when this build actually carries a usable update
        // configuration. Until `generate_keys` has produced a real EdDSA public
        // key and a real `SUFeedURL` is set (see Info.plist / SECRETS.md), both
        // Info.plist values are the deliberate `REPLACE…` placeholders A3 shipped —
        // and Sparkle's `startUpdater:` rejects an invalid `SUPublicEDKey` by
        // failing at launch with "The updater failed to start." Gating the start
        // keeps Debug / pre-release runs silent (the menu item simply stays
        // disabled) instead of nagging on every launch, while a real Developer ID
        // release — which carries valid keys — starts and behaves normally.
        // Feed URL + public EdDSA key come from Info.plist (SUFeedURL / SUPublicEDKey).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.hasUsableUpdateConfiguration,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        // Sparkle publishes `canCheckForUpdates` via KVO; bridge it to @Published.
        // When the updater wasn't started (placeholder config) this stays false,
        // so the "Check for Updates…" menu item is correctly disabled.
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Begin a user-initiated update check; Sparkle's standard UI drives the rest.
    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    /// Whether this build's Info.plist carries a real Sparkle feed + public key
    /// (reads `Bundle.main`). Delegates to the pure overload for testability.
    static var hasUsableUpdateConfiguration: Bool {
        hasUsableUpdateConfiguration(
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    /// Pure config validator: true only when the feed URL and EdDSA public key are
    /// both present, non-empty, not the shipped `REPLACE…` placeholders, and the
    /// key decodes to a 32-byte Ed25519 public key. An invalid key is exactly what
    /// makes Sparkle's `startUpdater:` fail, so a malformed paste can't reproduce
    /// the "failed to start" alert either — it just leaves the updater unstarted.
    static func hasUsableUpdateConfiguration(feedURL: String?, publicEDKey: String?) -> Bool {
        func real(_ value: String?) -> String? {
            guard let value, !value.isEmpty, !value.contains("REPLACE") else { return nil }
            return value
        }
        guard real(feedURL) != nil, let key = real(publicEDKey) else { return false }
        // Ed25519 public key = 32 bytes → 44 Base64 characters.
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else { return false }
        return true
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
