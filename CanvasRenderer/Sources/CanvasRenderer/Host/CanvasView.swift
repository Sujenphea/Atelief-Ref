import SwiftUI

/// The active canvas tool (E3). `select` is the classic pan / select / drag mode;
/// `frame` / `text` are *create* modes — a drag rubber-bands a world rect that the
/// host reports via ``CanvasHostView/onCreateElement`` to place a new element.
public enum CanvasTool: Equatable, Sendable {
    case select
    case frame
    case text
}

/// SwiftUI wrapper around ``CanvasHostView``. Drives the canvas from any
/// ``TileProvider`` + ``TileImageSource`` — the spike passes its dummy generator
/// and fixture set; build-order step 5's real view passes a `CollectionItem`-
/// backed provider/source. The host is rebuilt (not mutated) when the content
/// changes, so callers swap boards with SwiftUI's `.id(_:)`.
public struct CanvasView: NSViewRepresentable {
    private let provider: any TileProvider
    private let images: any TileImageSource
    private let selectedTileIDs: Set<Int>
    private let syncToken: Int
    private let tool: CanvasTool
    private let onActivateTile: ((Int) -> Void)?
    private let onSelectTiles: ((Set<Int>) -> Void)?
    private let onRemoveTiles: ((Set<Int>) -> Void)?
    private let onDeleteTiles: ((Set<Int>) -> Void)?
    private let onCopyTiles: ((Set<Int>) -> Void)?
    private let onMoveTile: ((Int, CGPoint) -> Void)?
    private let onCreateElement: ((CanvasTool, CGRect) -> Void)?

    public init(
        provider: any TileProvider,
        images: any TileImageSource,
        selectedTileIDs: Set<Int> = [],
        syncToken: Int = 0,
        tool: CanvasTool = .select,
        onActivateTile: ((Int) -> Void)? = nil,
        onSelectTiles: ((Set<Int>) -> Void)? = nil,
        onRemoveTiles: ((Set<Int>) -> Void)? = nil,
        onDeleteTiles: ((Set<Int>) -> Void)? = nil,
        onCopyTiles: ((Set<Int>) -> Void)? = nil,
        onMoveTile: ((Int, CGPoint) -> Void)? = nil,
        onCreateElement: ((CanvasTool, CGRect) -> Void)? = nil
    ) {
        self.provider = provider
        self.images = images
        self.selectedTileIDs = selectedTileIDs
        self.syncToken = syncToken
        self.tool = tool
        self.onActivateTile = onActivateTile
        self.onSelectTiles = onSelectTiles
        self.onRemoveTiles = onRemoveTiles
        self.onDeleteTiles = onDeleteTiles
        self.onCopyTiles = onCopyTiles
        self.onMoveTile = onMoveTile
        self.onCreateElement = onCreateElement
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        let view = CanvasHostView(provider: provider, images: images)
        apply(to: view)
        return view
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        apply(to: nsView)
    }

    /// Push the current closures + selection + tool onto the host. Selection is
    /// set last so an externally-driven change (e.g. selecting in another view)
    /// reflects into the highlight.
    private func apply(to view: CanvasHostView) {
        view.onActivateTile = onActivateTile
        view.onSelectTiles = onSelectTiles
        view.onRemoveTiles = onRemoveTiles
        view.onDeleteTiles = onDeleteTiles
        view.onCopyTiles = onCopyTiles
        view.onMoveTile = onMoveTile
        view.onCreateElement = onCreateElement
        view.tool = tool
        view.syncToken = syncToken
        view.selectedTileIDs = selectedTileIDs
    }
}
