import AppKit

/// What a Delete key press asked for on a board (022 · D3).
///
/// The board's copy of the app's `DeleteIntent` — see
/// ``CanvasHostView/deleteIntent(characters:modifiers:)`` for why there are two of
/// them and what keeps them honest.
public enum CanvasDeleteIntent: Equatable, Sendable {
    /// ⌫ — drop the selected tiles' PLACEMENTS. The board is what you are looking at.
    case remove
    /// ⌘⌫ — delete the selected tiles' assets from the library.
    case destroy
}

/// Thin `NSView` host (decision C5: the side-effecting boundary). It owns events
/// and the layer tree, and delegates all rendering decisions to ``CanvasEngine``.
/// Scroll pans, pinch zooms, layout/resize re-syncs.
@MainActor
public final class CanvasHostView: NSView {
    private let engine: CanvasEngine

    /// The layer-hosting subview the engine draws into. See ``init`` for why the tile
    /// tree cannot live on the host itself.
    private let surface: CanvasSurfaceView

    /// The engine's layer tree, for the package's own tests: the host is a plain
    /// container, so its own `layer` is not where tiles are.
    var contentLayer: CALayer { engine.rootLayer }

    /// The handle a press at `point` would arm, for the package's own tests — the
    /// gesture itself needs a real `NSEvent`, which a headless test has no way to make.
    func resizeHandleForTesting(at point: CGPoint) -> ResizeHandle? {
        engine.resizeHandle(atScreenPoint: point)?.handle
    }

    /// Whether this host may still frame the board to fit. The app arms it for the
    /// FIRST open of a board and disarms it once ``onDidFrameContent`` reports the
    /// framing happened, so no later reload — or rebuild — can move the camera.
    ///
    /// It used to be a private per-instance `hasFramedContent`, which quietly meant
    /// "once per HOST" rather than "once per board", so any host rebuild reframed and
    /// threw the user's pan/zoom away. It also fired too early: a board loads its rows
    /// asynchronously, so the first `layout()` runs with NO tiles, and framing an empty
    /// world is a no-op that nonetheless consumed the one shot.
    public var framesContentWhenReady: Bool = true

    /// Fired the one time framing actually happened (never for a no-op attempt), so the
    /// app can record that this board has been framed.
    public var onDidFrameContent: (() -> Void)?

    /// The saved camera to open the board at INSTEAD of fitting it (018 · Cluster C),
    /// or `nil` to fit. Consumed by the same one shot ``framesContentWhenReady`` arms —
    /// restoring and fitting are two answers to one question ("where does this board
    /// open?"), so they share the arming, the content-is-ready wait, and the
    /// ``onDidFrameContent`` report rather than racing each other.
    ///
    /// A camera that would land the viewport on empty world space is refused here and
    /// falls back to the fit; see ``CanvasEngine/restoreCamera(_:padding:)``.
    public var restoreCamera: CanvasCamera?

    private var didFrameContent = false

    /// Establish the board's opening camera, if this host is still allowed to and
    /// there is now something to look at: the saved ``restoreCamera`` when it shows
    /// content, else a fit. Returns whether it did.
    @discardableResult
    private func frameContentIfNeeded() -> Bool {
        guard framesContentWhenReady, !didFrameContent,
              bounds.width > 0, bounds.height > 0,
              engine.hasDrawableContent else { return false }
        didFrameContent = true
        engine.restoreCamera(restoreCamera)
        onDidFrameContent?()
        return true
    }

    /// Called with a tile's id when the user double-clicks it (e.g. to open a
    /// video). Set by the host; `nil` disables activation.
    public var onActivateTile: ((Int) -> Void)?

    /// Called when the selection changes via a click / marquee: the full set of
    /// selected tile ids (empty when the selection is cleared). `nil` disables.
    public var onSelectTiles: ((Set<Int>) -> Void)?

    /// The user pressed a tool key (`v` / `f` / `t`). The app owns the tool, so it
    /// decides what to do; the canvas only reports the press.
    ///
    /// This lives on the canvas rather than as a shortcut elsewhere in the window for
    /// one reason: a key equivalent is dispatched BEFORE `keyDown` reaches the first
    /// responder, and it has no idea whether that responder is a text editor. An
    /// unmodified letter registered as a shortcut therefore fires — and swallows the
    /// keystroke — while the user is typing into a text box. Handling it here makes
    /// the canvas's focus the gate: an open editor holds first responder, so these
    /// never reach us at all.
    public var onSelectTool: ((CanvasTool) -> Void)?

    /// **`A`** — file the selected tiles somewhere, PLACEMENTS UNTOUCHED (024 · K3).
    /// The host only reports the press and which tiles it carried; what "file" means
    /// is the app's word (a collection), which this package deliberately does not know.
    ///
    /// It rides the same gate ``onSelectTool`` does — a bare letter read inside
    /// `keyDown`, so an open text editor holding first responder never lets it fire.
    /// See ``boardShortcut(characters:modifiers:)`` for why it is decoded beside the
    /// tool keys rather than as one of them.
    public var onFileTiles: ((Set<Int>) -> Void)?

    /// **⌫** — drop the tiles' PLACEMENTS from this board (022 · D3). The context
    /// menu's "Remove from Board" and the bare Delete key. The underlying assets are
    /// never touched: a board owns placements, not memberships.
    public var onRemoveTiles: ((Set<Int>) -> Void)?

    /// **⌘⌫** — delete the tiles' assets from the LIBRARY (022 · D3). The context
    /// menu's "Delete from Library…" and the ⌘-modified Delete key.
    ///
    /// This used to be an alias: the app handed the same closure to both, so a board
    /// had no way to delete an asset at all and the menu offered two labels for one
    /// behaviour. The host still only reports the press — the app owns the
    /// confirmation, and its copy has to say "the library", not "this board".
    public var onDeleteTiles: ((Set<Int>) -> Void)?

    /// **Archive** — put the tiles' assets on the archive shelf (023 · A3). The
    /// context menu's Archive item; the tile then vanishes from the board and
    /// returns, in place, when the asset is unarchived. `nil` omits the item
    /// rather than drawing a dead one, so a host that has no shelf is unchanged.
    ///
    /// The renderer deliberately does NOT decide the verb's direction or its
    /// title: a board can only ever show unarchived assets, and what "archive"
    /// means for a mixed set is an app-level rule (`shelfVerb`) that has no
    /// business being duplicated in a rendering package.
    public var onArchiveTiles: ((Set<Int>) -> Void)?

    /// Called with the selected tile ids for Edit ▸ Copy (⌘C, 052 · B1). The host
    /// maps them to assets and writes the pasteboard; `nil` disables Copy.
    public var onCopyTiles: ((Set<Int>) -> Void)?

