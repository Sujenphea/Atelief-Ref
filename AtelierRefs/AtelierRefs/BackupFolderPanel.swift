//
//  BackupFolderPanel.swift
//  AtelierRefs
//
//  008 · H4 — "Choose Folder…" for the off-device backup target. The powerbox
//  grant this panel returns is what makes the folder reachable at all; turning it
//  into something that survives relaunch is `StoredFolderAccess` (F2).
//
//  A thin wrapper on purpose, mirroring `ImportFilesPanel`: the panel only picks
//  a directory. Validating it and remembering it are
//  `IngestionModel.setBackupFolder(_:)`, so a folder chosen here and one restored
//  from a bookmark cannot diverge.
//

import AppKit

enum BackupFolderPanel {

    /// Ask for the backup destination, calling back with the chosen directory
    /// (`nil` on cancel).
    ///
    /// Presented as a sheet on the key window when there is one — the Settings
    /// window, normally — with `runModal()` as the window-less fallback, matching
    /// `ImportFilesPanel`. Either way `completion` runs after the panel is down.
    static func present(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Backing up to a brand-new folder is the common first run, so let the
        // user make one here rather than bouncing them out to Finder.
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for off-device backups — an external "
            + "drive or a synced folder."

        guard let window = NSApp.keyWindow else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}
