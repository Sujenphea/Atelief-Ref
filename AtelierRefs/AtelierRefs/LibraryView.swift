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
    @ObservedObject var model: IngestionModel
    @State private var isTargeted = false
    @State private var showInspector = true
    @State private var showCaptureInfo = false

    private static let gridItemMinWidth: CGFloat = 112
    private static let gridSpacing: CGFloat = 8
    private let columns = [
        GridItem(.adaptive(minimum: gridItemMinWidth, maximum: 140), spacing: gridSpacing)
    ]

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
                    showCaptureInfo.toggle()
                } label: {
                    Label("Browser Capture", systemImage: "puzzlepiece.extension")
                }
                .popover(isPresented: $showCaptureInfo, arrowEdge: .bottom) {
                    captureInfo
                }
            }
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
    }

    // MARK: - Browser capture info

    /// The endpoint status + the token to paste into the Chrome extension.
    private var captureInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Browser Capture", systemImage: "puzzlepiece.extension")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(model.captureEndpointRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.captureEndpointRunning
                     ? "Listening on 127.0.0.1:\(model.capturePort)"
                     : "Endpoint unavailable (port \(model.capturePort) in use)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Extension token")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.captureToken.isEmpty ? "—" : model.captureToken)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.copyCaptureToken()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.captureToken.isEmpty)
            }

            Text("Paste this token into the Atelier Chrome extension's options to authorize captures.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 320)
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
        // A `GeometryReader` gives the width the adaptive grid packs into, so
        // Up/Down can step by the ACTUAL column count; a `ScrollViewReader` lets
        // arrow-key selection scroll the newly-selected thumbnail into view.
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(model.items, id: \.item.id) { detail in
                            Button {
                                model.select(detail)
                            } label: {
                                FolderThumbnail(
                                    image: model.thumbnail(for: detail),
                                    isSelected: model.selectedItemID == detail.item.id)
                            }
                            .buttonStyle(.plain)
                            .id(detail.item.id)
                            .contextMenu {
                                Button("Remove from Folder") {
                                    model.removeFromFolder(assetIDs: [detail.asset.id])
                                }
                                Button("Delete", role: .destructive) {
                                    model.requestDelete(assetIDs: [detail.asset.id])
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                // Focus is required to receive key events; keep click-to-select
                // and ⌫ / Delete (destructive → confirmed) working alongside.
                .focusable()
                .onDeleteCommand { model.requestDeleteSelected() }
                .onKeyPress(.leftArrow) { move(.left, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.rightArrow) { move(.right, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.upArrow) { move(.up, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.downArrow) { move(.down, width: geo.size.width, proxy: proxy) }
            }
        }
        .overlay {
            if model.items.isEmpty {
                Text("No items in this folder yet.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Move the grid selection by one arrow press, then scroll the new selection
    /// into view. Returns `.handled` when a grid item exists to act on (consuming
    /// the arrow), `.ignored` for an empty folder.
    private func move(
        _ key: GridArrowKey, width: CGFloat, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let currentIndex = model.selectedItemID.flatMap { id in
            model.items.firstIndex { $0.item.id == id }
        }
        let columnCount = gridColumnCount(
            availableWidth: width,
            minItemWidth: Self.gridItemMinWidth,
            spacing: Self.gridSpacing)
        guard let target = nextGridIndex(
            from: currentIndex, key: key,
            count: model.items.count, columns: columnCount)
        else { return .ignored }

        let detail = model.items[target]
        if detail.item.id != model.selectedItemID {
            model.select(detail)
        }
        withAnimation { proxy.scrollTo(detail.item.id, anchor: .center) }
        return .handled
    }

    // MARK: - Import actions

    /// Paste from the GENERAL pasteboard into the selected folder. Mirrors the
    /// drop path's three outcomes (backlog B1): ingestible bytes → run them; a
    /// bare image URL (no bytes) → download + ingest it; nothing readable → a
    /// status line, never a silent no-op.
    private func paste() {
        guard model.isReady else { return }
        let pasteboard = NSPasteboard.general
        let inputs = DirectInputReader.inputs(
            from: pasteboard, into: model.selectedFolderID, now: Date())
        if !inputs.isEmpty {
            model.run(inputs: inputs)
        } else if let url = Self.firstWebURL(on: pasteboard) {
            model.ingestRemoteImage(from: url)
        } else {
            model.reportUnreadableDrop()
        }
    }

    /// The first web (`http`/`https`) URL on `pasteboard`, skipping file URLs — the
    /// pasteboard counterpart of ``firstWebURL(in:)`` for the Paste path. Shares
    /// one definition of "web URL" with the reader via `DirectInputReader.isWebURL`.
    private static func firstWebURL(on pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = objects.first(where: { !$0.isFileURL && DirectInputReader.isWebURL($0) }) {
            return url
        }
        if let string = pasteboard.string(forType: .URL),
           let url = URL(string: string), DirectInputReader.isWebURL(url) {
            return url
        }
        return nil
    }

    /// Convert dropped providers into inputs targeting the selected folder,
    /// off-main, then run them.
    ///
    /// A browser image drag delivers its source PAGE URL either on the same
    /// provider as the image or as a separate URL provider, so we collect any
    /// web URL across the whole drop FIRST, then attach it to the image(s) as
    /// provenance — mirroring the pasteboard path (`DirectInputReader.inputs`).
    ///
    /// Three outcomes (backlog B1): the drop carried ingestible bytes → run them;
    /// it carried only a bare image URL (no bytes) → download + ingest it as
    /// `.web`; it carried nothing we can read → a status line, never a silent
    /// no-op.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isReady else { return false }
        let target = model.selectedFolderID
        Task {
            let webURL = await Self.firstWebURL(in: providers)
            var inputs: [IngestInput] = []
            for provider in providers {
                if let input = await Self.input(from: provider, pageURL: webURL, into: target) {
                    inputs.append(input)
                }
            }
            if !inputs.isEmpty {
                model.run(inputs: inputs)
            } else if let webURL {
                // No bytes on the drop, but a web URL — treat it as a direct image
                // URL and download it (a non-image response fails cleanly).
                model.ingestRemoteImage(from: webURL)
            } else {
                model.reportUnreadableDrop()
            }
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
