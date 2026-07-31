//
//  ImportFilesPanel.swift
//  AtelierRefs
//
//  "Import Images…" — the app's first FILE-CHOOSER import path. Until now images could
//  only enter by drag-and-drop or the Chrome extension: there was no `NSOpenPanel`
//  anywhere in the app, even though the sandbox has carried
//  `files.user-selected.read-write` (which is exactly this) from the start, and
//  `DirectInputReader.fileInput` has been ready to take the URLs the whole time.
//
//  A thin wrapper on purpose. The panel only picks URLs; turning them into inputs is
//  `IngestionModel.fileInputs`, and ingesting them is the same funnel a drop uses, so a
//  chosen file and a dropped file cannot diverge.
//

import AppKit
import UniformTypeIdentifiers

enum ImportFilesPanel {

    /// Ask for files to import, calling back with the chosen URLs (empty on cancel).
    ///
    /// Presented as a SHEET on the key window when there is one, so the panel belongs
    /// to the document it imports into rather than floating free; `runModal()` is the
    /// fallback for the window-less case. Either way `completion` runs on the main
    /// actor, after the panel is down.
    static func present(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Video rides along: the ingest pipeline already classifies and thumbnails it,
        // so restricting to `.image` would refuse files the app can otherwise hold.
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "Import"
        panel.message = "Choose images or videos to import."

        guard let window = NSApp.keyWindow else {
            completion(panel.runModal() == .OK ? panel.urls : [])
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.urls : [])
        }
    }
}
