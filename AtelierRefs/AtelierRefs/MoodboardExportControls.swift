//
//  MoodboardExportControls.swift
//  AtelierRefs
//
//  052 · B3 — the Space board's export chrome, both in the top-bar header:
//   • ``MoodboardExportButton`` — a Figma-style popover: format + one contextual
//     row (PDF layout / PNG scale) + a live count, then Export… hands off to the
//     save panel via ``ExportController``.
//   • ``ExportProgressRing`` — the non-modal progress indicator (052 · 15A): a
//     determinate ring while rendering (click → Cancel), a brief checkmark on
//     success. The partial-success / error summary is a toast, raised centrally
//     in ``ContentView``.
//

import AtelierCore
import AtelierExport
import SwiftUI

// MARK: - Export button + config popover

struct MoodboardExportButton: View {
    @ObservedObject var space: SpaceModel
    @ObservedObject var model: IngestionModel
    @EnvironmentObject private var controller: ExportController
    @State private var config = ExportConfig()
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(space.items.isEmpty || controller.isExporting)
        .help("Export this board as a moodboard PDF or PNG")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) { panel }
    }

    /// The current selection-or-whole-board mapping (052 · B3 scope: selection if
    /// any tiles are selected, else the entire board).
    private var mapping: MoodboardExport.Mapping {
        MoodboardExport.map(
            details: MoodboardExport.rows(items: space.placedItems, selected: space.selectedItemIDs),
            imageURL: { model.previewImageURL(forAsset: $0) })
    }

    private var panel: some View {
        let map = mapping
        let pageCount = MoodboardExport.pages(for: map.elements, config: config).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Export moodboard").font(.headline)

            LabeledContent("Format") {
                Picker("Format", selection: $config.format) {
                    Text("PDF").tag(ExportFormat.pdf)
                    Text("PNG").tag(ExportFormat.png)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // The one contextual row swaps by format.
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

            Text(summary(refs: map.elements.count, pages: pageCount, skipped: map.skipped))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Export…") {
                    showPanel = false
                    controller.requestExport(mapping: map, config: config, suggestedName: space.name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(map.isEmpty)
            }
        }
        .popoverContent(width: 280)
    }

    private func summary(refs: Int, pages: Int, skipped: Int) -> String {
        var parts = ["\(refs) \(refs == 1 ? "ref" : "refs")"]
        if config.format == .pdf, config.pdfLayout == .letterPages {
            parts.append("\(pages) \(pages == 1 ? "page" : "pages")")
        }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu command (File ▸ Export Moodboard…)

/// A focused trigger so the File-menu command reaches whichever Space board is
/// active. Exports with default settings (PDF, single page) — the popover is the
/// place to change format; the menu is the discoverable/keyboard path.
struct ExportMoodboardAction {
    let run: () -> Void
}

private struct ExportMoodboardActionKey: FocusedValueKey {
    typealias Value = ExportMoodboardAction
}

extension FocusedValues {
    var exportMoodboard: ExportMoodboardAction? {
        get { self[ExportMoodboardActionKey.self] }
        set { self[ExportMoodboardActionKey.self] = newValue }
    }
}

/// The `File ▸ Export Moodboard…` command. Enabled only when a board is focused.
struct ExportMoodboardCommand: View {
    @FocusedValue(\.exportMoodboard) private var action

    var body: some View {
        Button("Export Moodboard…") { action?.run() }
            .disabled(action == nil)
            .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}

// MARK: - Top-bar progress ring

struct ExportProgressRing: View {
    @EnvironmentObject private var controller: ExportController
    @State private var showCancel = false
    @State private var showDone = false

    var body: some View {
        Group {
            if controller.isExporting {
                Button { showCancel.toggle() } label: { ring }
                    .buttonStyle(.plain)
                    .help("Exporting…")
                    .popover(isPresented: $showCancel, arrowEdge: .bottom) { cancelPanel }
            } else if showDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .onChange(of: controller.lastReport) { _, report in
            guard let report, case .success = report.outcome else { return }
            showDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { showDone = false }
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, controller.progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.easeOut(duration: 0.2), value: controller.progress)
    }

    private var cancelPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exporting…").font(.callout)
            ProgressView(value: controller.progress).frame(width: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    controller.cancel()
                    showCancel = false
                }
            }
        }
        .popoverContent(width: 220)
    }
}
