//
//  ContactSheetExportControls.swift
//  AtelierRefs
//
//  052 · B4 — the collection contact-sheet export chrome:
//   • ``ContactSheetExportButton`` — a config popover (format + PDF layout / PNG
//     scale + column count + captions) raised from the selection bar; Export…
//     hands the generated ``MoodboardExport/Mapping`` to the shared
//     ``ExportController`` (same save panel / progress / toast as the moodboard).
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

// MARK: - Export button + config popover

struct ContactSheetExportButton: View {
    @ObservedObject var model: IngestionModel
    let collectionID: UUID
    @EnvironmentObject private var controller: ExportController
    @State private var config = ExportConfig()
    @State private var sheet = ContactSheetConfig()
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            SelectionBarIcon(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help("Export a contact sheet (PDF or PNG)")
        .disabled(controller.isExporting)
        .popover(isPresented: $showPanel, arrowEdge: .top) { panel }
    }

    /// The selection-or-whole-collection mapping for the current knobs.
    private var mapping: MoodboardExport.Mapping {
        ContactSheetExport.map(
            details: ContactSheetExport.rows(items: model.items, selectedIDs: model.selection.ids),
            config: sheet,
            imageURL: { model.previewImageURL(forAsset: $0) })
    }

    private var panel: some View {
        let map = mapping
        let pageCount = MoodboardExport.pages(for: map.elements, config: config).count
        // Refs = image/colour elements; captions are extra text elements, so count
        // the non-text ones for the intuitive "how many images".
        let refCount = map.elements.filter { if case .text = $0.content { return false }; return true }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Export contact sheet").font(.headline)

            LabeledContent("Format") {
                Picker("Format", selection: $config.format) {
                    Text("PDF").tag(ExportFormat.pdf)
                    Text("PNG").tag(ExportFormat.png)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if config.format == .pdf {
                LabeledContent("Layout") {
                    Picker("Layout", selection: $config.pdfLayout) {
                        Text("Single page").tag(PDFLayout.singlePage)
                        Text("Letter pages").tag(PDFLayout.letterPages)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                LabeledContent("Scale") {
                    Picker("Scale", selection: $config.pngScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            LabeledContent("Columns") {
                Picker("Columns", selection: $sheet.columns) {
                    ForEach([3, 4, 5, 6], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Captions", isOn: $sheet.captions)

            Text(summary(refs: refCount, pages: pageCount, skipped: map.skipped))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Export…") {
                    showPanel = false
                    controller.requestExport(
                        mapping: map, config: config, suggestedName: model.name(for: collectionID))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(map.isEmpty)
            }
        }
        .popoverContent(width: 300)
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
