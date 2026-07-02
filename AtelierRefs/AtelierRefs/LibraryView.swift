//
//  LibraryView.swift
//  AtelierRefs
//
//  Chunk 3 (folders) — the Library tab. A `NavigationSplitView` whose sidebar is
//  the ``FolderTreeView`` and whose detail shows the selected folder's
//  subfolders (navigable chips) + a thumbnail grid of its DIRECT items, plus the
//  import affordances (drop target + Paste) now targeting the selected folder.
//

import AppKit
import AtelierCore
import AtelierIngestion
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var model = IngestionModel()
    @State private var isTargeted = false
    @State private var showInspector = true

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 8)]

    var body: some View {
        NavigationSplitView {
            FolderTreeView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dropZone
            if !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
        .navigationTitle(model.name(for: model.selectedFolderID))
    }

    private var header: some View {
        HStack {
            Text(model.name(for: model.selectedFolderID)).font(.title2).bold()
            Text("\(model.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
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
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26))
                    Text("Drop images or files into “\(model.name(for: model.selectedFolderID))”")
                        .font(.callout)
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

    private var subfolderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.subfolders) { folder in
                    Button {
                        model.selectedFolderID = folder.id
                        model.loadContents(of: folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.items, id: \.item.id) { detail in
                    Button {
                        model.select(detail)
                    } label: {
                        FolderThumbnail(
                            image: model.thumbnail(for: detail),
                            isSelected: model.selectedItemID == detail.item.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .overlay {
            if model.items.isEmpty {
                Text("No items in this folder yet.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Import actions

    /// Paste from the GENERAL pasteboard into the selected folder.
    private func paste() {
        guard model.isReady else { return }
        let inputs = DirectInputReader.inputs(
            from: .general, into: model.selectedFolderID, now: Date())
        model.run(inputs: inputs)
    }

    /// Convert dropped providers into inputs targeting the selected folder,
    /// off-main, then run them.
    ///
    /// A browser image drag delivers its source PAGE URL either on the same
    /// provider as the image or as a separate URL provider, so we collect any
    /// web URL across the whole drop FIRST, then attach it to the image(s) as
    /// provenance — mirroring the pasteboard path (`DirectInputReader.inputs`).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isReady else { return false }
        let target = model.selectedFolderID
        Task {
            let pageURL = await Self.firstWebURL(in: providers)
            var inputs: [IngestInput] = []
            for provider in providers {
                if let input = await Self.input(from: provider, pageURL: pageURL, into: target) {
                    inputs.append(input)
                }
            }
            model.run(inputs: inputs)
        }
        return true
    }

    // MARK: - NSItemProvider → IngestInput

    /// Interpret one dropped provider. Files → `.localDrag` (reading the real
    /// bytes). An image with an accompanying web `pageURL` → `.web` (browser
    /// image, page URL as provenance); an image without one → `.localPaste`.
    /// URL-only providers are skipped (their URL is captured via `pageURL`).
    private nonisolated static func input(
        from provider: NSItemProvider, pageURL: URL?, into collectionID: UUID
    ) async -> IngestInput? {
        let now = Date()
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.isFileURL {
            return DirectInputReader.fileInput(fileURL: url, into: collectionID, at: now)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: UTType.image.identifier) {
            if let pageURL {
                return DirectInputReader.browserImageInput(
                    imageData: data, pageURL: pageURL, into: collectionID, at: now)
            }
            return DirectInputReader.pasteInput(
                imageData: data, sourceURL: nil, into: collectionID, at: now)
        }
        return nil
    }

    /// The first web (`http`/`https`) URL across all dropped providers, or `nil`.
    /// File-URL providers are skipped (a file URL also conforms to `public.url`,
    /// but it isn't provenance); the scheme test is shared with the pasteboard
    /// path via `DirectInputReader.isWebURL`.
    private nonisolated static func firstWebURL(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            else { continue }
            if let url = await loadURL(provider), DirectInputReader.isWebURL(url) {
                return url
            }
        }
        return nil
    }

    private nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

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

/// One thumbnail cell — shows the loaded image, or a placeholder tile. A
/// selection ring marks the item currently shown in the inspector.
private struct FolderThumbnail: View {
    let image: NSImage?
    var isSelected: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 3)
        }
    }
}
