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
    /// The tile an inline text editor is editing (2B · 054 §5.1), or `nil`. Pushed to
    /// the host so the engine blanks that tile's `CATextLayer` while editing.
    private let editingTileID: Int?
    private let onActivateTile: ((Int) -> Void)?
    private let onSelectTiles: ((Set<Int>) -> Void)?
    private let onRemoveTiles: ((Set<Int>) -> Void)?
    private let onDeleteTiles: ((Set<Int>) -> Void)?
    private let onCopyTiles: ((Set<Int>) -> Void)?
    private let onMoveTile: ((Int, CGPoint) -> Void)?
    private let onCreateElement: ((CanvasTool, CGRect) -> Void)?
    /// Fired once per transform mutation (2B · 054 §5.1 · R2) so the inline editor
    /// repositions its overlay imperatively — a plain closure, NOT a `Binding`, so it
    /// never re-evaluates SwiftUI `body` (R15).
    private let onTransformChanged: (() -> Void)?
    /// Handed the freshly-built ``CanvasHostView`` so the app can reach its
    /// ``CanvasHostView/transform`` + ``CanvasHostView/screenFrame(forTileID:)`` for
    /// the inline editor. Fires on make (and again if the host is rebuilt via `.id`).
    private let onHostReady: ((CanvasHostView) -> Void)?

    public init(
        provider: any TileProvider,
        images: any TileImageSource,
        selectedTileIDs: Set<Int> = [],
        syncToken: Int = 0,
        tool: CanvasTool = .select,
        editingTileID: Int? = nil,
        onActivateTile: ((Int) -> Void)? = nil,
        onSelectTiles: ((Set<Int>) -> Void)? = nil,
        onRemoveTiles: ((Set<Int>) -> Void)? = nil,
        onDeleteTiles: ((Set<Int>) -> Void)? = nil,
        onCopyTiles: ((Set<Int>) -> Void)? = nil,
        onMoveTile: ((Int, CGPoint) -> Void)? = nil,
        onCreateElement: ((CanvasTool, CGRect) -> Void)? = nil,
        onTransformChanged: (() -> Void)? = nil,
        onHostReady: ((CanvasHostView) -> Void)? = nil
    ) {
        self.provider = provider
        self.images = images
        self.selectedTileIDs = selectedTileIDs
        self.syncToken = syncToken
        self.tool = tool
        self.editingTileID = editingTileID
        self.onActivateTile = onActivateTile
        self.onSelectTiles = onSelectTiles
        self.onRemoveTiles = onRemoveTiles
        self.onDeleteTiles = onDeleteTiles
        self.onCopyTiles = onCopyTiles
        self.onMoveTile = onMoveTile
        self.onCreateElement = onCreateElement
        self.onTransformChanged = onTransformChanged
        self.onHostReady = onHostReady
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        let view = CanvasHostView(provider: provider, images: images)
        apply(to: view)
        onHostReady?(view) // hand the live host to the app (inline-editor plumbing)
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
        view.onTransformChanged = onTransformChanged
        view.tool = tool
        view.editingTileID = editingTileID
        view.syncToken = syncToken
        view.selectedTileIDs = selectedTileIDs
    }
}