    /// Called when a tile is dragged to a new position: its id and the FINAL
    /// world-space origin. The host updates the provider in memory (so the tile
    /// stays put) and persists off-main. During a frame group-drag it fires once
    /// per carried tile. `nil` disables drag-to-place.
    public var onMoveTile: ((Int, CGPoint) -> Void)?

    /// Called when an ⌥-drag finishes: the carried tile ids and how far the drag moved
    /// them, in WORLD units. The app is expected to create copies at that offset and
    /// leave the originals alone.
    ///
    /// An offset rather than per-tile origins because the copies do not exist yet —
    /// there is no tile id to report an origin against, only a displacement from
    /// whatever each source's own position is.
    ///
    /// **⌥ duplicates every kind of tile** (065b). It used to duplicate only the tiles
    /// that yielded no drag-out payload, because it shared the modifier with drag-out —
    /// which meant assets could not be duplicated by drag at all, and that ⌥ meant two
    /// different things depending on what you grabbed. Drag-out moved to ⌘.
    /// `nil` disables ⌥-duplicate, leaving ⌥ a plain move.
    public var onDuplicateTiles: ((Set<Int>, CGSize) -> Void)?

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
    ///
    /// Arming a tool moves no mouse — it comes from the picker or a bare key — so the
    /// pointer would otherwise keep whatever answer the last `mouseMoved` gave it
    /// until the user jiggled it. Refreshing on the set is what makes the crosshair
    /// appear the instant the tool does.
    public var tool: CanvasTool = .select {
        didSet {
            guard tool != oldValue else { return }
            refreshHoverCursor()
        }
    }

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

    /// ⌘ at mouse-DOWN → drag-out (065b). Latched for the same reason as
    /// ``pressOptionDown``: what a drop means is settled when the drag starts.
    ///
    /// Read ONLY at drag-start, which is what lets ⌘ keep its other job on this path
    /// without ambiguity — pressed once a move is already running it turns snapping
    /// off. Held from the start it is a drag-out, which returns before the snapping
    /// line is ever reached.
    private var pressCommandDown = false

    /// Whether the running drag duplicates rather than moves (065) — latched at
    /// drag-start from `pressOptionDown`, so releasing ⌥ mid-drag cannot change what
    /// the drop means.
    private var isDuplicatingDrag = false

    /// Forwarded from the engine (2B · 054 §5.1 · R2): fired once per transform
    /// mutation so the app's inline text editor can reposition its overlay
    /// imperatively, off the SwiftUI diff. `nil` disables it. Wired to the engine in
    /// ``init`` so any transform source (pan/zoom/setTransform/frameToContent)
    /// notifies through this one seam.
    public var onTransformChanged: (() -> Void)?

    /// The camera moved (018 · Cluster C): a pan, a zoom, or the opening
    /// restore/fit. Rides the SAME engine notification as ``onTransformChanged``,
    /// but carries the VALUE — so the app persists what it was handed rather than
    /// reaching back into a (weakly held, possibly detached) host to read it.
    ///
    /// Its own callback rather than a second job for `onTransformChanged`, which is
    /// the inline editor's imperative reposition hook and deliberately carries
    /// nothing. `nil` disables camera reporting.
    public var onCameraChanged: ((CanvasCamera) -> Void)?

    /// Forwarded from the engine (062): fired when a live resize moves a tile's
    /// displayed frame with the camera standing still. The editor's overlay is
    /// positioned from that frame, so it has to hear about both kinds of movement —
    /// see ``CanvasEngine/onLiveFrameChanged``.
    public var onLiveFrameChanged: (() -> Void)?

    // MARK: Inline text editing (054 §5)

    /// The tile whose text this host is currently editing, or `nil`.
    ///
    /// Read-only: the host owns the editor now, so nobody else can claim an edit is in
    /// progress that isn't. Ask for one with ``editRequest`` or ``beginEditingText``.
    public private(set) var editingTileID: Int?

    /// The live editor, while an edit is open.
    private var editor: CanvasTextEditController?

    /// Editing began (the tile id) or ended (`nil`). The app mirrors this into its own
    /// state — the floating format bubble anchors on "the box being edited".
    public var onEditingChanged: ((Int?) -> Void)?

    /// An edit finished. Fired exactly once per edit, before ``onEditingChanged``
    /// reports `nil`, so the app can write the result while the tile is still known.
    public var onFinishEditingText: ((Int, CanvasTextEditOutcome) -> Void)?

    /// Ask the host to begin editing a tile, as a value.
    ///
    /// A method call would be simpler, but the app drives this from SwiftUI, where the
    /// same state is pushed on every view update: creating a text box has to wait for
    /// the row to be written before it knows the tile id, so the request is set once and
    /// re-delivered until it is consumed. The token makes that idempotent — and lets the
    /// same tile be edited twice in a row, which an id alone could not express.
    ///
    /// `nil` is a NO-OP, never "stop editing": the app clears its state after the
    /// request is taken, and that must not tear down the edit it just started. Use
    /// ``endEditingText(commit:)`` to end one.
    public var editRequest: CanvasTextEditRequest? {
        didSet { applyEditRequestIfNeeded() }
    }

    private var appliedEditToken: Int?

    private func applyEditRequestIfNeeded() {
        guard let request = editRequest, request.token != appliedEditToken else { return }
        // Wait for a viewport: `beginEditingText` measures the tile's screen frame, and
        // before the first layout there is nothing to measure against. The request is
        // held, not dropped — `layout()` retries.
        guard bounds.width > 0, bounds.height > 0,
              engine.textStyle(forTileID: request.tileID) != nil else { return }
        appliedEditToken = request.token
        beginEditingText(tileID: request.tileID, isNewlyCreated: request.isNewlyCreated)
    }

    /// Begin editing `tileID`'s text. A no-op for a tile that draws no text. An edit
    /// already open on another tile is committed first.
    public func beginEditingText(tileID: Int, isNewlyCreated: Bool) {
        guard let style = engine.textStyle(forTileID: tileID) else { return }
        if let editor {
            guard editor.tileID != tileID else { return } // already editing this one
            editor.finish(commit: true)
        }
        let controller = CanvasTextEditController(
            tileID: tileID, isNewlyCreated: isNewlyCreated, style: style,
            engine: engine, host: self,
            onFinish: { [weak self] outcome in self?.editorDidFinish(tileID: tileID, outcome) })
        editor = controller
        editingTileID = tileID
        onEditingChanged?(tileID)
    }

