//
//  ContactSheetExportControls.swift
//  AtelierRefs
//
//  052 · B4 — the collection contact-sheet export chrome:
//   • ``ContactSheetExportPanel`` — a config popover (format + PDF layout / PNG
//     scale + column count + captions) raised from the selection bar's `…`
//     overflow; Export… hands the generated ``MoodboardExport/Mapping`` to the
//     shared ``ExportController`` (same save panel / progress / toast as the
//     moodboard).
//   • ``ExportContactSheetCommand`` — the File-menu path, exporting the
//     selection-or-whole-collection with default settings whenever a collection
//     is focused.
//
//  The progress ring + completion toast are the moodboard's (``ExportProgressRing``
//  / `ContentView`), reused as-is — a contact sheet is just another export.
//

import AtelierCore
import AtelierExport
import SwiftUI

// MARK: - Config popover

/// The contact sheet's knobs, presented from the selection bar's `…` overflow.
///
/// **The knobs are the HOST's state, not this view's.** A popover's content is
/// built fresh on each presentation, so `@State` here would reset format and
/// column count every time the panel opened — the bar-glyph version this replaced
/// kept them because its button view outlived the popover. `CollectionView` owns
/// them now, which preserves that for as long as the collection is on screen.
struct ContactSheetExportPanel: View {
    @ObservedObject var model: IngestionModel
    let collectionID: UUID
    @Binding var config: ExportConfig
    @Binding var sheet: ContactSheetConfig
    /// Dismiss the popover — the host owns its presentation.
    var onClose: () -> Void
    @EnvironmentObject private var controller: ExportController

    /// The selection-or-whole-collection mapping for the current knobs.
    private var mapping: MoodboardExport.Mapping {
        ContactSheetExport.map(
            details: ContactSheetExport.rows(items: model.items, selectedIDs: model.selection.ids),
            config: sheet,
            imageURL: { model.previewImageURL(forAsset: $0) })
    }

    var body: some View {
        let map = mapping
        let pageCount = MoodboardExport.pages(for: map.elements, config: config).count
        // Refs = image/colour elements; captions are extra text elements, so count
        // the non-text ones for the intuitive "how many images".
        let refCount = map.elements.filter { if case .text = $0.content { return false }; return true }.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Export Contact Sheet").font(Theme.Typography.bodyEmphasis)

            DialogRow("Format") {
                SegmentedControl(selection: $config.format, values: [.pdf, .png]) {
                    Text($0 == .pdf ? "PDF" : "PNG")
                }
            }

            if config.format == .pdf {
                DialogRow("Layout") {
                    SegmentedControl(
                        selection: $config.pdfLayout, values: [.singlePage, .letterPages]
                    ) {
                        Text($0 == .singlePage ? "Single Page" : "Letter Pages")
                    }
                }
            } else {
                DialogRow("Scale") {
                    SegmentedControl(selection: $config.pngScale, values: [1, 2, 3]) {
                        Text("\($0)×")
                    }
                }
            }

            DialogRow("Columns") {
                SegmentedControl(selection: $sheet.columns, values: [3, 4, 5, 6]) {
                    Text("\($0)")
                }
            }

            // Left native: a checkbox has no counterpart in the reference frames, and
            // inventing one is a separate decision from restyling what they do show.
            Toggle("Captions", isOn: $sheet.captions)

            Text(summary(refs: refCount, pages: pageCount, skipped: map.skipped))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)

            Button("Export…") {
                onClose()
                controller.requestExport(
                    mapping: map, config: config, suggestedName: model.name(for: collectionID))
            }
            .buttonStyle(DialogButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(map.isEmpty)
        }
        .popoverContent(width: 320)
    }

    /// The count line: refs, page count (letter PDF only), and any skipped rows.
    private func summary(refs: Int, pages: Int, skipped: Int) -> String {
        var parts = ["\(refs) \(refs == 1 ? "ref" : "refs")"]
        if config.format == .pdf, config.pdfLayout == .letterPages {
            parts.append("\(pages) \(pages == 1 ? "page" : "pages")")
        }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu command (File ▸ Export Contact Sheet…)

/// A focused trigger so the File-menu command reaches whichever collection is
/// active. Exports the selection-or-whole-collection with default settings (PDF,
/// single page, captions) — the popover is where format / columns change.
struct ExportContactSheetAction {
    let run: () -> Void
}

private struct ExportContactSheetActionKey: FocusedValueKey {
    typealias Value = ExportContactSheetAction
}

extension FocusedValues {
    var exportContactSheet: ExportContactSheetAction? {
        get { self[ExportContactSheetActionKey.self] }
        set { self[ExportContactSheetActionKey.self] = newValue }
    }
}

/// The `File ▸ Export Contact Sheet…` command. Enabled only when a collection is
/// focused. No shortcut (⇧⌘E is the Space board's moodboard export).
struct ExportContactSheetCommand: View {
    @FocusedValue(\.exportContactSheet) private var action

    var body: some View {
        Button("Export Contact Sheet…") { action?.run() }
            .disabled(action == nil)
    }
}
