//
//  ImportView.swift
//  AtelierRefs
//
//  Chunk 5 — the minimal demo that proves the capture loop end-to-end: a drop
//  target and a Paste button turn dropped/pasted content into `IngestInput`s (via
//  the DirectInputReader factories) and run them through the coordinator, showing
//  the ingested thumbnails + a count + progress. Deliberately unpolished — this
//  exists to demonstrate the loop, not to be finished import UX.
//

import AppKit
import AtelierCore
import AtelierIngestion
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject private var model = IngestionModel()
    @State private var isTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dropZone
            grid
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Import").font(.title2).bold()
            Spacer()
            Button {
                paste()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!model.isReady)
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28))
                    Text("Drop images or files here").font(.callout)
                    if let progress = model.progress {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 200)
                        Text("\(progress.completed) / \(progress.total)")
                            .font(.caption).monospacedDigit()
                    } else if let status = model.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .onDrop(of: [.image, .fileURL, .url], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.items) { item in
                    Image(nsImage: item.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            if item.deduplicated {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .padding(3)
                                    .background(.thinMaterial, in: Circle())
                                    .padding(4)
                            }
                        }
                }
            }
            .padding(.top, 4)
        }
        .overlay {
            if model.items.isEmpty {
                Text("No imports yet — \(model.items.count) items")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    /// Paste from the GENERAL pasteboard (the one AppKit paste uses) — the only
    /// place the shared pasteboard is touched (tests use named pasteboards).
    private func paste() {
        guard let collectionID = model.collectionID else { return }
        let inputs = DirectInputReader.inputs(
            from: .general, into: collectionID, now: Date())
        model.run(inputs: inputs)
    }

    /// Convert dropped `NSItemProvider`s into `IngestInput`s off-main, then run
    /// them. Returns `true` so the drop is accepted (the async work follows).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let collectionID = model.collectionID else { return false }
        Task {
            var inputs: [IngestInput] = []
            for provider in providers {
                if let input = await Self.input(from: provider, into: collectionID) {
                    inputs.append(input)
                }
            }
            model.run(inputs: inputs)
        }
        return true
    }

    // MARK: - NSItemProvider → IngestInput

    /// Interpret one dropped provider (files → `.localDrag`; images → `.localPaste`).
    /// Web-URL-only providers (no bytes to ingest) are skipped.
    private nonisolated static func input(
        from provider: NSItemProvider, into collectionID: UUID
    ) async -> IngestInput? {
        let now = Date()

        // A dragged FILE (Finder, etc.) surfaces a file URL → `.localDrag`.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.isFileURL {
            return DirectInputReader.fileInput(fileURL: url, into: collectionID, at: now)
        }

        // A dragged / pasted IMAGE surfaces image bytes → `.localPaste`.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: UTType.image.identifier) {
            return DirectInputReader.pasteInput(
                imageData: data, sourceURL: nil, into: collectionID, at: now)
        }

        return nil
    }

    /// Load a provider's URL (file or web) via the object API.
    private nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Load a provider's data for `type`, coercing to a concrete representation.
    private nonisolated static func loadData(
        _ provider: NSItemProvider, type: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