    /// End the open edit, if any. `commit: false` abandons it (Esc).
    public func endEditingText(commit: Bool) {
        editor?.finish(commit: commit)
    }

    /// Whether the host is being torn out of its window / the app is quitting. Set only
    /// around the two teardown commits below.
    private var isTearingDown = false

    private func editorDidFinish(tileID: Int, _ outcome: CanvasTextEditOutcome) {
        editor = nil
        editingTileID = nil

        // Normally SYNCHRONOUS, and that matters: the caller un-blanks this tile and
        // restores its stored height the instant this returns, re-reading the provider.
        // An app that defers its write therefore has its box redrawn with the old text
        // at the old height for a turn — a visible flicker on every commit.
        //
        // The exception is teardown. There the app would be publishing into a SwiftUI
        // pass that is removing this very view, and the redraw it would race is one
        // nobody sees, so the outcome goes off the current turn instead.
        guard isTearingDown else {
            onFinishEditingText?(tileID, outcome)
            onEditingChanged?(nil)
            return
        }
        let reportFinish = onFinishEditingText
        let reportChange = onEditingChanged
        Task { @MainActor in
            reportFinish?(tileID, outcome)
            reportChange?(nil)
        }
    }

    /// Commit an open edit as part of tearing this host down, delivering the outcome off
    /// the current turn. See ``editorDidFinish(tileID:_:)``.
    private func endEditingForTeardown() {
        guard editingTileID != nil else { return }
        isTearingDown = true
        endEditingText(commit: true)
        isTearingDown = false
    }

    /// The current world↔screen transform (2B · 054 §5.1) — read by the inline
    /// editor to scale its measured overlay size to screen points.
    public var transform: CanvasTransform { engine.transform }

    /// The window-independent camera the board is currently looking through
    /// (018 · Cluster C) — what the app persists.
    public var camera: CanvasCamera { engine.camera }

    /// Look through `camera` now, rather than at the next board open.
    ///
    /// The peer of the ``restoreCamera`` property, which is consumed once by the
    /// opening framing and ignored afterwards. This is for a caller that needs to move
    /// the camera mid-session — the measurement harness returning to a known start
    /// between sweeps, and any future "go here" affordance. Falls back to a fit for a
    /// camera that would show nothing, exactly as the opening restore does.
    public func setCamera(_ camera: CanvasCamera) {
        engine.restoreCamera(camera)
    }

    /// The on-screen frame a tile is drawn at (2B · 054 §5.1) — `nil` only when the id
    /// resolves to no tile. The inline editor positions its `NSTextView` from this on
    /// each ``onTransformChanged``.
    ///
    /// Not visibility-gated: "where is this tile" and "can the user see it" are
    /// separate questions, and conflating them made the editor commit itself on its
    /// first layout, when the viewport size wasn't known yet. Ask ``isTileVisible(_:)``
    /// for the commit-and-exit rule (054 §5.4).
    public func screenFrame(forTileID id: Int) -> CGRect? {
        engine.screenFrame(forTileID: id)
    }

    /// Whether a tile is currently within the culled-visible set.
    public func isTileVisible(_ id: Int) -> Bool { engine.isVisible(tileID: id) }

    /// The canvas's viewport in points — `.zero` until the first ``layout()``. The
    /// inline editor reads it to tell "not laid out yet" from "scrolled away".
    public var viewportSize: CGSize { engine.viewportSize }

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
    /// What the pointer is currently showing, so a hover only touches `NSCursor` when
    /// the answer actually changes. A VALUE rather than the cursor itself because
    /// `NSCursor.frameResize` vends a fresh instance per call, which would make an
    /// identity comparison always differ.
    private var hoverCursor: HoverCursor = .arrow
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

