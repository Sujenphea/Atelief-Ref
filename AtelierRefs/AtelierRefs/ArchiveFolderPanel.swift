//
//  ArchiveFolderPanel.swift
//  AtelierRefs
//
//  008 · H6 — "Archive Library…"'s destination picker.
//
//  A SAVE panel, not an open panel, for the reason `CollectionSiteExport`'s is:
//  the user is NAMING something new. The "file" it names is the folder the
//  archive is written into, so there is no content type and no extension.
//
//  No bookmark and no entitlement are involved — a powerbox-granted URL is
//  usable for the life of the process, and an archive is consumed in-process.
//  The URL becomes a `DirectFolderAccess` at the call site so the writer sees
//  the same `FolderAccess` seam a backup does, and its tests can hand it a plain
//  temp directory.
//

import AppKit

enum ArchiveFolderPanel {

    /// Ask where to write the archive, calling back with the chosen folder
    /// (`nil` on cancel).
    ///
    /// Presented as a sheet on the key window when there is one — the Settings
    /// window, normally — with `runModal()` as the window-less fallback, matching
    /// `BackupFolderPanel` and `ImportFilesPanel`.
    static func present(suggestedName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.prompt = "Archive"
        panel.message = ArchiveCopy.panelMessage

        guard let window = NSApp.keyWindow else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Ask which archive to read back in (008 · H7), calling back with the
    /// chosen folder (`nil` on cancel).
    ///
    /// An OPEN panel this time, and a directory one: the archive is a folder the
    /// user already has, and the thing that makes it an archive — `manifest.json`
    /// — is inside it. Validating that is `LibraryArchiveReader.parse`, not this
    /// panel: a folder chosen here and one handed to the reader by a test must
    /// be judged by exactly the same rules.
    static func presentImport(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = ArchiveImportCopy.panelPrompt
        panel.message = ArchiveImportCopy.panelMessage

        guard let window = NSApp.keyWindow else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}
