//
//  CollectionSiteExportControls.swift
//  AtelierRefs
//
//  014 · S3 — the collection→web-page export chrome, shaped exactly like the
//  contact sheet's (052 · B4) so a third export is not a third set of habits:
//   • ``CollectionSiteExportPanel`` — a config popover (columns + captions +
//     source links) raised from the selection bar's `…` overflow; Export… hands
//     the ``CollectionSiteExport/Plan`` to the shared ``ExportController``, which
//     owns the save panel, the progress ring and the completion toast.
//   • ``ExportWebPageCommand`` — the File-menu path, exporting the
//     selection-or-whole-collection with default settings. Absent (and so
//     disabled) when the focused collection has nothing in it.
//
//  "Include source links" gets its own row rather than hiding under captions:
//  a title is a label, a source is provenance, and the decision to strip the
//  second is not the same decision as tidying away the first (014).
//

import AtelierCore
import AtelierExport
import SwiftUI

// MARK: - Config popover

/// The web page's knobs, presented from the selection bar's `…` overflow. Shaped
/// exactly like ``ContactSheetExportPanel``, including where its state lives —
/// see that type for why the host owns `config` rather than this view.
struct CollectionSiteExportPanel: View {
    @ObservedObject var model: IngestionModel
    let collectionID: UUID
    @Binding var config: SiteExportConfig
    /// Dismiss the popover — the host owns its presentation.
    var onClose: () -> Void
    @EnvironmentObject private var controller: ExportController

    /// The selection-or-whole-collection plan for the current knobs.
    private var plan: CollectionSiteExport.Plan {
        CollectionSiteExport.plan(
            title: model.name(for: collectionID),
            details: CollectionSiteExport.rows(
                items: model.items, selectedIDs: model.selection.ids),
            config: config,
            blobURL: { model.blobURL(forAsset: $0) },
            posterURL: { model.previewImageURL(forAsset: $0) })
    }

    var body: some View {
        let export = plan
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Export Web Page").font(Theme.Typography.bodyEmphasis)

            DialogRow("Columns") {
                SegmentedControl(selection: $config.columns, values: [3, 4, 5, 6]) {
                    Text("\($0)")
                }
            }

            // Left native, like the contact sheet's: a checkbox has no
            // counterpart in the reference frames, and inventing one is a
            // separate decision from restyling what they do show.
            Toggle("Captions", isOn: $config.captions)
            Toggle("Include source links", isOn: $config.sourceLinks)

            Text(summary(export))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)

            Button("Export…") {
                onClose()
                controller.requestSiteExport(
                    plan: export,
                    suggestedName: CollectionSiteExport.folderName(
                        for: model.name(for: collectionID)))
            }
            .buttonStyle(DialogButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(export.isEmpty)
        }
        .popoverContent(width: 320)
    }

    /// Refs, any skips, and the promise the folder makes.
    private func summary(_ plan: CollectionSiteExport.Plan) -> String {
        let refs = plan.gallery.items.count
        var parts = ["\(refs) \(refs == 1 ? "ref" : "refs")"]
        if plan.skipped > 0 { parts.append("\(plan.skipped) skipped") }
        parts.append("no internet needed")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu command (File ▸ Export Web Page…)

/// A focused trigger so the File-menu command reaches whichever collection is
/// active. Exports the selection-or-whole-collection with default settings
/// (4 columns, captions and source links on) — the popover is where those change.
struct ExportWebPageAction {
    let run: () -> Void
}

private struct ExportWebPageActionKey: FocusedValueKey {
    typealias Value = ExportWebPageAction
}

extension FocusedValues {
    var exportWebPage: ExportWebPageAction? {
        get { self[ExportWebPageActionKey.self] }
        set { self[ExportWebPageActionKey.self] = newValue }
    }
}

/// The `File ▸ Export Web Page…` command. Enabled only when a NON-EMPTY
/// collection is focused: an empty collection disables the action rather than
/// writing a folder with nothing in it (014). No shortcut — ⇧⌘E is the Space
/// board's moodboard export.
struct ExportWebPageCommand: View {
    @FocusedValue(\.exportWebPage) private var action

    var body: some View {
        Button("Export Web Page…") { action?.run() }
            .disabled(action == nil)
    }
}