    /// The display link that commits an in-flight pinch, at most once per vsync
    /// (086 · Phase 1). Its own link rather than a shared one: the two gestures are
    /// mutually exclusive in practice but not by construction, and a link that two
    /// callers can start and stop is a link that one of them leaves running.
    private var zoomLink: CADisplayLink?

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
            // A board's rows arrive asynchronously, so content can turn up long after
            // the last `layout()` — with no bounds change to notice it. Without this,
            // a board whose first layout ran empty would never be framed at all.
            if !frameContentIfNeeded() { engine.sync() }
            // A restyle mid-edit (the format bubble) arrives as a re-sync, so this is
            // where the live glyphs learn about it. The string is deliberately NOT
            // taken from the model — it belongs to the text view until the edit ends.
            editor?.applyStyleIfChanged()
            applyEditRequestIfNeeded()
        }
    }

    public init(
        provider: TileProvider,
        images: any TileImageSource,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 800)
    ) {
        self.engine = CanvasEngine(provider: provider, images: images, viewportSize: frame.size)
        self.surface = CanvasSurfaceView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        // The engine's layer tree lives on a dedicated LAYER-HOSTING subview, not on
        // this view. A layer-hosting view owns its layer's sublayers outright, so any
        // subview added here would have its layer spliced in among the pooled tile
        // layers — where it would compete by `zPosition` and break the one-layer-per-
        // visible-tile invariant. Keeping the host a plain container is what lets it
        // hold real subviews (the inline text editor) above the canvas.
        surface.layer = engine.rootLayer
        surface.wantsLayer = true
        wantsLayer = true
        addSubview(surface)
        engine.rootLayer.frame = surface.bounds
        // Forward the engine-sourced transform notification outward (2B · 054 §5.1):
        // any transform mutation (pan/zoom/setTransform/frameToContent) reaches the
        // app through this one seam.
        // The editor repositions FIRST, then the app hears about it. Its height push
        // changes the tile's displayed frame, so an app listener (the format bubble
        // anchors on that frame) reading before the editor would trail by a frame.
        engine.onTransformChanged = { [weak self] in
            guard let self else { return }
            self.editor?.reposition()
            self.onTransformChanged?()
            // Camera persistence (018 · Cluster C) rides the same seam, so the ONE
            // place a transform can change is also the one place a camera write can
            // be missed from.
            self.onCameraChanged?(self.engine.camera)
        }
        // …and its peer for a live resize (062), which moves the box under a still
        // camera and so never reaches the notification above.
        engine.onLiveFrameChanged = { [weak self] in
            self?.editor?.reposition()
            self?.onLiveFrameChanged?()
        }
        engine.sync()
        // Commit rather than lose the edit if this view is torn out from under it —
        // a board switch, a window close, or the app quitting.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationWillTerminate(_ note: Notification) {
        endEditingForTeardown()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left origin so world-y grows downward, the usual canvas feel.
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        engine.rootLayer.frame = surface.bounds
        engine.viewportSize = bounds.size
        // Frame the board to fit the first time we know our size AND have content;
        // afterwards a resize just re-syncs (it must not stomp the user's pan/zoom).
        if !frameContentIfNeeded() { engine.sync() }
        // A request that arrived before the first layout had no viewport to measure
        // against; now there is one.
        applyEditRequestIfNeeded()
        editor?.reposition()
    }

    /// If the host leaves its window mid-gesture (e.g. a content reload rebuilds it
    /// via `.id`), invalidate the auto-pan link so it can't retain a detached view.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A gesture left open would keep the LOD tiers frozen and the camera
        // notification suppressed for good — `.cancelled` is not reliably delivered,
        // and a view yanked out of its window will never see one at all.
        if window == nil { endMarquee(); endZoomGesture() }
        // An edit that began before this view had a window can take focus now.
        editor?.hostDidMoveToWindow()
    }

    /// Leaving the window ends any open edit by COMMITTING it. Losing typed text
    /// because a board was switched or a window closed is never what the user meant.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endEditingForTeardown() }
    }

    // MARK: Hover cursor (resize handles — 062 · create crosshair)

    /// A handle is a small target, so the pointer has to say when it's over one —
    /// without the cursor change the 22pt grab zone is invisible and undiscoverable.
    /// An armed create tool is invisible for the same reason, and answered the same
    /// way (a crosshair over the whole canvas).
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

    /// Arriving over the canvas answers immediately rather than on the first move —
    /// a create tool armed while the pointer was away from the view would otherwise
    /// show the arrow until it happened to move.
    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHoverCursor()
    }

    /// What the pointer says about the press it would make here.
    ///
    /// An enum rather than an `NSCursor` because two of the four answers are not a
    /// cursor this view sets: `.editor` means *someone else owns it*, and every
    /// `.resize` answer is a fresh `NSCursor` instance (see ``hoverCursor``).
    private enum HoverCursor: Equatable {
        case arrow
        /// A create tool is armed: the press draws a new element.
        case crosshair
        case resize(ResizeHandle)
        /// Inside the open inline editor, where the text view vends its own I-beam.
        case editor
    }

    /// Point the cursor at whatever is under `point`. Suppressed mid-gesture: during a
    /// drag or a resize the cursor belongs to that gesture.
    private func updateHoverCursor(at point: CGPoint) {
        guard !isResizing, !isDragging, !isMarqueeing else { return }
        apply(hoverCursor(at: point))
    }

    /// The pointer's answer for `point`, in precedence order. Split from ``apply(_:)``
    /// so the decision is a pure read of the canvas's state.
    private func hoverCursor(at point: CGPoint) -> HoverCursor {
        // An armed create tool owns the WHOLE viewport, not just its empty parts:
        // `canvasPressTarget` hands a create tool every press, over a tile or not, so
        // the crosshair has to be everywhere the press means "draw here" — which is
        // everywhere. This is Figma's affordance, and the reason the tool was
        // previously undiscoverable: the arrow said "click to select" while the canvas
        // meant "drag out a box".
        guard tool == .select else { return .crosshair }
        // Inside the box being edited the cursor belongs to the text view. Answering
        // `.editor` rather than `.arrow` is what stops us stomping its I-beam.
        if let editor, editor.contains(hostPoint: point) { return .editor }
        guard onResizeTile != nil else { return .arrow }
        return engine.resizeHandle(atScreenPoint: point).map { .resize($0.handle) } ?? .arrow
    }

    private func apply(_ next: HoverCursor) {
        guard next != hoverCursor else { return }
        hoverCursor = next
        switch next {
        case .arrow: NSCursor.arrow.set()
        case .crosshair: NSCursor.crosshair.set()
        case .resize(let handle): Self.cursor(for: handle).set()
        case .editor: break // the text view has already set its own
        }
    }

    /// Re-ask for the pointer's current position, for a cause that isn't a mouse move
    /// (the tool changing under a stationary pointer). A no-op when the pointer is not
    /// over this view — `mouseEntered` will ask again when it arrives.
    private func refreshHoverCursor() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        updateHoverCursor(at: point)
    }

    private func clearHoverCursor() {
        guard hoverCursor != .arrow else { return }
        hoverCursor = .arrow
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

    /// Escape, ⌘↵ and ⌘Z while an edit is open, handled here rather than in `keyDown`
    /// because the text view holds first responder while editing — `keyDown` never
    /// reaches us.
    ///
    /// ⌘Z needs BOTH halves of a bargain, and neither works alone:
    ///
    /// - This method loses to a sibling SwiftUI `keyboardShortcut` (measured: with the
    ///   app's undo button mounted, it claims ⌘Z and the canvas is never asked). So the
    ///   app must withdraw its binding while an edit is open.
    /// - But withdrawing it is not enough on its own. Nothing else claims ⌘Z, so it
    ///   falls through to `keyDown` on the `NSTextView` — which does nothing with it,
    ///   because typing undo is normally driven by an Edit ▸ Undo menu item this app
    ///   has no equivalent of. Undo has to be *performed*, here.
    ///
    /// Together: the app stands down, and this drives the text view's own undo manager,
    /// so ⌘Z mid-sentence undoes one keystroke instead of the last board operation.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editingTileID != nil else { return super.performKeyEquivalent(with: event) }

        if event.keyCode == 53 { // Escape → end the edit, keeping the text
            // The same answer `CanvasEditorTextView.onEscape` gives — this path only
            // runs for an edit that began before the host had a window, and the two
            // must not disagree about what ⎋ means.
            endEditingText(commit: true)
            return true
        }
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 36, command { // ⌘↵ → commit
            endEditingText(commit: true)
            return true
        }
        if command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            // Claimed either way: an edit is open, so ⌘Z means the text, and letting it
            // fall through to the board's undo mid-sentence is the bug this prevents.
            guard let undoManager = window?.firstResponder?.undoManager else { return true }
            if event.modifierFlags.contains(.shift) { undoManager.redo() } else { undoManager.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A bare wheel pans; ⌘-wheel zooms about the cursor (099 · P12).
    ///
    /// The zoom half goes through the SAME three engine calls the pinch brackets with
    /// (086 · C7), not through `engine.zoom(by:aroundScreenPoint:)`. That is not
    /// tidiness: while a gesture is open the LOD tier is frozen
    /// (``CanvasEngine/isZoomGestureActive``), so a wheel sweep re-lays the layers it
    /// already has and asks for its sharper thumbnails ONCE, at settle. Zooming
    /// directly would request a decode per event and cancel it on the next one —
    /// exactly the cost 086 measured and removed from the pinch.
    ///
    /// The phase switch mirrors ``magnify(with:)`` case for case, including the
    /// implicit `.began`, because a wheel gesture has the same shape and the two
    /// drifting apart is how one of them would quietly stop freezing. The `default`
    /// branch is where they differ, and it has to: a mouse wheel reports no phase at
    /// all, so one notch IS the whole gesture and is bracketed as one.
    public override func scrollWheel(with event: NSEvent) {
        let intent = CanvasZoomGesture.scrollIntent(
            commandHeld: event.modifierFlags.contains(.command),
            scrollDeltaX: event.scrollingDeltaX,
            scrollDeltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas)

        switch intent {
        case .pan(let delta):
            engine.pan(byScreenDelta: delta)
        case .zoom(let factor):
            applyWheelZoom(factor, phase: event.phase,
                           anchor: convert(event.locationInWindow, from: nil))
        }
    }

    /// Route one wheel-zoom factor through the pinch bracket, per the event's phase.
    ///
    /// Split out of ``scrollWheel(with:)`` so the branch a real wheel takes is
    /// reachable without an `NSEvent` — a `swift test` process cannot synthesize one,
    /// which is why 086 put the pinch's own seam on the engine.
    public func applyWheelZoom(_ factor: CGFloat, phase: NSEvent.Phase, anchor: CGPoint) {
        switch phase {
        case .began:
            beginZoomGesture(anchorScreenPoint: anchor)
            updateZoomGesture(by: factor)
        case .changed:
            // The same implicit begin `magnify(with:)` needs, for the same reason: a
            // scroll already in flight when this view is installed delivers `.changed`
            // with no `.began` in front of it.
            if !engine.isZoomGestureActive { beginZoomGesture(anchorScreenPoint: anchor) }
            updateZoomGesture(by: factor)
        case .ended, .cancelled:
            updateZoomGesture(by: factor)
            endZoomGesture()
        default:
            zoomDiscretely(by: factor, aroundScreenPoint: anchor)
        }
    }

    /// One discrete zoom, bracketed but WITHOUT a display link — a mouse-wheel notch,
    /// and the momentum tail of a trackpad scroll after `.ended` has closed the
    /// gesture.
    ///
    /// Bracketed rather than sent to ``zoom(by:aroundScreenPoint:)`` so the notch
    /// still gets the gesture's shape: the tier is frozen across the commit and
    /// re-derived once on the way out, so a notch that crosses an LOD boundary asks
    /// for the new thumbnail exactly once instead of on the commit and again on the
    /// re-tier.
    ///
    /// No link, because there is nothing to coalesce — the events are already one per
    /// notch, and starting and invalidating a `CADisplayLink` per notch would cost
    /// more than the coalescing could ever save.
    public func zoomDiscretely(by factor: CGFloat, aroundScreenPoint anchor: CGPoint) {
        endEditingText(commit: true)
        engine.beginZoomGesture(anchorScreenPoint: anchor)
        engine.updateZoomGesture(by: factor)
        engine.endZoomGesture()
    }

    /// A pinch, bracketed as a gesture (018 · C7 · 086).
    ///
    /// It used to be one line — `engine.zoom(by:aroundScreenPoint:)` per event, with
    /// `NSEvent.phase` never read anywhere in this file, so there was no gesture at
    /// all: only a stream of independent zooms that happened to arrive together. Each
    /// one paid a full relayout, an editor reposition, a SwiftUI publish and a
    /// create-and-cancel camera debounce task.
    ///
    /// Now the phases open and close a gesture on the engine, events accumulate into
    /// it, and a display link commits at most once per vsync — so the cost is bounded
    /// by the display's refresh rate rather than by the trackpad's report rate, which
    /// is the higher of the two.
    public override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        switch event.phase {
        case .began:
            beginZoomGesture(anchorScreenPoint: convert(event.locationInWindow, from: nil))
            updateZoomGesture(by: factor)
        case .changed:
            // An implicit begin: a gesture already in flight when this view is
            // installed delivers `.changed` with no `.began` before it, and dropping
            // those would make the first pinch after a board switch do nothing.
            if !engine.isZoomGestureActive {
                beginZoomGesture(anchorScreenPoint: convert(event.locationInWindow, from: nil))
            }
            updateZoomGesture(by: factor)
        case .ended, .cancelled:
            updateZoomGesture(by: factor)
            endZoomGesture()
        default:
            // No phase at all — a synthetic event, or a device that does not report
            // one. There is no gesture to bracket, so this keeps the original
            // behaviour: apply it directly and notify immediately.
            zoom(by: factor, aroundScreenPoint: convert(event.locationInWindow, from: nil))
        }
    }

    /// Open a pinch: commit any in-progress edit, then bracket the engine and start
    /// the commit link.
    ///
    /// The edit is COMMITTED, not abandoned — the same bargain clicking away strikes,
    /// and for the same reason (losing typed text is the failure that actually
    /// matters). It has to happen here because the editor is an `NSTextView` subview
    /// positioned from the tile's screen frame, and it repositions off
    /// `onTransformChanged`, which the gesture deliberately withholds until settle:
    /// an editor left open would sit still while the board zoomed out from under it.
    /// Public because a pinch cannot otherwise be scripted: there is no way to
    /// synthesize a phased `magnify` `NSEvent`, so the measurement harness (086 ·
    /// Phase 0) would have no way in. Same three calls the trackpad drives.
    public func beginZoomGesture(anchorScreenPoint anchor: CGPoint) {
        endEditingText(commit: true)
        engine.beginZoomGesture(anchorScreenPoint: anchor)
        startZoomLink()
    }

    /// Fold a factor into the running gesture, committing inline when no display
    /// link is driving the commits.
    public func updateZoomGesture(by factor: CGFloat) {
        engine.updateZoomGesture(by: factor)
        if zoomLink == nil { engine.commitZoomGesture() }
    }

    /// Close a pinch. Safe to call when none is running, so every teardown path can
    /// call it unconditionally.
    public func endZoomGesture() {
        stopZoomLink()
        engine.endZoomGesture()
    }

    /// Zoom immediately, with no gesture bracket — the pre-086 behaviour, kept as the
    /// harness's control arm and for any caller that has a single discrete zoom to
    /// apply (a menu command, a keyboard shortcut) rather than a gesture to track.
    public func zoom(by factor: CGFloat, aroundScreenPoint anchor: CGPoint) {
        engine.zoom(by: factor, aroundScreenPoint: anchor)
    }

    /// Pan by a screen-space delta, as a scroll would. The peer of ``zoom(by:aroundScreenPoint:)``,
    /// and the measurement harness's CONTROL: "is a pinch expensive?" is only
    /// answerable against "is a pan expensive?", on the same board and the same frame.
    public func pan(byScreenDelta delta: CGSize) {
        engine.pan(byScreenDelta: delta)
    }

    private func startZoomLink() {
        guard zoomLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(zoomCommitStep(_:)))
        link.add(to: .main, forMode: .common)
        zoomLink = link
    }

    private func stopZoomLink() {
        zoomLink?.invalidate()
        zoomLink = nil
    }

    /// The link fires on the main runloop; hop back into isolation to commit.
    @objc nonisolated private func zoomCommitStep(_ link: CADisplayLink) {
        MainActor.assumeIsolated { _ = self.engine.commitZoomGesture() }
    }

    /// A single click selects the tile under the cursor (or clears the selection
    /// on empty space); a double-click also activates it (e.g. play a video).
    /// Panning/zooming stay on scroll/pinch, so a click is free to select.
    public override func mouseDown(with event: NSEvent) {
        // Become first responder so the ⌫ / Delete key reaches ``keyDown``.
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        resetGestureState()

        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        pressOptionDown = event.modifierFlags.contains(.option)   // ⌥ → duplicate (065b)
        pressCommandDown = command                                 // ⌘ → drag-out (065b)

        // Gesture precedence lives in `canvasPressTarget` (049 · D8 · 062) so the
        // ORDER is pinned by tests rather than by the shape of this method — the
        // double-click-vs-handle case it settles is a bug this file shipped.
        switch canvasPressTarget(
            tool: tool,
            clickCount: event.clickCount,
            tileID: engine.tile(atScreenPoint: point)?.id,
            handle: engine.resizeHandle(atScreenPoint: point),
            resizeEnabled: onResizeTile != nil)
        {
        case .create:
            createStartPoint = point

        case .activate(let tileID):
            // Collapse to the activated tile and hand it over. Nothing is armed: an
            // activation is not a drag or a resize, so mouse-UP is inert. The
            // selection lands on the DOWN edge here, where the old path deferred it
            // to `pendingClickAction` on the up edge — same outcome, one event sooner.
            applySelection(.selectOnly(tileID))
            // A text tile edits in place, and it begins HERE — synchronously, inside
            // the gesture. `makeFirstResponder(self)` above has already committed any
            // edit that was open, exactly as clicking away would.
            if engine.textStyle(forTileID: tileID) != nil {
                beginEditingText(tileID: tileID, isNewlyCreated: false)
            }
            onActivateTile?(tileID)

        case .resize(let tileID, let handle):
            resizeCandidate = (tileID: tileID, handle: handle)
            dragStartPoint = point

        case .tile(let tileID):
            // Route the press through the selection reducer: ⇧/⌘ act on the down
            // edge; a plain press on a SELECTED tile defers (so a drag carries the
            // whole selection), collapsing to one only if it stays a click. Arm the
            // tile as the drag candidate.
            let routing = canvasPressRouting(
                tileID: tileID,
                isSelected: engine.selectedTileIDs.contains(tileID),
                shift: shift)
            if let press = routing.pressAction { applySelection(press) }
            pendingClickAction = routing.clickAction
            dragStartPoint = point
            dragCandidateTileID = tileID

        case .empty:
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
        pressCommandDown = false
        isDuplicatingDrag = false
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
            // SP7 / 065b: a ⌘-drag on a tile is a drag-OUT (board→board / →collection
            // via the sidebar), not an in-view move — start an NSDraggingSession with
            // the app's asset payload. Asked only under ⌘: building the payload walks
            // the carried tiles, and neither a move nor a duplicate has a use for one.
            let dragOutItem = pressCommandDown ? onBeginTileDragOut?(carry.union([tileID])) : nil
            let intent = Self.dragIntent(
                optionDown: pressOptionDown,
                commandDown: pressCommandDown,
                hasDragOutPayload: dragOutItem != nil,
                canDuplicate: onDuplicateTiles != nil)
            if intent == .dragOut, let dragOutItem {
                beginTileDragOut(pasteboardItem: dragOutItem, primaryTileID: tileID, event: event)
                return
            }
            // ⌘ on tiles nothing can accept: the drag does not happen. Reset rather
            // than return, so the half-armed gesture cannot resume if the pointer keeps
            // moving — one refusal, not a drag that starts on the next tick.
            if intent == .none {
                resetGestureState()
                return
            }
            // Latched at drag-START, not read again at drop: both flags are the modifier
            // state from mouse-DOWN, so releasing ⌥ mid-drag cannot silently turn a
            // duplicate back into a move.
            isDuplicatingDrag = intent == .duplicate
            engine.beginDrag(tileID: tileID, alsoCarry: carry)
        }
        // ⌘ turns snapping off mid-drag, exactly as it does for a resize. This reads the
        // LIVE flag, not the latch, and that is what lets ⌘ carry two meanings on one
        // gesture without ambiguity: held from mouse-down it is a drag-out, which
        // returned above and never reaches here; pressed once a move is already running
        // it suppresses snapping.
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
        // An ⌥-drag duplicates instead of moving (065): report the carried ids and how
        // far they travelled, then let the drag unwind WITHOUT persisting the move, so
        // the originals snap back to where they started and the copies land at the
        // drop. Read before `endDrag()`, which clears both.
        if isDuplicatingDrag {
            let carried = Set(engine.currentDragOrigins().map(\.tileID))
            let offset = engine.currentDragWorldOffset() ?? .zero
            _ = engine.endDrag()
            engine.sync()
            onDuplicateTiles?(carried, offset)
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
        preview.zPosition = CanvasEngine.chromeZ
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
            // **Width only** (see ``textDragChoseWidth(worldRect:)``). A text box's
            // height is derived from its own glyphs, so the height of the rubber-band
            // is not a thing the user can choose and must not be read as one.
            if !Self.textDragChoseWidth(worldRect: worldRect) {
                // A click, not a drag: report the origin and a ZERO size. The host has
                // no business inventing a width here — only the app layer can measure
                // text — so an empty rect is it saying "no width was chosen" and
                // `SpaceModel.addText` sizes the box to its own glyphs (063). This
                // replaced a 260×72 literal that every click-placed box inherited.
                worldRect = CGRect(origin: engine.transform.screenToWorld(a), size: .zero)
            }
        case .frame:
            guard worldRect.width >= Self.minCreateWorldEdge,
                  worldRect.height >= Self.minCreateWorldEdge else { return }
        case .select:
            return
        }
        onCreateElement?(tool, worldRect)
    }

    /// Whether a text rubber-band of `worldRect` states a width the user chose.
    ///
    /// **Width alone decides it.** A text box's HEIGHT follows its wrapped text (062)
    /// and no gesture can set it, so the natural way to draw one — a wide, shallow
    /// band, because that is the shape the box will end up — used to fail a
    /// both-dimensions test and be discarded as a click. The width the user had just
    /// drawn went with it, and they got a hugging box at the press point instead.
    /// Figma honours the width; so do we.
    ///
    /// Pure + static so the rule is pinned by a test rather than by the shape of an
    /// `if` inside a gesture no test wants to build.
    static func textDragChoseWidth(worldRect: CGRect) -> Bool {
        worldRect.width >= minCreateWorldEdge
    }

    /// Abandon an in-progress rubber-band: the preview goes and the armed press is
    /// forgotten, so the eventual mouse-UP has nothing to finish. Safe to call when no
    /// create is in progress.
    private func cancelCreate() {
        createPreviewLayer?.removeFromSuperlayer()
        createPreviewLayer = nil
        createStartPoint = nil
    }

    /// Whether `event` is a bare Escape. Read from `charactersIgnoringModifiers`
    /// rather than the keyCode, matching how every other key on this canvas is read,
    /// and gated by the same ``isBareLetter(_:)`` modifier rule — ⎋ has no modified
    /// meaning here, so ⌘⎋ and friends fall through to the responder chain.
    private static func isEscape(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == "\u{1B}" && isBareLetter(event.modifierFlags)
    }

    private func makeCreatePreviewLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1.5
        layer.borderColor = CanvasChrome.createStroke
        layer.backgroundColor = CanvasChrome.createFill
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
        layer.zPosition = CanvasEngine.chromeZ
        CATransaction.commit()
    }

    private func makeMarqueeLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1
        layer.borderColor = CanvasChrome.marqueeStroke
        layer.backgroundColor = CanvasChrome.marqueeFill
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
    ///
    /// The two items were synonyms until 022 · D3 — both fired the app's
    /// remove-the-placement closure, so "Delete" on a board was a lie. They now name
    /// the two different things they do, and the titles say WHERE each one acts:
    /// "Board" is the container you are looking at, "Library" is everything.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let tile = engine.tile(atScreenPoint: point) else { return nil }
        // Finder rule: right-clicking a tile OUTSIDE the selection selects only it;
        // right-clicking one INSIDE the selection acts on the whole selection.
        if !engine.selectedTileIDs.contains(tile.id) { applySelection(.selectOnly(tile.id)) }

        let menu = NSMenu()
        let remove = NSMenuItem(
            title: "Remove from Board", action: #selector(contextRemove), keyEquivalent: "")
        remove.target = self
        let delete = NSMenuItem(
            title: "Delete from Library…", action: #selector(contextDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(remove)
        menu.addItem(delete)
        if onArchiveTiles != nil {
            let archive = NSMenuItem(
                title: "Archive", action: #selector(contextArchive), keyEquivalent: "")
            archive.target = self
            menu.addItem(.separator())
            menu.addItem(archive)
        }
        return menu
    }

    /// The ⌫ / Delete keys act on the current selection (⌦ forward-delete too).
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // `editingTileID` is belt-and-braces — an open editor normally holds first
        // responder, so this method is unreachable while typing — but an edit begun
        // before the host had a window is still waiting for focus, and in that window
        // the host IS the responder. The delete keys are now INSIDE that gate too: a
        // text box in exactly that state used to lose its tile to a Backspace.
        guard editingTileID == nil else { super.keyDown(with: event); return }

        // Esc disarms a create tool, as Figma's Esc drops back to the Move tool —
        // otherwise Text stays armed until something is placed or `V` is pressed, and
        // every click in between makes a box the user didn't want. A rubber-band
        // already in progress is abandoned with it: nothing is reported, so the press
        // that started it never becomes an element.
        //
        // Gated on `tool != .select` so Esc is only swallowed when it has something to
        // do. With Select active it falls through to `super`, leaving the key free for
        // whatever else the responder chain wants with it.
        if Self.isEscape(event), tool != .select {
            cancelCreate()
            onSelectTool?(.select)
            return
        }

        // ⌫ drops the placement, ⌘⌫ leaves the library (022 · D3). This read used to
        // be `keyCode == 51 || keyCode == 117` with the modifiers never inspected, so
        // a ⌘⌫ was silently treated as a bare ⌫ — the modifier wasn't rejected, it was
        // simply not read — and ⌥⌫ (a word-delete) removed tiles.
        if let intent = Self.deleteIntent(
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
            let ids = engine.selectedTileIDs
            if !ids.isEmpty {
                switch intent {
                case .remove: onRemoveTiles?(ids)
                case .destroy: onDeleteTiles?(ids)
                }
                return
            }
        }
        // The tool keys.
        if let tool = Self.toolShortcut(
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
            onSelectTool?(tool)
            return
        }
        // …and the bare letters that are NOT tools (024 · K3). `A` only, and only with
        // something selected: with an empty board selection there is nothing to file,
        // so the key falls through rather than being swallowed — the same courtesy the
        // delete branch above extends.
        if Self.boardShortcut(
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags) == .file {
            let ids = engine.selectedTileIDs
            if !ids.isEmpty {
                onFileTiles?(ids)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// What a Delete key press means on a board: ``CanvasDeleteIntent/remove`` for a
    /// bare ⌫ / ⌦, ``CanvasDeleteIntent/destroy`` under ⌘, `nil` for anything else.
    ///
    /// **This is a deliberate second copy** of the app's `deleteIntent(characters:
    /// modifiers:)`. This package is declared with ZERO dependencies (see
    /// `Package.swift`) so the compiler enforces the view-agnostic boundary, and the
    /// alternative — moving a decoder whose vocabulary is "remove from a collection"
    /// into a rendering package, or giving the package a dependency on the app —
    /// would cost more than eight lines. The two are held in step by a contract test
    /// in the app's suite (`SpaceDeleteKeyTests`) that runs the whole matrix through
    /// both and asserts they agree, so a divergence fails a build rather than shipping
    /// a board where ⌘⌫ means something else.
    ///
    /// ⌥ and ⌃ disqualify (word / line deletes inside a text box), ⇧ and fn are
    /// tolerated — fn *must* be: on a keyboard with no ⌦ key, ⌦ IS fn-⌫.
    public static func deleteIntent(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> CanvasDeleteIntent? {
        guard !modifiers.contains(.option), !modifiers.contains(.control),
              let scalar = characters?.unicodeScalars.first,
              scalar.value == 0x7F || Int(scalar.value) == NSDeleteFunctionKey
        else { return nil }
        return modifiers.contains(.command) ? .destroy : .remove
    }

    /// What a tile drag past the threshold means.
    public enum CanvasDragIntent: Equatable, Sendable {
        /// Leave the board — an `NSDraggingSession` to another board or a collection.
        case dragOut
        /// Create copies at the drop, leaving the originals put.
        case duplicate
        /// Move the tiles.
        case move
        /// Do nothing at all — the drag never begins (065b).
        ///
        /// Reached by ⌘-dragging a tile that cannot leave the board: a frame or a text
        /// box, which no collection can hold. Falling through to a plain move was
        /// considered and rejected, because it would make ⌘ mean "leave the board" on
        /// an asset and "move without snapping" on an element — a modifier whose
        /// meaning depends on what you happen to have grabbed is not one you can learn,
        /// and that ambiguity is the whole reason drag-out moved off ⌥.
        case none
    }

    /// Resolve what the held modifiers mean for this drag. Pure, so the PRECEDENCE is
    /// pinned by tests rather than by the shape of an `if` — the same posture
    /// `canvasPressTarget` took after gesture ordering in this file shipped a bug.
    ///
    /// **One modifier, one meaning** (065b). 065 shipped both gestures on ⌥ and split
    /// them by whether the tiles could leave the board, so ⌥ meant *drag-out* on an
    /// asset and *duplicate* on a frame. That is unlearnable, and it also meant assets
    /// could not be duplicated by drag at all. So:
    ///
    /// - **⌥ duplicates**, every tile kind, always.
    /// - **⌘ drags out**, and on tiles nothing can accept it does nothing rather than
    ///   quietly degrading to a move (see ``CanvasDragIntent/none``).
    /// - Holding both is a drag-out: leaving the board is the more consequential of the
    ///   two and the one you have to mean, whereas an unwanted duplicate is one ⌘Z away.
    /// - Without an `onDuplicateTiles` handler, ⌥ is a plain move.
    static func dragIntent(
        optionDown: Bool, commandDown: Bool, hasDragOutPayload: Bool, canDuplicate: Bool
    ) -> CanvasDragIntent {
        if commandDown { return hasDragOutPayload ? .dragOut : .none }
        if optionDown, canDuplicate { return .duplicate }
        return .move
    }

    /// The tool a bare keystroke asks for, or `nil`. Pure, so the mapping is pinned by
    /// tests rather than by an `NSEvent` no test wants to build.
    ///
    /// Bare means bare: any of ⌘ / ⌥ / ⌃ disqualifies it, so ⌘V still pastes. ⇧ is
    /// allowed through `lowercased()` — an accidental capital shouldn't silently do
    /// nothing when the user meant the tool.
    ///
    /// `public` for the same reason ``deleteIntent(characters:modifiers:)`` is: the
    /// app's key map (024 · K1) claims V / F / T on this surface, and the contract test
    /// that keeps that claim honest lives in the app's suite, which can only see the
    /// package's public surface. It remains a pure read of a key — nothing dispatches
    /// from outside this file.
    public static func toolShortcut(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> CanvasTool? {
        guard isBareLetter(modifiers) else { return nil }
        switch characters?.lowercased() {
        case "v": return .select
        case "f": return .frame
        case "t": return .text
        default: return nil
        }
    }

    /// A bare keystroke that asks the board for something which is NOT a tool.
    ///
    /// One case today, and the enum exists rather than a `Bool` so the second one is a
    /// case rather than a second decoder.
    public enum CanvasBoardCommand: Equatable, Sendable {
        /// `A` — file the selected tiles' assets somewhere, placements untouched.
        case file
    }

    /// The board command a bare keystroke asks for, or `nil` (024 · K3).
    ///
    /// **Why this is a sibling of ``toolShortcut(characters:modifiers:)`` rather than
    /// another case in it.** `toolShortcut` returns a ``CanvasTool``, and `CanvasTool`
    /// is not "a thing a key can do" — it is the canvas's MODE, the value the tool
    /// picker binds to, the value `onCreateElement` switches over, and the value the
    /// host stores in ``tool`` and keeps until something changes it. Filing tiles is a
    /// one-shot verb with no mode to be in, so an `.addToCollection` case on
    /// `CanvasTool` would have to be excluded by hand from the picker, from the create
    /// path and from the host's own state — a value that is a member of the enum
    /// everywhere except the three places the enum is used. Two small decoders keep
    /// `CanvasTool` meaning exactly the three modes it has always meant.
    ///
    /// They share ``isBareLetter(_:)`` so the modifier rule cannot drift between them:
    /// ⌘ / ⌥ / ⌃ / fn disqualify (so ⌘A is still Select All wherever that is bound,
    /// and ⌥A still types `å` in a text box), ⇧ is tolerated via `lowercased()`.
    ///
    /// **`M` is deliberately absent.** [024] §C recommended M ("Move to…") on every
    /// surface with a selection; on a board that would have meant filing the assets
    /// AND dropping the placements, which is a different verb from the grid's M under
    /// the same key. See the doc's §C amendment.
    public static func boardShortcut(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> CanvasBoardCommand? {
        guard isBareLetter(modifiers) else { return nil }
        switch characters?.lowercased() {
        case "a": return .file
        default: return nil
        }
    }

    /// The modifier rule every bare-letter binding on this canvas lives under: none of
    /// ⌘ / ⌥ / ⌃ / fn, and ⇧ tolerated (the callers `lowercased()` the character).
    private static func isBareLetter(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.command) && !modifiers.contains(.option)
            && !modifiers.contains(.control) && !modifiers.contains(.function)
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

    @objc private func contextArchive() {
        let ids = engine.selectedTileIDs
        if !ids.isEmpty { onArchiveTiles?(ids) }
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

/// The layer-hosting surface the ``CanvasEngine`` draws into, sitting beneath every
/// real subview of ``CanvasHostView``.
///
/// It exists so the host itself does NOT have to be layer-hosting. A layer-hosting
/// view owns its layer's sublayers completely — the engine pools, recycles and
/// z-orders them every `sync()` — so a subview added to it would have its backing
/// layer spliced into that same tree, competing with tiles by `zPosition` and
/// breaking the "one layer per visible tile" invariant. Splitting the two means the
/// host can hold ordinary AppKit subviews (the inline text editor) above a canvas
/// that keeps managing its own layers.
///
/// Transparent to events: `hitTest` returns `nil`, so every click, drag and scroll
/// still lands on the host exactly as it did when the host was the drawing view.
/// Flipped to match the host (top-left origin, y down), so the engine's screen-space
/// geometry is unchanged.
final class CanvasSurfaceView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
