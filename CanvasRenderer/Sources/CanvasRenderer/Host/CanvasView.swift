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
    /// A request to begin editing a tile's text (054 §5). Token-keyed, so pushing the
    /// same value on every view update starts exactly one edit; `nil` is a no-op and
    /// never ENDS an edit. See ``CanvasHostView/editRequest``.
    private let editRequest: CanvasTextEditRequest?
    /// Editing began (a tile id) or ended (`nil`) — the app mirrors this into its own
    /// state, since the host owns the edit now.
    private let onEditingChanged: ((Int?) -> Void)?
    /// An edit finished: which tile, and what it meant. The app writes the result.
    private let onFinishEditingText: ((Int, CanvasTextEditOutcome) -> Void)?
    private let onActivateTile: ((Int) -> Void)?
    private let onSelectTiles: ((Set<Int>) -> Void)?
    /// A tool key (`v` / `f` / `t`) was pressed on the canvas. Handled there rather
    /// than as a `keyboardShortcut` here, which would fire — and eat the keystroke —
    /// while the user is typing into a text box. See ``CanvasHostView/onSelectTool``.
    private let onSelectTool: ((CanvasTool) -> Void)?
    private let onRemoveTiles: ((Set<Int>) -> Void)?
    private let onDeleteTiles: ((Set<Int>) -> Void)?
    private let onCopyTiles: ((Set<Int>) -> Void)?
    private let onMoveTile: ((Int, CGPoint) -> Void)?
    private let onCreateElement: ((CanvasTool, CGRect) -> Void)?
    private let onResizeTile: ((Int, CGRect) -> Void)?
    /// Fired once per transform mutation (2B · 054 §5.1 · R2) so the inline editor
    /// repositions its overlay imperatively — a plain closure, NOT a `Binding`, so it
    /// never re-evaluates SwiftUI `body` (R15).
    private let onTransformChanged: (() -> Void)?
    /// Peer of the above for a LIVE RESIZE (062), which moves a tile's displayed
    /// frame while the camera stands still — so the editor's overlay hears about
    /// both kinds of movement. See ``CanvasEngine/onLiveFrameChanged``.
    private let onLiveFrameChanged: (() -> Void)?
    /// Handed the freshly-built ``CanvasHostView`` so the app can reach its
    /// ``CanvasHostView/transform`` + ``CanvasHostView/screenFrame(forTileID:)`` for
    /// the inline editor. Fires on make (and again if the host is rebuilt via `.id`).
    private let onHostReady: ((CanvasHostView) -> Void)?
    /// Drop-target seam (059 · SP2 / 4A): the pasteboard types the canvas accepts,
    /// the hover-operation decision, and the drop handler (pasteboard + WORLD point).
    /// All `nil`/empty by default, so a canvas that passes none is not a drop target.
    private let acceptedDropTypes: [NSPasteboard.PasteboardType]
    private let onDragEntered: ((NSPasteboard) -> NSDragOperation)?
    private let onDrop: ((NSPasteboard, CGPoint) -> Bool)?
    private let onPaste: ((NSPasteboard, CGPoint) -> Bool)?
    private let onBeginTileDragOut: ((Set<Int>) -> NSPasteboardItem?)?
    /// Whether this canvas may still frame its content to fit — the app arms it for a
    /// board's FIRST open only, so no later reload moves the camera. See
    /// ``CanvasHostView/framesContentWhenReady``.
    private let framesContentWhenReady: Bool
    /// Fired the one time the framing actually happened.
    private let onDidFrameContent: (() -> Void)?

    public init(
        provider: any TileProvider,
        images: any TileImageSource,
        selectedTileIDs: Set<Int> = [],
        syncToken: Int = 0,
        tool: CanvasTool = .select,
        editRequest: CanvasTextEditRequest? = nil,
        onActivateTile: ((Int) -> Void)? = nil,
        onSelectTiles: ((Set<Int>) -> Void)? = nil,
        onSelectTool: ((CanvasTool) -> Void)? = nil,
        onRemoveTiles: ((Set<Int>) -> Void)? = nil,
        onDeleteTiles: ((Set<Int>) -> Void)? = nil,
        onCopyTiles: ((Set<Int>) -> Void)? = nil,
        onMoveTile: ((Int, CGPoint) -> Void)? = nil,
        onCreateElement: ((CanvasTool, CGRect) -> Void)? = nil,
        onResizeTile: ((Int, CGRect) -> Void)? = nil,
        onTransformChanged: (() -> Void)? = nil,
        onLiveFrameChanged: (() -> Void)? = nil,
        onHostReady: ((CanvasHostView) -> Void)? = nil,
        acceptedDropTypes: [NSPasteboard.PasteboardType] = [],
        onDragEntered: ((NSPasteboard) -> NSDragOperation)? = nil,
        onDrop: ((NSPasteboard, CGPoint) -> Bool)? = nil,
        onPaste: ((NSPasteboard, CGPoint) -> Bool)? = nil,
        onBeginTileDragOut: ((Set<Int>) -> NSPasteboardItem?)? = nil,
        framesContentWhenReady: Bool = true,
        onDidFrameContent: (() -> Void)? = nil,
        onEditingChanged: ((Int?) -> Void)? = nil,
        onFinishEditingText: ((Int, CanvasTextEditOutcome) -> Void)? = nil
    ) {
        self.provider = provider
        self.images = images
        self.selectedTileIDs = selectedTileIDs
        self.syncToken = syncToken
        self.tool = tool
        self.editRequest = editRequest
        self.onActivateTile = onActivateTile
        self.onSelectTiles = onSelectTiles
        self.onRemoveTiles = onRemoveTiles
        self.onDeleteTiles = onDeleteTiles
        self.onCopyTiles = onCopyTiles
        self.onMoveTile = onMoveTile
        self.onCreateElement = onCreateElement
        self.onResizeTile = onResizeTile
        self.onTransformChanged = onTransformChanged
        self.onLiveFrameChanged = onLiveFrameChanged
        self.onHostReady = onHostReady
        self.acceptedDropTypes = acceptedDropTypes
        self.onDragEntered = onDragEntered
        self.onDrop = onDrop
        self.onPaste = onPaste
        self.onBeginTileDragOut = onBeginTileDragOut
        self.framesContentWhenReady = framesContentWhenReady
        self.onDidFrameContent = onDidFrameContent
        self.onEditingChanged = onEditingChanged
        self.onFinishEditingText = onFinishEditingText
        self.onSelectTool = onSelectTool
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
        view.onSelectTool = onSelectTool
        view.onRemoveTiles = onRemoveTiles
        view.onDeleteTiles = onDeleteTiles
        view.onCopyTiles = onCopyTiles
        view.onMoveTile = onMoveTile
        view.onCreateElement = onCreateElement
        view.onResizeTile = onResizeTile
        view.onTransformChanged = onTransformChanged
        view.onLiveFrameChanged = onLiveFrameChanged
        view.onDragEntered = onDragEntered
        view.onDrop = onDrop
        view.onPaste = onPaste
        view.onBeginTileDragOut = onBeginTileDragOut
        // Assign the registered types AFTER the handlers so a drop arriving between
        // the two assignments still finds `onDrop` in place.
        view.acceptedDropTypes = acceptedDropTypes
        // Both BEFORE `syncToken`: its didSet may frame, and must see the current
        // arming state and be able to report back through the current closure.
        view.onDidFrameContent = onDidFrameContent
        view.framesContentWhenReady = framesContentWhenReady
        view.tool = tool
        view.onEditingChanged = onEditingChanged
        view.onFinishEditingText = onFinishEditingText
        view.syncToken = syncToken
        view.selectedTileIDs = selectedTileIDs
        // LAST: an edit request is applied the moment it lands, so everything it needs
        // — the callbacks, the tool, the freshly synced geometry — must be in place.
        view.editRequest = editRequest
    }
}
