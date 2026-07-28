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

    /// Called when the selection changes via a click / marquee: the full set of
    /// selected tile ids (empty when the selection is cleared). `nil` disables.
    public var onSelectTiles: ((Set<Int>) -> Void)?

    /// Called with the selected tile ids for the context-menu "Remove from Folder".
    public var onRemoveTiles: ((Set<Int>) -> Void)?

    /// Called with the selected tile ids for a destructive delete — the context-menu
    /// "Delete" or the ⌫ / Delete key on the current selection.
    public var onDeleteTiles: ((Set<Int>) -> Void)?

    /// Called with the selected tile ids for Edit ▸ Copy (⌘C, 052 · B1). The host
    /// maps them to assets and writes the pasteboard; `nil` disables Copy.
    public var onCopyTiles: ((Set<Int>) -> Void)?

    /// Called when a tile is dragged to a new position: its id and the FINAL
    /// world-space origin. The host updates the provider in memory (so the tile
    /// stays put) and persists off-main. During a frame group-drag it fires once
    /// per carried tile. `nil` disables drag-to-place.
    public var onMoveTile: ((Int, CGPoint) -> Void)?

    /// Called when a create tool (``CanvasTool/frame`` / ``CanvasTool/text``)
    /// finishes rubber-banding: the tool and the new element's WORLD-space rect.
    /// The host places the element and (typically) flips back to `.select`.
    public var onCreateElement: ((CanvasTool, CGRect) -> Void)?

    /// Called when a resize-handle drag finishes: the tile's id and its FINAL
    /// WORLD-space rect (062). Peer of ``onMoveTile`` — the host updates the
    /// provider in memory and persists off-main. For a text box the host is expected
    /// to treat the rect's WIDTH as authoritative and re-derive the height from the
    /// wrapped text, so the two never disagree. `nil` disables resizing.
    public var onResizeTile: ((Int, CGRect) -> Void)?

    /// The active tool. `.select` pans / selects / drags; `.frame` / `.text`
    /// rubber-band a new element instead.
    public var tool: CanvasTool = .select

    // MARK: Drop destination (059 · SP2 / 4A — external + library drops)

    /// Pasteboard types this canvas accepts as a DROP target. The app sets these
    /// (e.g. its app-private asset-drag type, and later file / image / URL types
    /// for external import). Empty means the canvas is not a drop target. Setting
    /// re-registers the view's dragged types, so a `nil`/empty assignment cleanly
    /// disables dropping. This is AppKit (not SwiftUI `.onDrop`) on purpose: the
    /// canvas already owns mouse-drag / marquee / pan gestures, and an
    /// `NSDraggingDestination` composes with them without fighting for the event.
    public var acceptedDropTypes: [NSPasteboard.PasteboardType] = [] {
        didSet {
            unregisterDraggedTypes()
            if !acceptedDropTypes.isEmpty { registerForDraggedTypes(acceptedDropTypes) }
        }
    }

    /// Decide the drag operation to advertise while a drag hovers (the cursor
    /// badge). The app inspects the drag pasteboard and returns `.copy` to accept
    /// or `[]` to refuse. `nil` → accept as `.copy` whenever any accepted type is
    /// present. Kept app-side so the package never needs the app's payload types.
    public var onDragEntered: ((NSPasteboard) -> NSDragOperation)?

    /// Handle a drop. The app receives the drag pasteboard and the WORLD point
    /// under the drop — computed HERE via the same ``CanvasTransform`` hit-testing
    /// uses (decision C6), so a dropped item lands exactly where the cursor is with
    /// zero chance of drift. Returns whether the drop was accepted. `nil` disables
    /// dropping regardless of ``acceptedDropTypes``.
    public var onDrop: ((_ pasteboard: NSPasteboard, _ worldPoint: CGPoint) -> Bool)?

    /// Handle Edit ▸ Paste (⌘V) when the canvas holds focus (059 · SP4, the paste
    /// peer of the ⌘C ``onCopyTiles`` seam / 236). The app receives the general
    /// pasteboard and the world point at the VIEWPORT CENTRE — a paste has no cursor
    /// location, so pasted content lands in the middle of what the user is looking
    /// at. Returns whether the paste was handled. `nil` disables Paste. Because this
    /// is a responder-chain action, a focused text field (e.g. the inline text
    /// editor) still gets ⌘V first — the canvas only pastes when IT holds focus.
    public var onPaste: ((_ pasteboard: NSPasteboard, _ worldPoint: CGPoint) -> Bool)?

    /// Start a board→board / board→collection drag-OUT (059 · SP7). Given the
    /// carried tile ids, the app returns an `NSPasteboardItem` carrying its
    /// asset-drag payload (or `nil` when nothing draggable-out is carried, e.g. only
    /// element tiles). When non-nil AND ⌥ is held at press, an ⌥-drag on a tile
    /// starts an `NSDraggingSession` with that item INSTEAD of an in-view move, so it
    /// can land on a sidebar space / collection row. ⌥ (copy) matches the additive
    /// board→board semantics — the source tile stays put, no snap-back. `nil`
    /// disables drag-out (in-view move only).
    public var onBeginTileDragOut: ((Set<Int>) -> NSPasteboardItem?)?

    /// True while THIS view is the source of an in-flight drag-out session — used to
    /// refuse a drop of our own drag back onto the SAME board (a board→board copy
    /// onto the source would duplicate in place, 059 · SP7).
    private var isActiveDragSource = false

    /// ⌥ state captured at `mouseDown`, gating ⌥-drag drag-out at the threshold.
    private var pressOptionDown = false

    /// Forwarded from the engine (2B · 054 §5.1 · R2): fired once per transform
    /// mutation so the app's inline text editor can reposition its overlay
    /// imperatively, off the SwiftUI diff. `nil` disables it. Wired to the engine in
    /// ``init`` so any transform source (pan/zoom/setTransform/frameToContent)
    /// notifies through this one seam.
    public var onTransformChanged: (() -> Void)?

    /// Forwarded from the engine (062): fired when a live resize moves a tile's
    /// displayed frame with the camera standing still. The editor's overlay is
    /// positioned from that frame, so it has to hear about both kinds of movement —
    /// see ``CanvasEngine/onLiveFrameChanged``.
    public var onLiveFrameChanged: (() -> Void)?

    /// The tile an app-layer inline editor is editing (2B), or `nil`. Forwarded to
    /// the engine, which blanks that tile's `CATextLayer` while the `NSTextView`
    /// overlay is up (054 §5.2) so glyphs aren't doubled.
    public var editingTileID: Int? {
        get { engine.editingTileID }
        set { engine.editingTileID = newValue }
    }

    /// The current world↔screen transform (2B · 054 §5.1) — read by the inline
    /// editor to scale its measured overlay size to screen points.
    public var transform: CanvasTransform { engine.transform }

    /// The on-screen frame a tile is currently drawn at, or `nil` if it isn't
    /// visible (2B · 054 §5.1). The inline editor positions its `NSTextView` from
    /// this on each ``onTransformChanged``; a `nil` result means the tile scrolled
    /// out of the viewport → commit-and-exit (054 §5.4).
    public func screenFrame(forTileID id: Int) -> CGRect? {
        engine.currentScreenFrame(forTileID: id)
    }

    // MARK: Element-create tracking (rubber-band)

    /// Screen point of the create `mouseDown`, or `nil` when not creating.
    private var createStartPoint: CGPoint?
    /// The dashed preview rect shown while rubber-banding a new element.
    private var createPreviewLayer: CALayer?

    // MARK: Drag tracking (click-vs-drag)

    /// The screen point of the current `mouseDown`, or `nil` when not tracking.
    private var dragStartPoint: CGPoint?
    /// The tile hit at `mouseDown` — the drag candidate (nil over empty space).
    private var dragCandidateTileID: Int?
    /// A selection action deferred from `mouseDown` to the mouse-UP click: applied
    /// only if the press did NOT become a drag (049 · D6). Carries the plain-press-
    /// on-a-selected-tile collapse-to-one, and the empty-space click-to-clear.
    private var pendingClickAction: CanvasSelectionAction?
    /// Whether movement has passed the threshold and a live drag is in progress.
    private var isDragging = false
    /// Screen-point movement before a press-and-move becomes a drag (not a click).
    static let dragThreshold: CGFloat = 3

    // MARK: Resize tracking (handle drag — 062)

    /// The handle grabbed at `mouseDown`, or `nil` when the press missed every
    /// handle. Armed on the down edge; the resize itself only begins once movement
    /// passes the drag threshold, so a click on a handle stays a click.
    private var resizeCandidate: (tileID: Int, handle: ResizeHandle)?
    /// Whether a live resize is in progress.
    private var isResizing = false
    /// The handle the pointer is currently over, so `mouseMoved` only touches
    /// `NSCursor` when the answer actually changes. Tracked as the HANDLE rather
    /// than the cursor because `NSCursor.frameResize` vends a fresh instance per
    /// call, which would make an identity comparison always differ.
    private var hoveredHandle: ResizeHandle?
    /// Tracking area backing the hover cursor.
    private var hoverTrackingArea: NSTrackingArea?

    // MARK: Marquee tracking (rubber-band selection — 049 · D2 / PR 2)

    /// The marquee's anchor in **world** space, captured at the empty-space
    /// `mouseDown`, or `nil` when no marquee is armed. World-anchored (not screen)
    /// so edge auto-pan — which mutates the transform under a stationary pointer —
    /// grows the box correctly: the anchor stays pinned to the world point where the
    /// drag began while the opposite corner tracks the pointer through the new
    /// transform.
    private var marqueeAnchorWorld: CGPoint?
    /// The latest pointer position in screen space during a marquee — the moving
    /// corner, and the input the auto-pan ramp reads each vsync (the pointer doesn't
    /// move on its own while auto-panning, so the tick reuses this).
    private var marqueeCurrentScreen: CGPoint?
    /// The selection captured when the marquee began: empty for a plain marquee, the
    /// prior selection for a ⇧-additive one (`.marquee(hits:base:)` unions the two).
    private var marqueeBase: Set<Int> = []
    /// Whether the marquee has passed the drag threshold. Below it an empty-space
    /// mouse-up is a click (the deferred click-to-clear), at/above it it's a marquee.
    private var isMarqueeing = false
    /// The translucent rubber-band overlay, in SCREEN space (like the create
    /// preview). Created on the first marquee tick, removed on end.
    private var marqueeLayer: CALayer?
    /// The display link driving edge auto-pan while marqueeing. Vended off this view
    /// (an `NSView` can vend its own link); a minimal peer of the grid's
    /// `DisplayLinkPump`, inlined here to keep `CanvasRenderer` dependency-free.
    private var autoPanLink: CADisplayLink?

    /// Screen-point edge band within which a marquee triggers auto-pan, and the
    /// pt/sec velocity ramp across it — mirrors the grid marquee's `edgeZone` /
    /// `minSpeed` / `maxSpeed` so the feel matches.
    static let autoPanEdgeZone: CGFloat = 28
    static let autoPanMinSpeed: CGFloat = 180
    static let autoPanMaxSpeed: CGFloat = 1080

    /// The screen-space auto-pan velocity (pt/sec) for a marquee whose pointer sits
    /// at `pointer` in a viewport of `size`. Zero when the pointer is clear of all
    /// four edge zones; otherwise, per axis, it ramps from `autoPanMinSpeed` at the
    /// zone's inner edge to `autoPanMaxSpeed` at (or past) the viewport edge.
    ///
    /// The SIGN pans so the world under the pointer EXTENDS toward that edge (content
    /// shifts the opposite way, matching `pan(byScreenDelta:)`'s translation add):
    /// near the LEFT/TOP edge the delta is positive (translation grows → the world
    /// point under the pointer moves toward the origin → the box extends left/up);
    /// near the RIGHT/BOTTOM edge it is negative. Pure + static so the ramp is
    /// unit-testable without a window or display link.
    static func marqueeAutoPanVelocity(pointer: CGPoint, in size: CGSize) -> CGSize {
        func axis(_ p: CGFloat, _ extent: CGFloat) -> CGFloat {
            if p < autoPanEdgeZone {
                return autoPanSpeed(penetration: autoPanEdgeZone - p)          // toward origin
            } else if p > extent - autoPanEdgeZone {
                return -autoPanSpeed(penetration: p - (extent - autoPanEdgeZone)) // away from origin
            }
            return 0
        }
        return CGSize(width: axis(pointer.x, size.width), height: axis(pointer.y, size.height))
    }

    /// Velocity ramp (pt/sec): penetration 0 → `autoPanMinSpeed`, a full zone depth
    /// (or past the viewport edge) → `autoPanMaxSpeed`. Matches the grid marquee.
    private static func autoPanSpeed(penetration: CGFloat) -> CGFloat {
        let t = min(max(penetration / autoPanEdgeZone, 0), 1)
        return autoPanMinSpeed + t * (autoPanMaxSpeed - autoPanMinSpeed)
    }

    /// Whether a cumulative press-move `delta` (screen points) is far enough to
    /// count as a drag rather than a click. Pure + static so it's unit-testable.
    static func exceedsDragThreshold(_ delta: CGSize, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(delta.width, delta.height) > threshold
    }

    /// Reflect an externally-driven selection (e.g. the model pushed a selection
    /// change) into the engine's highlights. Idempotent, so the round-trip with
    /// ``onSelectTiles`` settles without a loop.
    public var selectedTileIDs: Set<Int> {
        get { engine.selectedTileIDs }
        set { engine.setSelected(newValue) }
    }

    /// A monotonic token the SwiftUI layer bumps to force a re-sync WITHOUT a full
    /// host rebuild — the provider's tiles were mutated in place (e.g. align /
    /// distribute) with no drag gesture and no selection change to otherwise drive
    /// `sync()`. Setting a new value redraws from the provider's current tiles.
    public var syncToken: Int = 0 {
        didSet {
            guard syncToken != oldValue else { return }
            engine.sync()
        }
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
        // Forward the engine-sourced transform notification outward (2B · 054 §5.1):
        // any transform mutation (pan/zoom/setTransform/frameToContent) reaches the
        // app through this one seam.
        engine.onTransformChanged = { [weak self] in self?.onTransformChanged?() }
        // …and its peer for a live resize (062), which moves the box under a still
        // camera and so never reaches the notification above.
        engine.onLiveFrameChanged = { [weak self] in self?.onLiveFrameChanged?() }
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

    /// If the host leaves its window mid-gesture (e.g. a content reload rebuilds it
    /// via `.id`), invalidate the auto-pan link so it can't retain a detached view.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endMarquee() }
    }

    // MARK: Hover cursor (resize handles — 062)

    /// A handle is a small target, so the pointer has to say when it's over one —
    /// without the cursor change the 22pt grab zone is invisible and undiscoverable.
    /// `.inVisibleRect` keeps the area in step with scrolling/resizing on its own.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHoverCursor()
    }

    /// Point the cursor at whatever handle is under `point` (or back to the arrow).
    /// Suppressed mid-gesture: during a drag or resize the cursor belongs to that
    /// gesture, and a create tool has its own meaning for a press.
    private func updateHoverCursor(at point: CGPoint) {
        guard !isResizing, !isDragging, !isMarqueeing, tool == .select, onResizeTile != nil else {
            return
        }
        let handle = engine.resizeHandle(atScreenPoint: point)?.handle
        guard handle != hoveredHandle else { return }
        hoveredHandle = handle
        (handle.map(Self.cursor(for:)) ?? .arrow).set()
    }

    private func clearHoverCursor() {
        guard hoveredHandle != nil else { return }
        hoveredHandle = nil
        NSCursor.arrow.set()
    }

    /// The directional resize cursor for a handle.
    ///
    /// `NSCursor.frameResize` (macOS 15+) is the only public API that gives true
    /// diagonal corner cursors. Below it AppKit exposes just the two axis cursors,
    /// so a corner falls back to the horizontal one — honest rather than arbitrary,
    /// since width is the axis that survives a text resize anyway. The package
    /// targets macOS 14, so this stays a runtime check rather than a floor bump.
    static func cursor(for handle: ResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch handle {
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .left: return .frameResize(position: .left, directions: .all)
            }
        }
        switch handle {
        case .top, .bottom: return .resizeUpDown
        default: return .resizeLeftRight
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
        resetGestureState()

        // Gesture precedence (049 · D8 · 062), highest to lowest:
        //  1. A create tool (`.frame` / `.text`) → rubber-band a NEW element.
        //  2. `.select` on a resize HANDLE → a resize candidate.
        //  3. `.select` on a TILE → a drag candidate (press routing selects).
        //  4. `.select` on EMPTY space → a marquee candidate (or click-to-clear).
        if tool != .select {
            createStartPoint = point
            return
        }

        // Handles sit ON the tile's edge, so they must be tested BEFORE the body:
        // otherwise every handle press would be swallowed as a move of the tile
        // beneath it.
        if onResizeTile != nil, let hit = engine.resizeHandle(atScreenPoint: point) {
            resizeCandidate = hit
            dragStartPoint = point
            return
        }

        let tileID = engine.tile(atScreenPoint: point)?.id
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        pressOptionDown = event.modifierFlags.contains(.option) // ⌥ → drag-out (SP7)

        if let tileID {
            // Route the press through the selection reducer: ⇧/⌘ act on the down
            // edge; a plain press on a SELECTED tile defers (so a drag carries the
            // whole selection), collapsing to one only if it stays a click. Arm the
            // tile as the drag candidate.
            let routing = canvasPressRouting(
                tileID: tileID,
                isSelected: engine.selectedTileIDs.contains(tileID),
                shift: shift, command: command)
            if let press = routing.pressAction { applySelection(press) }
            pendingClickAction = routing.clickAction
            if event.clickCount == 2 { onActivateTile?(tileID) }
            dragStartPoint = point
            dragCandidateTileID = tileID
        } else {
            // Empty space: arm a rubber-band marquee anchored in WORLD space (so
            // edge auto-pan grows it correctly), and defer a click-to-clear to
            // mouse-UP — applied only if the press never becomes a marquee. A ⇧
            // press is additive: it neither clears on a bare click nor resets the
            // base (the marquee unions its hits onto the current selection).
            dragStartPoint = point
            marqueeAnchorWorld = engine.transform.screenToWorld(point)
            marqueeCurrentScreen = point
            marqueeBase = shift ? engine.selectedTileIDs : []
            pendingClickAction = (!shift && !engine.selectedTileIDs.isEmpty) ? .clear : nil
        }
    }

    /// Clear all transient press/drag/marquee state so a fresh `mouseDown` never
    /// inherits a stale candidate from an interrupted gesture.
    private func resetGestureState() {
        createStartPoint = nil
        dragStartPoint = nil
        dragCandidateTileID = nil
        pendingClickAction = nil
        isDragging = false
        marqueeAnchorWorld = nil
        marqueeCurrentScreen = nil
        marqueeBase = []
        isMarqueeing = false
        pressOptionDown = false
        resizeCandidate = nil
        isResizing = false
    }

    /// Once movement passes the threshold, begin (then continue) a live drag of
    /// the candidate tile. Empty-space presses never drag. The delta is
    /// cumulative from the press point, so the engine can replace its offset.
    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Rubber-band a new element under a create tool.
        if tool != .select, let start = createStartPoint {
            updateCreatePreview(from: start, to: point)
            return
        }

        // Resize: an armed handle takes precedence over everything below. Past the
        // threshold the engine draws the tile at the live frame; the provider is
        // untouched until mouse-UP.
        if let candidate = resizeCandidate, let start = dragStartPoint {
            if !isResizing {
                let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
                guard Self.exceedsDragThreshold(delta) else { return }
                isResizing = true
                engine.beginResize(tileID: candidate.tileID, handle: candidate.handle)
            }
            // ⇧ locks the ratio (an image locks its own regardless); ⌘ turns snapping
            // off, matching the move gesture's "put it exactly here" escape.
            engine.updateResize(
                toWorldPoint: engine.transform.screenToWorld(point),
                constrainRatio: event.modifierFlags.contains(.shift),
                snapping: !event.modifierFlags.contains(.command))
            return
        }

        // Marquee on empty space: no tile candidate, but an armed world anchor.
        // Once past the threshold it selects live and (if the pointer nears an
        // edge) auto-pans; below the threshold it is still a pending click-to-clear.
        if dragCandidateTileID == nil, marqueeAnchorWorld != nil, let start = dragStartPoint {
            marqueeCurrentScreen = point
            if !isMarqueeing {
                let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
                guard Self.exceedsDragThreshold(delta) else { return }
                isMarqueeing = true
                pendingClickAction = nil // it became a marquee, not a click
            }
            updateMarquee()
            updateAutoPan()
            return
        }

        guard let start = dragStartPoint, let tileID = dragCandidateTileID else { return }
        let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
        if !isDragging {
            guard Self.exceedsDragThreshold(delta) else { return }
            isDragging = true
            pendingClickAction = nil // it became a drag, not a click
            // Finder rule: dragging a tile that isn't part of the selection selects
            // only it first (so the highlight + carried set are consistent). A drag
            // on a selected tile keeps the whole selection.
            if !engine.selectedTileIDs.contains(tileID) { applySelection(.selectOnly(tileID)) }
            let carry = canvasDragCarry(grabbed: tileID, selection: engine.selectedTileIDs)
            // SP7: an ⌥-drag on a tile is a drag-OUT (board→board / →collection via
            // the sidebar), not an in-view move — start an NSDraggingSession with the
            // app's asset payload. If the carried tiles yield no payload (e.g. only
            // element tiles), fall through to the normal in-view move.
            if pressOptionDown, let item = onBeginTileDragOut?(carry.union([tileID])) {
                beginTileDragOut(pasteboardItem: item, primaryTileID: tileID, event: event)
                return
            }
            engine.beginDrag(tileID: tileID, alsoCarry: carry)
        }
        // ⌘ turns snapping off mid-drag, exactly as it does for a resize.
        engine.updateDrag(
            byScreenDelta: delta, snapping: !event.modifierFlags.contains(.command))
    }

    /// Finalize a drag: hand the final origin to the host (which updates the
    /// provider in memory + persists), THEN sync — so the tile stays put with no
    /// flicker and the viewport is untouched. A press with no drag is a plain
    /// click (already handled on down), so it's a no-op here.
    public override func mouseUp(with event: NSEvent) {
        // Finish a rubber-band create, if one is in progress.
        if tool != .select, let start = createStartPoint {
            let end = convert(event.locationInWindow, from: nil)
            finishCreate(from: start, to: end)
            createStartPoint = nil
            return
        }

        // Finish a resize: hand the FINAL world frame to the host (which updates the
        // provider + persists), then clear the live state and sync — the same
        // ordering the move path uses, so the tile never snaps back mid-write.
        if isResizing {
            if let resized = engine.currentResizeFrame() {
                onResizeTile?(resized.tileID, resized.worldFrame)
            }
            engine.endResize()
            engine.sync()
            resetGestureState()
            return
        }

        // A marquee applies its hits live on every tick, so mouse-UP only tears the
        // gesture down. A below-threshold press (never a marquee) falls through to
        // the plain-click handling below — its deferred click-to-clear.
        if isMarqueeing {
            endMarquee()
            resetGestureState()
            return
        }

        defer { resetGestureState() }
        guard isDragging else {
            // A press with no drag is a plain click: apply the deferred selection
            // action (collapse-a-selected-tile-to-one, or empty-space clear). This
            // covers the below-threshold marquee press → click-to-clear too.
            if let action = pendingClickAction { applySelection(action) }
            return
        }
        // Persist EVERY tile the drag carried (a frame + its group, or a multi-
        // selection), then clear the drag state. `currentDragOrigins()` is
        // non-mutating; `endDrag()` clears. The provider updates in memory per
        // callback so nothing snaps.
        for moved in engine.currentDragOrigins() {
            onMoveTile?(moved.tileID, moved.worldOrigin)
        }
        _ = engine.endDrag()
        engine.sync()
    }

    // MARK: Element create (rubber-band → world rect)

    /// Draw / update the dashed preview rect while rubber-banding a new element.
    private func updateCreatePreview(from a: CGPoint, to b: CGPoint) {
        let rect = Self.normalizedRect(from: a, to: b)
        let preview = createPreviewLayer ?? makeCreatePreviewLayer()
        createPreviewLayer = preview
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = rect
        preview.isHidden = false
        preview.zPosition = .greatestFiniteMagnitude
        CATransaction.commit()
    }

    /// Finalize a create gesture: convert the screen rubber-band to a WORLD rect
    /// and report it. A frame needs a real drag (below a minimum is cancelled); a
    /// text box tolerates a click — it falls back to a default-sized box at the
    /// press point so tapping the text tool just drops a text element.
    private func finishCreate(from a: CGPoint, to b: CGPoint) {
        createPreviewLayer?.removeFromSuperlayer()
        createPreviewLayer = nil

        let screenRect = Self.normalizedRect(from: a, to: b)
        var worldRect = engine.transform.screenToWorld(screenRect)

        switch tool {
        case .text:
            if worldRect.width < Self.minCreateWorldEdge || worldRect.height < Self.minCreateWorldEdge {
                let origin = engine.transform.screenToWorld(a)
                worldRect = CGRect(
                    origin: origin,
                    size: CGSize(width: Self.defaultTextWorldWidth, height: Self.defaultTextWorldHeight))
            }
        case .frame:
            guard worldRect.width >= Self.minCreateWorldEdge,
                  worldRect.height >= Self.minCreateWorldEdge else { return }
        case .select:
            return
        }
        onCreateElement?(tool, worldRect)
    }

    private func makeCreatePreviewLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1.5
        layer.borderColor = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
        layer.backgroundColor = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.08)
        layer.cornerRadius = 2
        engine.rootLayer.addSublayer(layer)
        return layer
    }

    /// Normalize two corner points into a positive-size rect (order-independent).
    /// Pure + static so the rubber-band math is unit-testable without a window.
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Smallest world edge a rubber-band must reach to count as a deliberate drag.
    static let minCreateWorldEdge: CGFloat = 12
    /// Default world size for a click-placed (undragged) text box.
    static let defaultTextWorldWidth: CGFloat = 260
    static let defaultTextWorldHeight: CGFloat = 72

    // MARK: Marquee (rubber-band selection → live hit set)

    /// Recompute the marquee's WORLD rect from the pinned anchor + current pointer
    /// under the CURRENT transform, apply the hit set through the reducer (unioned
    /// with the ⇧-additive base), and redraw the screen-space overlay. Called on
    /// every drag tick AND every auto-pan vsync — the transform can change between
    /// them, so the world rect (and thus the hits and the overlay) is always derived
    /// fresh, never cached in screen space.
    private func updateMarquee() {
        guard let anchorWorld = marqueeAnchorWorld, let screen = marqueeCurrentScreen else { return }
        let currentWorld = engine.transform.screenToWorld(screen)
        let worldRect = Self.normalizedRect(from: anchorWorld, to: currentWorld)
        applySelection(.marquee(hits: engine.tiles(inWorldRect: worldRect), base: marqueeBase))
        drawMarquee(worldRect: worldRect)
    }

    /// Draw / move the translucent rubber-band overlay. The world rect is mapped to
    /// screen for display, so as auto-pan shifts the transform the box appears pinned
    /// to the world while its on-screen frame tracks along. Actions are disabled so a
    /// per-tick frame change never implicitly animates.
    private func drawMarquee(worldRect: CGRect) {
        let layer = marqueeLayer ?? makeMarqueeLayer()
        marqueeLayer = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = engine.transform.worldToScreen(worldRect)
        layer.isHidden = false
        layer.zPosition = .greatestFiniteMagnitude
        CATransaction.commit()
    }

    private func makeMarqueeLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1
        layer.borderColor = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.7)
        layer.backgroundColor = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.12)
        engine.rootLayer.addSublayer(layer)
        return layer
    }

    /// Tear down the marquee overlay + auto-pan link at the end (or cancel) of a
    /// marquee. The selection was committed live on each tick, so nothing to persist.
    private func endMarquee() {
        stopAutoPan()
        marqueeLayer?.removeFromSuperlayer()
        marqueeLayer = nil
    }

    // MARK: Edge auto-pan (world-anchored marquee grows under a moving transform)

    /// Start or stop the auto-pan link based on whether the pointer currently sits
    /// in an edge zone. Cheap to call every drag tick (idempotent start/stop).
    private func updateAutoPan() {
        guard let screen = marqueeCurrentScreen,
              Self.marqueeAutoPanVelocity(pointer: screen, in: bounds.size) != .zero
        else { stopAutoPan(); return }
        startAutoPan()
    }

    private func startAutoPan() {
        guard autoPanLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(autoPanStep(_:)))
        link.add(to: .main, forMode: .common)
        autoPanLink = link
    }

    private func stopAutoPan() {
        autoPanLink?.invalidate()
        autoPanLink = nil
    }

    /// The link fires on the main runloop; hop back into isolation to step the pan.
    @objc nonisolated private func autoPanStep(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        MainActor.assumeIsolated { self.performAutoPan(dt: dt) }
    }

    /// One auto-pan step: pan the transform by the ramped velocity × the frame's
    /// real duration, then recompute the marquee against the NEW transform (the
    /// pointer hasn't moved in screen space, but the world under it has). Stops when
    /// the marquee ends or the pointer leaves every edge zone.
    private func performAutoPan(dt: CFTimeInterval) {
        guard isMarqueeing, let screen = marqueeCurrentScreen else { stopAutoPan(); return }
        let velocity = Self.marqueeAutoPanVelocity(pointer: screen, in: bounds.size)
        guard velocity != .zero else { stopAutoPan(); return }
        engine.pan(byScreenDelta: CGSize(
            width: velocity.width * CGFloat(dt), height: velocity.height * CGFloat(dt)))
        updateMarquee()
    }

    /// Right-click: select the tile under the cursor and offer Remove / Delete.
    /// Returns `nil` (no menu) over empty space.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let tile = engine.tile(atScreenPoint: point) else { return nil }
        // Finder rule: right-clicking a tile OUTSIDE the selection selects only it;
        // right-clicking one INSIDE the selection acts on the whole selection.
        if !engine.selectedTileIDs.contains(tile.id) { applySelection(.selectOnly(tile.id)) }

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
        // 51 = Delete (Backspace), 117 = Forward Delete. Both mean "delete", and
        // both act on the WHOLE selection (049 · D7).
        if event.keyCode == 51 || event.keyCode == 117 {
            let ids = engine.selectedTileIDs
            if !ids.isEmpty { onDeleteTiles?(ids); return }
        }
        super.keyDown(with: event)
    }

    /// Edit ▸ Copy (⌘C, 052 · B1) — the standard responder action, so the system's
    /// Copy menu item copies the canvas selection when the canvas holds focus.
    /// `copy(_:)` is not declared by NSView, so it is a fresh `@objc` action.
    @objc public func copy(_ sender: Any?) {
        let ids = engine.selectedTileIDs
        if !ids.isEmpty { onCopyTiles?(ids) }
    }

    /// Edit ▸ Paste (⌘V, 059 · SP4) — the standard responder action, so the system's
    /// Paste menu item pastes onto the canvas when it holds focus. Hands the app the
    /// general pasteboard + the world point at the viewport centre (via the shared
    /// transform, so it never drifts from hit-testing). `paste(_:)` is not declared
    /// by NSView, so it is a fresh `@objc` action.
    @objc public func paste(_ sender: Any?) {
        guard let onPaste else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        _ = onPaste(NSPasteboard.general, engine.transform.screenToWorld(centre))
    }

    /// Apply a selection reducer action to the engine's current selection, redraw
    /// the highlights, and notify the host of the new set.
    private func applySelection(_ action: CanvasSelectionAction) {
        let next = CanvasSelection(ids: engine.selectedTileIDs).applying(action).ids
        engine.setSelected(next)
        onSelectTiles?(next)
    }

    @objc private func contextRemove() {
        let ids = engine.selectedTileIDs
        if !ids.isEmpty { onRemoveTiles?(ids) }
    }

    @objc private func contextDelete() {
        let ids = engine.selectedTileIDs
        if !ids.isEmpty { onDeleteTiles?(ids) }
    }

    // MARK: - NSDraggingDestination (drop target, 059 · SP2 / 4A)

    /// The operation to advertise as a drag enters / moves over the canvas. Defers
    /// to ``onDragEntered`` (the app reads the pasteboard); with no handler it
    /// accepts as `.copy` whenever the canvas has accepted types, else refuses.
    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Refuse our OWN in-flight drag-out dropped back on this board (SP7): a
        // board→board copy onto the source would duplicate the tile in place.
        guard !isActiveDragSource, onDrop != nil, !acceptedDropTypes.isEmpty else { return [] }
        if let onDragEntered { return onDragEntered(sender.draggingPasteboard) }
        return .copy
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperation(for: sender) != []
    }

    /// Commit a drop: map the drop location to a WORLD point through the shared
    /// transform (isFlipped view coords → world), then hand the pasteboard + point
    /// to the app. The app decodes the payload and places / imports; the package
    /// stays ignorant of what's on the pasteboard.
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isActiveDragSource, let onDrop else { return false } // no self-drop (SP7)
        let viewPoint = convert(sender.draggingLocation, from: nil)
        let worldPoint = engine.transform.screenToWorld(viewPoint)
        return onDrop(sender.draggingPasteboard, worldPoint)
    }

    // MARK: - Drag-out source (board→board / →collection, 059 · SP7)

    /// Begin an `NSDraggingSession` for an ⌥-drag: the app's asset payload rides the
    /// session so a sidebar space / collection row accepts it (adds a copy). The
    /// primary tile's on-screen frame + a snapshot become the drag image, so it
    /// reads as the tile lifting off. The in-view move never started, so the source
    /// tile stays exactly put.
    private func beginTileDragOut(
        pasteboardItem: NSPasteboardItem, primaryTileID: Int, event: NSEvent
    ) {
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let frame = engine.currentScreenFrame(forTileID: primaryTileID)
            ?? CGRect(x: event.locationInWindow.x, y: event.locationInWindow.y, width: 120, height: 120)
        dragItem.setDraggingFrame(frame, contents: tileDragImage(in: frame))
        isActiveDragSource = true
        resetGestureState() // the in-view drag never began; drop the press state
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// A snapshot of the view region a tile occupies, for the drag image. `nil` (an
    /// invisible drag) is an acceptable fallback if caching fails.
    private func tileDragImage(in frame: CGRect) -> NSImage? {
        guard frame.width > 0, frame.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        return image
    }
}

extension CanvasHostView: NSDraggingSource {
    /// A board drag-out is always a COPY within the app (the board is additive — the
    /// source tile is never removed). It carries no file promise, so a drop OUTSIDE
    /// the app is refused (nothing to hand Finder).
    public func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    /// Session teardown: clear the source flag so the board accepts external drops
    /// again, and re-sync in case the gesture left transient state.
    public func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        isActiveDragSource = false
    }
}

extension CanvasHostView: NSUserInterfaceValidations {
    /// Enable Edit ▸ Copy only when the canvas has a tile selection (052 · B1).
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !engine.selectedTileIDs.isEmpty }
        // Enable Paste whenever a handler is wired; the handler no-ops if the
        // pasteboard holds nothing importable (059 · SP4). Content-type gating stays
        // app-side — the package never learns what "importable" means.
        if item.action == #selector(paste(_:)) { return onPaste != nil }
        return true
    }
}
