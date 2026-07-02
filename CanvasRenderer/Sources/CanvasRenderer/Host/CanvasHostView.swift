import AppKit

/// Thin `NSView` host (decision C5: the side-effecting boundary). It owns events
/// and the layer tree, and delegates all rendering decisions to ``CanvasEngine``.
/// Scroll pans, pinch zooms, layout/resize re-syncs.
@MainActor
public final class CanvasHostView: NSView {
    private let engine: CanvasEngine
    private var hasFramedContent = false

    /// Called with a tile's id when the user double-clicks it (e.g. to open a
    /// video). Set by the host; `nil` disables activation.
    public var onActivateTile: ((Int) -> Void)?

    /// Called when the selection changes via a click: a tile's id when one is
    /// clicked, or `nil` when empty space is clicked (deselect). `nil` disables.
    public var onSelectTile: ((Int?) -> Void)?

    /// Called with a tile's id for the context-menu "Remove from Folder".
    public var onRemoveTile: ((Int) -> Void)?

    /// Called with a tile's id for a destructive delete — the context-menu
    /// "Delete" or the ⌫ / Delete key on the current selection.
    public var onDeleteTile: ((Int) -> Void)?

    /// Called when a tile is dragged to a new position: its id and the FINAL
    /// world-space origin. The host updates the provider in memory (so the tile
    /// stays put) and persists off-main. `nil` disables drag-to-place.
    public var onMoveTile: ((Int, CGPoint) -> Void)?

    // MARK: Drag tracking (click-vs-drag)

    /// The screen point of the current `mouseDown`, or `nil` when not tracking.
    private var dragStartPoint: CGPoint?
    /// The tile hit at `mouseDown` — the drag candidate (nil over empty space).
    private var dragCandidateTileID: Int?
    /// Whether movement has passed the threshold and a live drag is in progress.
    private var isDragging = false
    /// Screen-point movement before a press-and-move becomes a drag (not a click).
    static let dragThreshold: CGFloat = 3

    /// Whether a cumulative press-move `delta` (screen points) is far enough to
    /// count as a drag rather than a click. Pure + static so it's unit-testable.
    static func exceedsDragThreshold(_ delta: CGSize, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(delta.width, delta.height) > threshold
    }

    /// Reflect an externally-driven selection (e.g. the host selected an item in
    /// another view) into the engine's highlight.
    public var selectedTileID: Int? {
        get { engine.selectedTileID }
        set { engine.setSelected(newValue) }
    }

    public init(
        provider: TileProvider,
        images: any TileImageSource,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 800)
    ) {
        self.engine = CanvasEngine(provider: provider, images: images, viewportSize: frame.size)
        super.init(frame: frame)

        // Layer-hosting view: install the engine's root layer, then opt in.
        layer = engine.rootLayer
        wantsLayer = true
        engine.rootLayer.frame = bounds
        engine.sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left origin so world-y grows downward, the usual canvas feel.
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        engine.rootLayer.frame = bounds
        engine.viewportSize = bounds.size
        // Frame the board to fit the very first time we know our size; afterwards
        // a resize just re-syncs (it must not stomp the user's pan/zoom).
        if !hasFramedContent, bounds.width > 0, bounds.height > 0 {
            hasFramedContent = true
            engine.frameToContent()
        } else {
            engine.sync()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        engine.pan(byScreenDelta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    public override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        engine.zoom(by: 1 + event.magnification, aroundScreenPoint: anchor)
    }

    /// A single click selects the tile under the cursor (or clears the selection
    /// on empty space); a double-click also activates it (e.g. play a video).
    /// Panning/zooming stay on scroll/pinch, so a click is free to select.
    public override func mouseDown(with event: NSEvent) {
        // Become first responder so the ⌫ / Delete key reaches ``keyDown``.
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let tileID = engine.tile(atScreenPoint: point)?.id
        selectTile(tileID)
        if event.clickCount == 2, let tileID {
            onActivateTile?(tileID)
        }
        // Arm click-vs-drag: a tile hit is a drag candidate; empty space isn't
        // (panning stays on scroll, so a drag over the void does nothing).
        dragStartPoint = point
        dragCandidateTileID = tileID
        isDragging = false
    }

    /// Once movement passes the threshold, begin (then continue) a live drag of
    /// the candidate tile. Empty-space presses never drag. The delta is
    /// cumulative from the press point, so the engine can replace its offset.
    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint, let tileID = dragCandidateTileID else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
        if !isDragging {
            guard Self.exceedsDragThreshold(delta) else { return }
            isDragging = true
            engine.beginDrag(tileID: tileID)
        }
        engine.updateDrag(byScreenDelta: delta)
    }

    /// Finalize a drag: hand the final origin to the host (which updates the
    /// provider in memory + persists), THEN sync — so the tile stays put with no
    /// flicker and the viewport is untouched. A press with no drag is a plain
    /// click (already handled on down), so it's a no-op here.
    public override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
            dragCandidateTileID = nil
            isDragging = false
        }
        guard isDragging else { return }
        if let result = engine.endDrag() {
            onMoveTile?(result.tileID, result.worldOrigin)
        }
        engine.sync()
    }

    /// Right-click: select the tile under the cursor and offer Remove / Delete.
    /// Returns `nil` (no menu) over empty space.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let tile = engine.tile(atScreenPoint: point) else { return nil }
        selectTile(tile.id)

        let menu = NSMenu()
        let remove = NSMenuItem(
            title: "Remove from Folder", action: #selector(contextRemove), keyEquivalent: "")
        remove.target = self
        let delete = NSMenuItem(
            title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(remove)
        menu.addItem(delete)
        return menu
    }

    /// The ⌫ / Delete keys delete the current selection (⌦ forward-delete too).
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // 51 = Delete (Backspace), 117 = Forward Delete. Both mean "delete".
        if (event.keyCode == 51 || event.keyCode == 117), let id = engine.selectedTileID {
            onDeleteTile?(id)
            return
        }
        super.keyDown(with: event)
    }

    /// Update the engine's highlight and notify the host of the new selection.
    private func selectTile(_ id: Int?) {
        engine.setSelected(id)
        onSelectTile?(id)
    }

    @objc private func contextRemove() {
        if let id = engine.selectedTileID { onRemoveTile?(id) }
    }

    @objc private func contextDelete() {
        if let id = engine.selectedTileID { onDeleteTile?(id) }
    }
}
