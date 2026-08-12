//
//  AssetFolderExportControls.swift
//  AtelierRefs
//
//  011 · A2 — the originals-export chrome. Shorter than its three siblings by one
//  whole surface: there is NO config popover, because an originals export has
//  nothing to configure. The moodboard picks a format and a scale, the contact
//  sheet picks columns and captions, the web page picks columns and provenance —
//  the files are just the files, so a popover here would be a summary line and an
//  Export button, which is a click tax rather than a control.
//
//  What remains is the File-menu path, wired the way the other three are: a
//  focused action so the command reaches whichever collection is active, absent
//  (and therefore disabled) when nothing is exportable.
//
//  No keyboard shortcut, matching `Export Contact Sheet…` and `Export Web Page…`.
//  ⇧⌘E is the Space board's moodboard export (KeyMap · 077), and a three-modifier
//  chord for a verb that ends in a save dialog earns nothing.
//

import SwiftUI

// MARK: - Menu command (File ▸ Export Assets…)

/// A focused trigger so the File-menu command reaches whichever collection is
/// active. Exports the selection-or-whole-collection's originals — there are no
/// settings to defer to a popover, so this IS the whole action.
struct ExportAssetsAction {
    let run: () -> Void
}

private struct ExportAssetsActionKey: FocusedValueKey {
    typealias Value = ExportAssetsAction
}

extension FocusedValues {
    var exportAssets: ExportAssetsAction? {
        get { self[ExportAssetsActionKey.self] }
        set { self[ExportAssetsActionKey.self] = newValue }
    }
}

/// The `File ▸ Export Assets…` command. Enabled only when a NON-EMPTY collection
/// is focused — an empty collection disables the action rather than writing an
/// empty folder, the rule ``ExportWebPageCommand`` established.
struct ExportAssetsCommand: View {
    @FocusedValue(\.exportAssets) private var action

    var body: some View {
        Button("Export Assets…") { action?.run() }
            .disabled(action == nil)
    }
}
