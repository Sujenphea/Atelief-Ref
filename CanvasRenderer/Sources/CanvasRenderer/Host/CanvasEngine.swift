import CoreGraphics
import QuartzCore

/// The heart of the renderer: each frame it culls to the viewport, recycles
/// layers for tiles that left, positions layers for tiles that entered, picks an
/// LOD tier, and paints from cache (requesting an async decode on a miss).
///
/// It is deliberately **window-free** so the per-frame cost can be measured
/// headlessly (the Checkpoint 6 benchmark) and the layer-pool invariants asserted
/// (Checkpoint 5). ``CanvasHostView`` is a thin `NSView` that owns events and
/// calls ``sync()``.
@MainActor
public final class CanvasEngine {
    /// The layer all tile layers are attached to (becomes the host view's layer).
    public let rootLayer: CALayer

    private let provider: TileProvider
    private let images: any TileImageSource
    private let culler = TileCuller()
    private let lod: LODPolicy
    private let pool: LayerPool
    private let cache: ThumbnailCache
    private let scheduler: DecodeScheduler

    /// Current world↔screen mapping. Mutate via ``pan(byScreenDelta:)`` /
    /// ``zoom(by:aroundScreenPoint:)`` / ``setTransform(_:)``.
    public private(set) var transform: CanvasTransform
    /// Viewport size in screen points. Set by the host on layout/resize.
    public var viewportSize: CGSize
    /// Screen-space ring decoded ahead of the viewport (decision P15).
    public var prefetchMarginScreen: CGFloat

    /// Fired exactly ONCE per transform mutation (``pan`` / ``zoom`` /
    /// ``setTransform``, and thus ``frameToContent`` for free) — the single choke
    /// point for the inline text editor to reposition its overlay imperatively
    /// (2B · 054 §5.1 · R2). Notified AFTER the ``sync()`` so a listener reading
    /// ``currentScreenFrame(forTileID:)`` sees the post-mutation geometry. `nil`
    /// disables the notification (the common, no-editor case).
    public var onTransformChanged: (() -> Void)?

    /// Fired when a LIVE gesture moves a tile's DISPLAYED frame without touching the
    /// camera — a resize drag or a move drag (062). The peer of ``onTransformChanged``,
    /// and it exists because that one is not enough: the inline editor places its
    /// overlay from the edited tile's on-screen frame, and the app's floating format
    /// chrome anchors on the selected tile's, so any change to that frame must reach
    /// them, whether the box moved under the camera or the camera moved under the box.
    ///
    /// Without this a resize of the tile being edited desynchronises the two halves of
    /// what the user sees: the engine redraws the box, border and handles at the live
    /// frame, while the `NSTextView` above them keeps the wrap width it was mounted
    /// with — so the box narrows and the text spills straight out of it. Every fix on
    /// the ``setGlyphOverlay`` path is inert here, because those glyphs are blanked
    /// while ``editingTileID`` is set.
    ///
    /// Notified AFTER the ``sync()``, exactly as ``onTransformChanged`` is, so a
    /// listener reading ``currentScreenFrame(forTileID:)`` sees the new geometry.
    public var onLiveFrameChanged: (() -> Void)?

    /// The tile whose text an app-layer inline editor currently owns (2B · 054
    /// §5.2), or `nil`. While set, that tile's `.text` glyphs are BLANKED in
    /// ``sync()`` so the live `NSTextView` above it isn't doubled by the
    /// `CATextLayer` beneath. Setting it re-syncs so the blank takes effect at once.
    public var editingTileID: Int? {
        didSet {
            guard editingTileID != oldValue else { return }
            // A height belongs to ONE edit. Carrying it into the next one would draw
            // the new box at the old box's height until its first keystroke. Same
            // reasoning for the auto-width span (063), so they clear together.
            editingWorldHeight = nil
            editingWorldSpan = nil
            sync()
        }
    }

    /// The world height the open editor currently needs, or `nil` when no editor is
    /// up (or before it has measured). Applied to ``editingTileID``'s displayed frame.
    private var editingWorldHeight: CGFloat?

    /// The world `minX` + width an open editor needs for an **auto-width** box (063),
    /// or `nil`. Never set for a fixed box, whose width is the user's and must not
    /// follow the text.
    ///
    /// Its own property rather than a wider `editingWorldFrame` on purpose: the two
    /// axes are owned by different rules — the height always follows the text, the
    /// width only does so when the box is flagged — and one optional per rule means a
    /// fixed box cannot accidentally inherit a width override.
    private var editingWorldSpan: (minX: CGFloat, width: CGFloat)?

    /// Relayouts served — introspection for the tests, in the same spirit as
    /// ``TextRenderLayer/drawCount``: the per-keystroke paths must cost nothing when
    /// nothing they own actually changed.
    public private(set) var syncCount = 0

    private var active: [Int: CALayer] = [:]
    private var keyByTile: [Int: ThumbnailCache.Key] = [:]
    /// Badge overlay layers (e.g. the ▶ for a video), keyed by tile id — siblings
    /// of the tile layers, so they never entangle with the recycling ``LayerPool``.
    private var badges: [Int: CALayer] = [:]
    /// Text overlay layers for freeform `.text` tiles and `.frame` labels (E3),
    /// keyed by tile id — `CATextLayer` siblings OUTSIDE the recycled ``LayerPool``
    /// (decision T3), created/dropped like ``badges``. A tile has at most one.
    private var textLayers: [Int: TextRenderLayer] = [:]

    /// Backing scale (points → pixels) for crisp vector text. The window host sets
    /// it from `backingScaleFactor`; defaults to 2 so headless/text tests still
    /// rasterize at Retina density.
    public var backingScale: CGFloat = 2

    /// The ▶ glyph, rendered once and shared by every badge layer's `contents`.
    private lazy var playBadgeImage: CGImage? = Self.makePlayBadgeImage()

    /// The currently selected tiles' ids (049 · D1 — multi-select). Drives one
    /// highlight layer per selected-and-visible tile and is the target set the host
    /// acts on for Delete / context-menu actions. Empty when nothing is selected.
    public private(set) var selectedTileIDs: Set<Int> = []

    /// Single-selection convenience for the callers/tests that act on exactly one
    /// tile: the lone selected id, or `nil` when the selection is empty OR holds
    /// more than one tile. Derived, never stored — no parallel state to drift.
    public var selectedTileID: Int? { selectedTileIDs.count == 1 ? selectedTileIDs.first : nil }

    /// Highlight border layers keyed by tile id — siblings OUTSIDE the recycled
    /// ``LayerPool`` (exactly like ``badges`` / ``textLayers``), created for a
    /// visible-AND-selected tile and dropped when it is deselected or leaves the
    /// viewport. Layer count is therefore bounded by the VIEWPORT, never the
    /// selection size (049 · D16), so a select-all on a huge board stays cheap.
    private var selectionLayers: [Int: CALayer] = [:]

    /// The tile currently being live-dragged, or `nil`. While set, its world
    /// frame is displayed offset by ``dragWorldOffset`` (in ``sync()`` and
    /// hit-testing) so the tile, its badge, and the highlight follow the cursor
    /// without touching the provider until the drag ends.
    private var dragTileID: Int?
    /// The **other** tiles carried along with ``dragTileID`` this drag (E3 —
    /// frame-as-group: a dragged frame moves the tiles it contains). Snapshotted
    /// once at ``beginDrag(tileID:)`` from the provider, offset by the same delta.
    private var dragGroupIDs: Set<Int> = []
    /// The live-drag's world-space offset from the dragged tile's stored origin.
    private var dragWorldOffset: CGSize = .zero

    /// The tile being live-resized (062), or `nil`. Like a drag, this is transient:
    /// the provider is untouched until the host persists the final frame.
    private var resizeTileID: Int?
    /// The handle being dragged this resize.
    private var activeResizeHandle: ResizeHandle?
    /// The resized tile's frame at `beginResize` — every update recomputes from THIS
    /// rather than accumulating, so a resize can't drift over a long drag.
    private var resizeOriginalFrame: CGRect = .zero
    /// The live world frame the resized tile is drawn at, or `nil` when idle.
    private var resizeWorldFrame: CGRect?
    /// The handle dots drawn on the single selected resizable tile.
    private var handleLayers: [ResizeHandle: CALayer] = [:]
    /// The snap guides for the current resize tick, in WORLD space.
    private var activeSnapGuides: [SnapGuide] = []
    /// The drawn guide lines, recycled across ticks (a resize churns these fast).
    private var guideLayers: [CALayer] = []
    /// The tiles currently washed as members. Two gestures write it and it holds ONE
    /// set, because there is only one thing it can mean on screen: *these tiles belong
    /// to that rect*. A resize keeps it live tick by tick (062 — membership is derived
    /// from containment, so a resize silently changes it, and showing the prospective
    /// set turns that invisible side effect into something the user can aim); ⌘G raises
    /// it once, briefly, over the tiles its new frame adopted (100 §5).
    ///
    /// Sharing the field is what keeps the two drivers honest about precedence — see
    /// ``washMembership(_:for:)`` for why the resize always wins.
    private var prospectiveMemberIDs: Set<Int> = []
    /// The wash drawn over each prospective member.
    private var membershipLayers: [Int: CALayer] = [:]
    /// The pending self-clear of a ⌘G wash (100 · P3), or `nil` when no wash is timed.
    /// Held so it can be CANCELLED: a wash that outlives its reason would clear a set
    /// some later gesture had put there.
    private var membershipWashExpiry: Task<Void, Never>?

    public init(
        provider: TileProvider,
        images: any TileImageSource,
        transform: CanvasTransform = CanvasTransform(),
        viewportSize: CGSize = .zero,
        lod: LODPolicy = LODPolicy(),
        maxCacheBytes: Int = 256 * 1024 * 1024,
        prefetchMarginScreen: CGFloat = 200,
        rootLayer: CALayer = CALayer()
    ) {
        self.provider = provider
        self.images = images
        self.transform = transform
        self.viewportSize = viewportSize
        self.lod = lod
        self.prefetchMarginScreen = prefetchMarginScreen
        self.rootLayer = rootLayer
        self.pool = LayerPool()
        self.cache = ThumbnailCache(maxBytes: maxCacheBytes)
        self.scheduler = DecodeScheduler(cache: cache)
        self.scheduler.onDecoded = { [weak self] key in self?.applyDecoded(key) }
    }

    // MARK: Introspection (used by the invariant tests + benchmark)

    /// Tile layers currently attached (should equal the culled visible count).
    public var activeLayerCount: Int { active.count }
    /// Total layers the pool has allocated (`inUse + free`) — must stay bounded.
    public var allocatedLayerCount: Int { pool.allocatedCount }
    /// Approximate resident bytes of decoded thumbnails.
    public var cacheResidentBytes: Int { cache.residentBytes }
    /// Outstanding async decodes.
    public var inFlightDecodeCount: Int { scheduler.inFlightCount }

    /// The cache key a tile is currently painted from — the LOD-freeze tests read the
    /// tier out of it. Internal: which tier a tile drew at is a renderer detail, and
    /// no app caller has ever needed it.
    func cacheKey(forTileID id: Int) -> ThumbnailCache.Key? { keyByTile[id] }

    /// The on-screen frame a tile WOULD be drawn at — its stored world frame plus any
    /// live-drag / live-resize / editing-height adjustment, mapped through the
    /// transform. `nil` only when the id resolves to no tile at all.
    ///
    /// Deliberately **not** gated on visibility. The culler is a rendering
    /// optimisation, not a statement about whether a tile exists, and a caller that
    /// needs a frame usually needs it most in the moments the culler has nothing to
    /// say — before the first ``layout()``, ``viewportSize`` is still `.zero` and
    /// ``currentVisibleTiles()`` returns nothing at all. Reading "no frame" as "the
    /// tile is gone" is what made an inline editor commit itself the instant it
    /// mounted. Ask ``isVisible(tileID:)`` for the separate question.
    public func screenFrame(forTileID id: Int) -> CGRect? {
        guard let tile = tile(withID: id) else { return nil }
        return transform.worldToScreen(displayWorldFrame(for: tile))
    }

    /// The tile's **committed** world frame — what the provider last supplied, with no
    /// live drag, resize or editing override applied.
    ///
    /// The peer of ``screenFrame(forTileID:)``, and the two answer deliberately
    /// different questions: that one is *where it is drawn right now*, this one is
    /// *what it actually is*. An auto-width editor (063) needs the second, because it
    /// re-anchors on every keystroke and anchoring against the live frame would mean
    /// anchoring against its own previous answer — which compounds into a sideways
    /// crawl. See ``canvasInlineEditorAnchoredMinX(oldMinX:oldWidth:newWidth:alignment:)``.
    public func storedWorldFrame(forTileID id: Int) -> CGRect? {
        tile(withID: id)?.worldFrame
    }

    /// The world frame a tile is **drawn at right now** — its stored frame plus every
    /// transient override in force: a drag's offset, a live resize, and an open
    /// editor's derived height / auto-width span.
    ///
    /// The third of the trio, and the one that was missing. ``storedWorldFrame`` is
    /// what the model has, ``screenFrame`` is that under the camera, and this is what
    /// the user can actually see — in the model's own units, so the app can hand it
    /// back as geometry.
    ///
    /// It exists because a display-only override can become the user's decision. While
    /// a box hugs its text its width lives HERE and nowhere else (``setEditingBoxSpan``
    /// writes no row), so the moment the user says "fixed", the number to freeze is
    /// this one — not the stored width, which is still whatever the box was born at.
    /// Freezing the stored one shrank a typed box back to its 8pt birth size and then
    /// wrapped the text into it.
    public func liveWorldFrame(forTileID id: Int) -> CGRect? {
        tile(withID: id).map(displayWorldFrame(for:))
    }

    /// Whether a tile is in the culled-visible set right now — i.e. whether the user
    /// can actually see it. The peer of ``screenFrame(forTileID:)``, split out so
    /// "where is it" and "can it be seen" are never conflated again.
    public func isVisible(tileID id: Int) -> Bool {
        currentVisibleTiles().contains { $0.id == id }
    }

    /// The text a tile draws, or `nil` if it isn't a `.text` tile.
    ///
    /// This is the whole typography seam for inline editing: ``TextStyle`` already
    /// carries the string, size, colour, family, weight and alignment, and the provider
    /// already hands it across on every sync — so an editor inside the renderer needs
    /// nothing from the app to build its glyphs, and the app needs to teach the renderer
    /// nothing about its own style type.
    public func textStyle(forTileID id: Int) -> TextStyle? {
        guard let tile = tile(withID: id),
              case .text(let style) = provider.content(for: tile) else { return nil }
        return style
    }

    /// ``screenFrame(forTileID:)``, but `nil` for a tile that isn't currently visible.
    /// Kept because callers depend on exactly that: the drag-out snapshot has no image
    /// to make for an off-screen tile, and the transform-seam tests pin the `nil`.
    public func currentScreenFrame(forTileID id: Int) -> CGRect? {
        isVisible(tileID: id) ? screenFrame(forTileID: id) : nil
    }

    /// The tiles visible under the current transform + viewport + prefetch margin.
    public func currentVisibleTiles() -> [Tile] {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return [] }
        let worldViewport = transform.visibleWorldRect(viewportSize: viewportSize)
        let marginWorld = prefetchMarginScreen / transform.scale
        return culler.visibleTiles(in: provider.tiles, worldViewport: worldViewport, margin: marginWorld)
    }

    // MARK: Transform mutations

    public func setTransform(_ newTransform: CanvasTransform) {
        transform = newTransform
        sync()
        onTransformChanged?()
    }

    public func pan(byScreenDelta delta: CGSize) {
        transform = transform.panned(byScreenDelta: delta)
        sync()
        onTransformChanged?()
    }

    public func zoom(by factor: CGFloat, aroundScreenPoint anchor: CGPoint) {
        transform = transform.zoomed(by: factor, aroundScreenPoint: anchor)
        sync()
        onTransformChanged?()
    }

    // MARK: Zoom gesture (018 · C7 — pinch smoothing, 086)

    /// The running pinch, or `nil` between gestures.
    private var zoomGesture: CanvasZoomGesture?

    /// Whether a pinch is in progress. Two things read it: the LOD tier is FROZEN
    /// while it is true (see ``paintImage(tile:layer:neededKeys:)``), and the host
    /// uses it to tell a gesture event from a stray one.
    public var isZoomGestureActive: Bool { zoomGesture != nil }

    /// The running gesture — introspection for the tests.
    var currentZoomGesture: CanvasZoomGesture? { zoomGesture }

    /// Begin a pinch anchored at `anchor` (a screen point).
    ///
    /// The three-call shape (`begin` / `update` / `end`) exists because a pinch is a
    /// gesture and the old path had no concept of one: it answered each `magnify`
    /// event with a full ``sync()`` plus an ``onTransformChanged`` fan-out, so a
    /// two-second pinch cost ~240 relayouts, ~240 editor repositions and ~240
    /// create-and-cancel camera debounce tasks. Bracketing lets the host gather the
    /// events and commit them once per vsync, and lets everything downstream hear
    /// about the camera ONCE, at the end.
    ///
    /// An unclosed gesture is ended first rather than replaced: `.cancelled` is not
    /// reliably delivered, and a leaked gesture would leave the tiers frozen and the
    /// notification suppressed for every pinch after it.
    public func beginZoomGesture(anchorScreenPoint anchor: CGPoint) {
        if zoomGesture != nil { endZoomGesture() }
        zoomGesture = CanvasZoomGesture(anchor: anchor)
    }

    /// Fold one event's factor into the running gesture. Does NOT sync — that is
    /// ``commitZoomGesture()``'s job, on the host's display link. Returns whether a
    /// gesture was running and the factor was usable.
    @discardableResult
    public func updateZoomGesture(by factor: CGFloat) -> Bool {
        guard zoomGesture != nil else { return false }
        return zoomGesture?.accumulate(factor) ?? false
    }

    /// Apply everything accumulated since the last commit, and redraw.
    ///
    /// Returns whether anything was outstanding, so a vsync during a pause in the
    /// gesture costs one comparison. Deliberately silent — no ``onTransformChanged``
    /// — because the camera is still moving; listeners hear the final value from
    /// ``endZoomGesture()``. The tiers stay frozen, so a commit re-lays existing
    /// layers and requests no new decodes.
    @discardableResult
    public func commitZoomGesture() -> Bool {
        guard let anchor = zoomGesture?.anchor, let factor = zoomGesture?.takePending()
        else { return false }
        transform = transform.zoomed(by: factor, aroundScreenPoint: anchor)
        sync()
        return true
    }

    /// Close the gesture: commit the remainder, un-freeze the tiers, and notify once.
    ///
    /// The second ``sync()`` is the re-tier — while the gesture ran, every tile kept
    /// the tier it started with, so this is where a tile that grew across a boundary
    /// finally asks for the sharper thumbnail. Doing it once at settle rather than
    /// per event is the point: a pinch sweeping a boundary used to request decodes
    /// and cancel them on the next event (``DecodeScheduler/retainOnly(_:)``), paying
    /// for work whose result was thrown away.
    ///
    /// A gesture that never moved leaves NO trace — no sync, no notification, no
    /// camera write. Resting two fingers on the trackpad is not a camera change.
    public func endZoomGesture() {
        guard let gesture = zoomGesture else { return }
        commitZoomGesture()
        zoomGesture = nil
        guard gesture.hasMoved else { return }
        sync()
        onTransformChanged?()
    }

    /// Select exactly `ids` (or clear with an empty set) and redraw the highlights.
    /// Idempotent — re-selecting the same set is a no-op, so it's cheap to call on
    /// every click / marquee tick.
    public func setSelected(_ ids: Set<Int>) {
        guard selectedTileIDs != ids else { return }
        selectedTileIDs = ids
        sync()
    }

    /// Single-selection convenience (clear with `nil`) over ``setSelected(_:)``.
    public func setSelected(_ id: Int?) {
        setSelected(id.map { [$0] } ?? [])
    }

    // MARK: Live drag (transient placement, no provider mutation)

    /// Begin live-dragging `tileID`, carrying `alsoCarry` along with it (049 · D3 —
    /// a multi-selection drag) UNIONED with the frame-as-group members the provider
    /// reports (``TileProvider/groupMembers(forDraggedTileID:)`` — a frame moves its
    /// contents). The carried set is a single de-duplicated ``Set`` (049 · D7 — a
    /// selected tile that is ALSO inside a dragged frame is carried once, never
    /// twice), and the primary tile is implicit (removed so it is never doubled).
    /// Nothing moves until ``updateDrag(byScreenDelta:)`` reports movement.
    public func beginDrag(tileID: Int, alsoCarry: Set<Int> = []) {
        dragTileID = tileID
        dragGroupIDs = Set(provider.groupMembers(forDraggedTileID: tileID)).union(alsoCarry)
        dragGroupIDs.remove(tileID) // the dragged tile is implicit, never doubled
        dragWorldOffset = .zero
    }

    /// Resolve a tile by id. ``Tile/id`` is the index into the provider's rows (its
    /// documented contract), so this is O(1) — but guarded, and it falls back to a
    /// scan if a provider ever violates the invariant, so correctness never depends
    /// on it (049 · D15). Replaces the O(K·N) `first(where:)` scans in the drag-
    /// origin paths, which run once per carried tile at drop.
    private func tile(withID id: Int) -> Tile? {
        let tiles = provider.tiles
        if tiles.indices.contains(id), tiles[id].id == id { return tiles[id] }
        return tiles.first { $0.id == id }
    }

    /// Update the live drag to a **cumulative** screen delta from the drag's
    /// start point. Converts to a world delta (world = screen / `scale`; the
    /// mapping is `screen = world * scale + translation`, uniform positive scale
    /// with no y-flip in the transform, so the sign is direct) and re-syncs so
    /// the dragged tile follows the cursor.
    public func updateDrag(byScreenDelta screenDelta: CGSize, snapping: Bool = true) {
        guard dragTileID != nil else { return }
        var offset = CGSize(
            width: screenDelta.width / transform.scale,
            height: screenDelta.height / transform.scale)

        // Snap the CARRIED SET's bounding box, not the grabbed tile: dragging a
        // frame (or a multi-selection) should align the thing the user sees moving,
        // and a group whose members snapped individually would tear itself apart.
        if snapping, let box = draggedBoundingBox(offsetBy: offset) {
            let snap = CanvasSnapping.snapOffset(
                movingBox: box,
                candidates: dragSnapCandidates(),
                threshold: CanvasSnapping.worldThreshold(scale: transform.scale))
            offset.width += snap.offset.width
            offset.height += snap.offset.height
            activeSnapGuides = snap.guides
        } else {
            activeSnapGuides = []
        }

        dragWorldOffset = offset
        sync()
        onLiveFrameChanged?()
    }

    /// The union of every carried tile's world frame at `offset`, or `nil` when the
    /// drag carries nothing drawable.
    private func draggedBoundingBox(offsetBy offset: CGSize) -> CGRect? {
        guard let primary = dragTileID else { return nil }
        var box: CGRect?
        for id in [primary] + dragGroupIDs {
            guard let tile = tile(withID: id) else { continue }
            let frame = tile.worldFrame.offsetBy(dx: offset.width, dy: offset.height)
            box = box.map { $0.union(frame) } ?? frame
        }
        return box
    }

    /// The frames a drag may snap to: visible tiles that are NOT being carried. A
    /// carried tile moves with the box, so snapping to one would be snapping to
    /// yourself — the drag would seize up and never move.
    private func dragSnapCandidates() -> [CGRect] {
        var carried = dragGroupIDs
        if let primary = dragTileID { carried.insert(primary) }
        return currentVisibleTiles().filter { !carried.contains($0.id) }.map(\.worldFrame)
    }

    /// Finalize the live drag: return the dragged tile's FINAL world origin
    /// (stored origin + offset) and clear the drag state, WITHOUT syncing.
    ///
    /// Ordering matters (avoids a viewport reset / snap-back): the host calls
    /// this, hands the origin to the provider (an in-memory placement update),
    /// then calls ``sync()`` — by then the provider reports the new geometry and
    /// the offset is cleared, so the tile stays exactly where it was dropped.
    /// Returns `nil` when nothing was being dragged.
    ///
    /// Notifies ``onLiveFrameChanged`` on the way out — but only if a drag was
    /// actually running, so an ordinary click doesn't fire it. By this point the
    /// provider already holds the dropped origin (the host persisted it above) and
    /// the offset is cleared, so a listener that tracked the drag lands on the
    /// committed frame rather than on the last mid-drag tick. Mirrors ``endResize()``.
    public func endDrag() -> (tileID: Int, worldOrigin: CGPoint)? {
        let wasDragging = dragTileID != nil
        defer { if wasDragging { onLiveFrameChanged?() } }
        guard let id = dragTileID, let tile = tile(withID: id) else {
            dragTileID = nil
            dragGroupIDs = []
            dragWorldOffset = .zero
            activeSnapGuides = []
            return nil
        }
        let origin = CGPoint(
            x: tile.worldFrame.origin.x + dragWorldOffset.width,
            y: tile.worldFrame.origin.y + dragWorldOffset.height)
        dragTileID = nil
        dragGroupIDs = []
        dragWorldOffset = .zero
        activeSnapGuides = []
        return (id, origin)
    }

    /// Every tile carried by the current drag (the primary tile + its group), with
    /// its FINAL world origin under the live offset. **Non-mutating** — the host
    /// calls this to persist all moved placements, then calls ``endDrag()`` to
    /// clear the drag state. Empty when nothing is being dragged.
    public func currentDragOrigins() -> [(tileID: Int, worldOrigin: CGPoint)] {
        guard let primary = dragTileID else { return [] }
        var ids = [primary]
        ids.append(contentsOf: dragGroupIDs.sorted())
        return ids.compactMap { id in
            guard let tile = tile(withID: id) else { return nil }
            let origin = CGPoint(
                x: tile.worldFrame.origin.x + dragWorldOffset.width,
                y: tile.worldFrame.origin.y + dragWorldOffset.height)
            return (id, origin)
        }
    }

    /// How far the current drag has carried its tiles, in WORLD units, or `nil` when
    /// nothing is being dragged.
    ///
    /// The offset rather than the origins is what an ⌥-duplicate needs (065): the
    /// copies are new rows that do not exist yet, so there is no tile id to report an
    /// origin for — only "this far from wherever your source was". Non-mutating, and
    /// read before ``endDrag()`` clears it, exactly like ``currentDragOrigins()``.
    public func currentDragWorldOffset() -> CGSize? {
        dragTileID == nil ? nil : dragWorldOffset
    }

    /// The world frame a tile is drawn at this frame — its stored frame, replaced by
    /// the live-resize frame while it is being resized, else offset by the live-drag
    /// delta when it's the dragged tile or one of its group. Resize wins because the
    /// two gestures are mutually exclusive: a press either grabs a handle or the
    /// body, never both.
    ///
    /// An open editor then overrides the HEIGHT (062). Height only, and last: under
    /// 062 a text box's height is not geometry the user sets but a fact about the
    /// text, so while an editor holds the text it also holds the height — whereas the
    /// width stays the user's, whether that's the stored one or the one a handle drag
    /// is setting this very moment. Applying it after both gestures is what lets a
    /// resize *while* editing take its width from the drag and its height from the
    /// text now in the editor, rather than from the last committed string.
    private func displayWorldFrame(for tile: Tile) -> CGRect {
        var frame = tile.worldFrame
        if tile.id == resizeTileID, let live = resizeWorldFrame {
            frame = live
        } else if tile.id == dragTileID || dragGroupIDs.contains(tile.id) {
            frame = frame.offsetBy(dx: dragWorldOffset.width, dy: dragWorldOffset.height)
        }
        if tile.id == editingTileID, let height = editingWorldHeight {
            frame.size.height = height
        }
        // The auto-width span, but never while a resize drag owns this tile: a drag is
        // the user taking the width back, and what they see during it must be what
        // they get. The height override above has no such guard because a resize
        // re-derives the height anyway — only the width is contested.
        if tile.id == editingTileID, tile.id != resizeTileID, let span = editingWorldSpan {
            frame.origin.x = span.minX
            frame.size.width = span.width
        }
        return frame
    }

    /// Draw the tile being edited at the height its editor currently needs, or `nil`
    /// to fall back to the stored one.
    ///
    /// 054 §5.2 (R16) deliberately kept the canvas out of the keystroke path: the
    /// editor grew its own overlay and the engine was left alone. Under the three-way
    /// resize modes that was right — a `.fixed` box's height was the user's, and had
    /// no business following the text. 062 removed that: the height IS the text now,
    /// so a box that doesn't grow as you type is showing a size that stopped being
    /// true at the first keystroke, and its border and handles sit inside its own
    /// glyphs until you commit.
    ///
    /// Cheap enough to call per keystroke: it is a `CGFloat` compare and, when it
    /// really changed, a ``sync()`` — which relays existing layers and re-rasterizes
    /// nothing (the edited tile's glyphs are blanked; the editor draws them). It is
    /// deliberately NOT a provider mutation and NOT a write: nothing is persisted
    /// until the edit commits, so an abandoned edit leaves no trace.
    ///
    /// Does not fire ``onLiveFrameChanged``. The editor is the caller here, and
    /// telling it what it just told us would be a loop with no new information.
    public func setEditingBoxHeight(_ height: CGFloat?) {
        guard editingWorldHeight != height else { return }
        editingWorldHeight = height
        sync()
    }

    /// Draw the tile being edited at the left edge + width its editor currently needs
    /// (063), or `nil` to fall back to the stored ones.
    ///
    /// The horizontal peer of ``setEditingBoxHeight(_:)``, and set only for a box that
    /// hugs its text. Both edges come together because they move together: growing a
    /// centre- or right-aligned box changes where its left edge is, so pushing a width
    /// without the matching `minX` would slide the box sideways as you type.
    ///
    /// Same cost and same discipline as the height override — a compare, then a
    /// ``sync()`` that re-lays existing layers; no provider mutation, no write, and
    /// no ``onLiveFrameChanged`` (the editor is the caller).
    public func setEditingBoxSpan(minX: CGFloat?, width: CGFloat?) {
        let span: (minX: CGFloat, width: CGFloat)? =
            if let minX, let width { (minX, width) } else { nil }
        guard span?.minX != editingWorldSpan?.minX
                || span?.width != editingWorldSpan?.width else { return }
        editingWorldSpan = span
        sync()
    }

    // MARK: Live resize (transient geometry, no provider mutation — 062)

    /// Whether `tile` may be resized by dragging a handle — every kind can.
    ///
    /// Each answers a width differently, and that difference lives in one place
    /// (``fittedFrame`` / ``locksAspect``) rather than in the gesture: text
    /// re-derives its height from the re-wrapped glyphs, an image holds its ratio so
    /// it can never distort, and a frame simply takes the rect (its contents keep
    /// their own positions — a frame is a boundary, not a scaler).
    private func isResizable(_ tile: Tile) -> Bool { true }

    /// Whether `tile` must keep its aspect ratio regardless of modifiers. Images do:
    /// a distorted photograph is never what the user meant, so the lock is the
    /// default rather than something they have to remember to hold.
    private func locksAspect(_ tile: Tile) -> Bool {
        if case .image = provider.content(for: tile) { return true }
        return false
    }

    /// The one tile that shows handles: the lone selected tile, if it is visible and
    /// resizable. A multi-selection shows none — resizing several boxes at once has
    /// no single sensible meaning here.
    ///
    /// `visible` lets ``sync()`` reuse the culled set it already computed; the
    /// selection check comes first so the common no-selection case costs nothing.
    private func handleTile(in visible: [Tile]? = nil) -> Tile? {
        guard let id = selectedTileID else { return nil }
        guard let tile = (visible ?? currentVisibleTiles()).first(where: { $0.id == id }),
              isResizable(tile)
        else { return nil }
        return tile
    }

    /// The resize handle under `screenPoint`, with the tile it belongs to, or `nil`.
    /// The host calls this at `mouseDown` BEFORE its tile hit-test, so a press on a
    /// handle starts a resize rather than a move.
    public func resizeHandle(atScreenPoint screenPoint: CGPoint) -> (tileID: Int, handle: ResizeHandle)? {
        guard let tile = handleTile() else { return nil }
        let screenFrame = transform.worldToScreen(displayWorldFrame(for: tile))
        // The box being edited yields most of its grab zone to the caret (062 keeps
        // resize-while-editing, so it yields SOME rather than all of it).
        let hitSize = tile.id == editingTileID
            ? ResizeGeometry.editingHitSize : ResizeGeometry.handleHitSize
        guard let handle = ResizeGeometry.handle(
            atScreenPoint: screenPoint, in: screenFrame, hitSize: hitSize) else {
            return nil
        }
        return (tile.id, handle)
    }

    /// Begin live-resizing `tileID` by `handle`. Nothing moves until
    /// ``updateResize(toWorldPoint:)``.
    public func beginResize(tileID: Int, handle: ResizeHandle) {
        guard let tile = tile(withID: tileID) else { return }
        // A ⌘G wash still up when a handle is grabbed is stale by definition: it names
        // what some OTHER rect adopted, and the highlight is about to start naming what
        // THIS one will. Retract it here rather than letting the first tick overwrite
        // it, so the wash can never be read as a statement about the frame being
        // dragged — and so its timer cannot fire mid-resize and clear the live preview
        // out from under the gesture (100 · P3).
        retractMembershipWash()
        resizeTileID = tileID
        activeResizeHandle = handle
        resizeOriginalFrame = tile.worldFrame
        resizeWorldFrame = tile.worldFrame
    }

    /// Update the live resize to the cursor's current WORLD point. Recomputed from
    /// the frame captured at `beginResize`, never accumulated.
    ///
    /// `constrainRatio` is the ⇧ modifier; an image adds its own permanent lock on
    /// top. `snapping` is ON by default and the host clears it for ⌘ — the same
    /// "hold ⌘ to place it exactly where I say" escape the move gesture offers.
    public func updateResize(
        toWorldPoint world: CGPoint, constrainRatio: Bool = false, snapping: Bool = true
    ) {
        guard let id = resizeTileID, let handle = activeResizeHandle,
              let tile = tile(withID: id) else { return }

        let keepRatio = constrainRatio || locksAspect(tile)
        let candidates = snapping ? snapCandidates(excluding: id) : []
        let threshold = CanvasSnapping.worldThreshold(scale: transform.scale)
        var guides: [SnapGuide] = []
        var frame: CGRect

        if keepRatio {
            // Ratio-locked: the point can't be nudged without breaking the ratio, so
            // the whole frame is scaled about its anchor onto the target instead.
            let aspect = resizeOriginalFrame.height > 0
                ? resizeOriginalFrame.width / resizeOriginalFrame.height : 1
            frame = ResizeGeometry.resizedFrame(
                resizeOriginalFrame, handle: handle, toWorldPoint: world,
                keepRatio: true, aspect: aspect)
            if snapping {
                let snapped = CanvasSnapping.snapAspectFrame(
                    frame, handle: handle, candidates: candidates, threshold: threshold)
                frame = snapped.frame
                guides = snapped.guides
            }
        } else {
            // Free: snap the dragged point itself, then build the frame from it.
            var target = world
            if snapping {
                let snapped = CanvasSnapping.snapPoint(
                    world, handle: handle, candidates: candidates, threshold: threshold)
                target = snapped.point
                guides = snapped.guides
            }
            frame = ResizeGeometry.resizedFrame(
                resizeOriginalFrame, handle: handle, toWorldPoint: target)
        }

        activeSnapGuides = guides
        let live = fittedFrame(frame, for: tile)
        resizeWorldFrame = live
        // Ask the provider what this rect would contain — never re-derive it here,
        // or the promise could drift from what a later drag actually carries.
        prospectiveMemberIDs = Set(provider.groupMembers(forTileID: id, in: live))
        sync()
        onLiveFrameChanged?()
    }

    /// The world frames a resize may snap to: every VISIBLE tile except the one
    /// being resized. Visible rather than all — snapping to a box the user cannot
    /// see would look like the drag sticking for no reason, and it keeps the scan
    /// bounded by the viewport rather than by the size of the board.
    private func snapCandidates(excluding id: Int) -> [CGRect] {
        currentVisibleTiles().filter { $0.id != id }.map(\.worldFrame)
    }

    /// A text tile's frame with its HEIGHT re-derived from the text wrapped to that
    /// frame's width; anything else is returned untouched.
    ///
    /// This is the same rule the app applies when the drag commits, applied on every
    /// tick so the preview cannot disagree with the result. Without it a resize
    /// looks wrong in a specific way: narrowing a box makes the text wrap onto more
    /// lines, but the box would keep its old height for the whole drag and only jump
    /// to the right size on release. It also means a vertical drag has no lasting
    /// effect on a text box — the height is the text's, never the pointer's — which
    /// is the behaviour, not an accident of it.
    private func fittedFrame(_ frame: CGRect, for tile: Tile) -> CGRect {
        guard case .text(let style) = provider.content(for: tile) else { return frame }
        let inset = TextMetrics.padding
        let shaped = TextShaper.shape(style, maxWidth: max(1, frame.width - 2 * inset))
        return CGRect(
            x: frame.minX, y: frame.minY,
            width: frame.width, height: shaped.size.height + 2 * inset)
    }

    /// The resized tile and its current live world frame, or `nil` when idle.
    /// **Non-mutating** — the host persists this, then calls ``endResize()``, mirroring
    /// the drag path's `currentDragOrigins()` / `endDrag()` ordering so the tile never
    /// snaps back between the write and the next sync.
    public func currentResizeFrame() -> (tileID: Int, worldFrame: CGRect)? {
        guard let id = resizeTileID, let frame = resizeWorldFrame else { return nil }
        return (id, frame)
    }

    /// Clear the live-resize state, WITHOUT syncing.
    ///
    /// Notifies ``onLiveFrameChanged`` on the way out: the host calls this AFTER
    /// handing the final frame to the app, so the displayed frame here is the
    /// committed one, and a listener that tracked the drag needs to land on it
    /// rather than on the last mid-drag tick.
    public func endResize() {
        resizeTileID = nil
        activeResizeHandle = nil
        resizeOriginalFrame = .zero
        resizeWorldFrame = nil
        activeSnapGuides = []
        prospectiveMemberIDs = []
        onLiveFrameChanged?()
    }

    // MARK: Membership wash (the second driver — 100 · P3)

    /// How long a ⌘G wash stays up.
    ///
    /// The first duration this package has ever needed: everything else here is either
    /// per-frame (the host's display link drives it) or bounded by a gesture the user
    /// is holding, so there was no existing constant to reuse rather than invent.
    ///
    /// Chosen against the two failure modes, which pull in opposite directions. Too
    /// short and it is missed: ⌘G puts a new frame on the board, the eye goes to the
    /// frame, and an adopted tile is BY DEFINITION somewhere the user was not looking —
    /// so the wash has to survive a saccade and a scan of the frame's interior, not
    /// just a glance. Too long and it stops reading as a report and starts reading as a
    /// mode, something the board is now in and that the user should perhaps dismiss;
    /// past a couple of seconds a persistent fill on unselected tiles invites exactly
    /// the wrong question ("are those selected?"), which is the confusion the fill-not-
    /// border choice (062 §6) exists to avoid. 1.2s sits between the two: long enough
    /// to be caught out of the corner of the eye and then actually looked at, short
    /// enough that it is plainly over before the next gesture.
    public static let membershipWashDuration: Duration = .milliseconds(1200)

    /// Wash `ids` as members for `duration`, then clear. The second driver of the
    /// highlight the resize preview already owns (100 §5): same set, same layer pool,
    /// same fill — the drawing code does not know which gesture raised it.
    ///
    /// ⌘G creates a frame at the selection's bounding box, and a bounding box adopts
    /// whatever else happens to sit between the tiles you picked (100 §3). This is how
    /// the user is told. Only the ADOPTED tiles are passed, never the whole membership:
    /// washing everything would say "here is what is in the frame", which is visible
    /// from the frame itself, while washing the adopted ones says "here is what you did
    /// not ask for" — the only new information the gesture produced.
    ///
    /// **An empty set is a total no-op** — no sync, no timer, and deliberately no clear
    /// of a wash already up. It is the common case (the selection usually IS the
    /// membership) and it must be silent: having nothing to report is not the same as
    /// retracting an earlier report.
    ///
    /// **A live resize outranks it.** The two drivers share one field because the
    /// highlight can only mean one thing at a time, so precedence has to be decided
    /// rather than raced, and it goes to the resize in both directions: this refuses to
    /// raise while a handle is being dragged (that preview is a promise about a rect
    /// the user is actively aiming, and this one is a retrospective note about a rect
    /// they already committed), and ``beginResize(tileID:handle:)`` retracts a standing
    /// wash on the way in. Cancelling the expiry there is the load-bearing half: a
    /// timer left running would fire mid-drag and blank a preview it knows nothing
    /// about.
    ///
    /// Syncs immediately rather than waiting for the next frame. The adopted tiles
    /// already exist — ⌘G creates only the frame — so there is nothing to wait for, and
    /// the caller's own reload is an async round trip whose length would otherwise eat
    /// an unpredictable slice of the duration.
    public func washMembership(_ ids: Set<Int>, for duration: Duration = membershipWashDuration) {
        guard !ids.isEmpty, resizeTileID == nil else { return }
        membershipWashExpiry?.cancel()
        prospectiveMemberIDs = ids
        sync()
        membershipWashExpiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Both checks matter. `Task.sleep` throws on a cancel that lands while it
            // is suspended, but a cancel racing the wake-up leaves the body to run with
            // the flag already set — and by then the field belongs to whoever cancelled
            // us, so clearing it would be exactly the stomp this guards against.
            guard !Task.isCancelled, let self else { return }
            self.prospectiveMemberIDs = []
            self.membershipWashExpiry = nil
            self.sync()
        }
    }

    /// Take the wash down NOW, because a gesture with a stronger claim on the highlight
    /// is starting. Syncs only if something was actually drawn, so the common path
    /// (grabbing a handle with no wash up) costs a set comparison and nothing else.
    private func retractMembershipWash() {
        membershipWashExpiry?.cancel()
        membershipWashExpiry = nil
        guard !prospectiveMemberIDs.isEmpty else { return }
        prospectiveMemberIDs = []
        sync()
    }

    /// The snap guides currently shown — introspection for the tests.
    public var snapGuides: [SnapGuide] { activeSnapGuides }

    /// The tiles currently washed as members — introspection for the tests, and the
    /// set the highlight is drawn from. What a resize will contain on release (062),
    /// or what a ⌘G frame just adopted (100 §5); the field does not record which,
    /// because the drawing does not distinguish them either.
    public var prospectiveMembers: Set<Int> { prospectiveMemberIDs }

    /// Whether handle dots are currently drawn — introspection for the tests.
    public var resizeHandleCount: Int { handleLayers.count }

    /// Where each handle dot is actually DRAWN, in screen points. Distinct from
    /// ``resizeHandle(atScreenPoint:)``, which reports where a handle would be hit:
    /// the two can disagree if the chrome goes stale, and only this one catches it.
    public var resizeHandlePositions: [ResizeHandle: CGPoint] {
        handleLayers.mapValues(\.position)
    }

    /// Frames all content to fit the viewport (with fractional `padding` on each
    /// side), centred. The host calls this once on first layout so the canvas
    /// opens *over* the tiles instead of on empty world space. No-op if the
    /// viewport is empty or there are no drawable tiles.
    /// Whether any tile would actually be framed — the precondition
    /// ``frameToContent(padding:)`` silently needs, hoisted so a caller can tell
    /// "framed it" from "did nothing" without inspecting the transform afterwards.
    public var hasDrawableContent: Bool {
        provider.tiles.contains { !$0.isDegenerate }
    }

    /// The union of every drawable tile's world frame, or `nil` when the board has
    /// nothing to draw.
    ///
    /// Hoisted out of ``frameToContent(padding:)`` so the restore path's
    /// "is anything on screen" test (``showsContent(under:)``) measures against
    /// EXACTLY the bounds the fit would use. Two copies of this union would be two
    /// definitions of where the content is, and the fallback's whole job is to
    /// agree with the fit it falls back to.
    public var contentWorldBounds: CGRect? {
        var content: CGRect?
        for tile in provider.tiles where !tile.isDegenerate {
            content = content.map { $0.union(tile.worldFrame) } ?? tile.worldFrame
        }
        return content
    }

    public func frameToContent(padding: CGFloat = 0.1) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        guard let bounds = contentWorldBounds, bounds.width > 0, bounds.height > 0 else { return }

        let usableWidth = viewportSize.width * max(0.01, 1 - padding * 2)
        let usableHeight = viewportSize.height * max(0.01, 1 - padding * 2)
        let fitScale = min(usableWidth / bounds.width, usableHeight / bounds.height)

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let viewportCentre = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        // CanvasTransform clamps fitScale into range; recompute translation from
        // the *clamped* scale so the content stays centred even at a zoom limit.
        let framed = CanvasTransform(
            scale: fitScale,
            translation: .zero,
            minScale: transform.minScale,
            maxScale: transform.maxScale
        )
        let translation = CGPoint(
            x: viewportCentre.x - centre.x * framed.scale,
            y: viewportCentre.y - centre.y * framed.scale
        )
        setTransform(CanvasTransform(
            scale: framed.scale,
            translation: translation,
            minScale: transform.minScale,
            maxScale: transform.maxScale
        ))
    }

    // MARK: - Camera restore (018 · Cluster C)

    /// The camera the current transform expresses — what a caller persists so the
    /// board can be reopened here. Window-independent; see ``CanvasCamera``.
    public var camera: CanvasCamera { transform.camera(viewportSize: viewportSize) }

    /// Whether opening at `camera` would put any content on screen: a pure
    /// intersection of the restored viewport rect against ``contentWorldBounds``.
    ///
    /// Deliberately a plain intersects-or-not, NOT a "clamp until some fraction is
    /// visible" threshold. A threshold has to invent a number, and every number it
    /// could invent would silently move a camera the user deliberately parked —
    /// panning to blank space next to your work is a legitimate place to be. The
    /// only state worth refusing to restore is the one that reads as data loss: an
    /// empty grey void with the board nowhere in it.
    public func showsContent(under camera: CanvasCamera) -> Bool {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let bounds = contentWorldBounds else { return false }
        return transform
            .settingCamera(camera, viewportSize: viewportSize)
            .visibleWorldRect(viewportSize: viewportSize)
            .intersects(bounds)
    }

    /// Open the board at `camera`, or fit its content when there is nothing usable
    /// to open at. ONE rule with ONE fallback (018 · Cluster C), covering:
    ///
    /// - `camera == nil` — never saved, or saved as a blob that no longer decodes
    ///   (the caller resolves both to `nil` before calling).
    /// - a camera whose restored viewport intersects NO content — the board would
    ///   open on empty world space, which reads as the board having been lost.
    ///
    /// The fallback is ``frameToContent(padding:)``, which is already the correct
    /// first-open behaviour and stays correct for a stale camera. Returns whether
    /// the saved camera was used, so a caller can tell "restored" from "re-fitted"
    /// without inspecting the transform afterwards.
    ///
    /// Routes through ``setTransform(_:)`` like every other camera mutation, so a
    /// restore notifies ``onTransformChanged`` exactly once.
    @discardableResult
    public func restoreCamera(_ camera: CanvasCamera?, padding: CGFloat = 0.1) -> Bool {
        guard let camera, showsContent(under: camera) else {
            frameToContent(padding: padding)
            return false
        }
        setTransform(transform.settingCamera(camera, viewportSize: viewportSize))
        return true
    }

    // MARK: The per-frame sync

    /// Reconciles the layer tree with the current transform. Cheap by design:
    /// only culled-visible tiles touch a layer; everything else is recycled.
    public func sync() {
        syncCount &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit per-frame animations
        defer { CATransaction.commit() }

        let visible = currentVisibleTiles()
        let visibleIDs = Set(visible.map(\.id))

        // Recycle layers for tiles that left the viewport (+ drop their badges
        // and any vector text overlay — both live outside the recycled pool).
        for (id, layer) in active where !visibleIDs.contains(id) {
            pool.recycle(layer)
            active[id] = nil
            keyByTile[id] = nil
            badges[id]?.removeFromSuperlayer()
            badges[id] = nil
            textLayers[id]?.removeFromSuperlayer()
            textLayers[id] = nil
            selectionLayers[id]?.removeFromSuperlayer()
            selectionLayers[id] = nil
        }

        // Place / update layers for visible tiles.
        var neededKeys = Set<ThumbnailCache.Key>()
        for tile in visible {
            let layer: CALayer
            if let existing = active[tile.id] {
                layer = existing
            } else {
                layer = pool.obtain()
                rootLayer.addSublayer(layer)
                active[tile.id] = layer
            }

            let screenFrame = transform.worldToScreen(displayWorldFrame(for: tile))
            layer.frame = screenFrame
            layer.zPosition = CGFloat(tile.z)
            updateBadge(for: tile, screenFrame: screenFrame)
            updateSelectionHighlight(for: tile, screenFrame: screenFrame)

            switch provider.content(for: tile) {
            case .image:
                clearVectorStyling(layer)
                setTextOverlay(nil, for: tile, screenFrame: screenFrame, worldPadded: false)
                paintImage(tile: tile, layer: layer, neededKeys: &neededKeys)
            case .frame(let style):
                // A frame draws directly on its (non-recycled-content) pooled
                // layer — no decode, no cache key (so applyDecoded/retain skip it).
                keyByTile[tile.id] = nil
                layer.contents = nil
                applyFrameStyling(layer, style: style)
                setTextOverlay(style.label, for: tile, screenFrame: screenFrame, worldPadded: false)
            case .text(let style):
                keyByTile[tile.id] = nil
                layer.contents = nil
                clearVectorStyling(layer) // transparent base; glyphs ride the overlay
                // While an app-layer inline editor owns this tile (2B · 054 §5.2),
                // blank the CATextLayer so the live NSTextView glyphs aren't doubled.
                let overlay = tile.id == editingTileID ? nil : style
                setTextOverlay(overlay, for: tile, screenFrame: screenFrame, worldPadded: true)
            }
        }

        // Resize handles ride on top of the selection border, once per sync (they
        // belong to at most ONE tile, so they are not part of the per-tile loop).
        updateResizeHandles(in: visible)
        updateSnapGuides()
        updateMembershipHighlights(in: visible)

        // Drop decodes whose tiles are no longer needed (decision P15).
        scheduler.retainOnly(neededKeys)
    }

    /// Show / move / drop the four CORNER dots on the single selected resizable
    /// tile. Sized in SCREEN points, so they stay the same physical size at every
    /// zoom — the whole reason the hit-test lives in screen space too.
    ///
    /// Only the corners are drawn; the edge handles keep their grab zones but no
    /// dot — an edge is its own affordance, and a dot on a short text box's edge
    /// midpoint sat on top of the text it resizes. The box being EDITED draws no
    /// dots at all (its border is chrome enough over live text), though its
    /// reduced grab zones stay live — resize-while-editing (062) is undrawn, not
    /// gone.
    private func updateResizeHandles(in visible: [Tile]) {
        guard let tile = handleTile(in: visible), tile.id != editingTileID else {
            for layer in handleLayers.values { layer.removeFromSuperlayer() }
            handleLayers.removeAll()
            return
        }
        let screenFrame = transform.worldToScreen(displayWorldFrame(for: tile))
        let size = ResizeGeometry.handleSize
        for (handle, centre) in ResizeGeometry.handleCentres(in: screenFrame)
        where handle.isCorner {
            let layer: CALayer
            if let existing = handleLayers[handle] {
                layer = existing
            } else {
                layer = makeHandleLayer()
                handleLayers[handle] = layer
            }
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.position = centre
            layer.cornerRadius = size / 2
            layer.zPosition = Self.chromeZ // above the selection border
        }
    }

    /// Draw the snap guides spanning the viewport. A guide is a world-space LINE,
    /// so only its position maps through the transform — its length is simply the
    /// viewport, and its thickness stays 1 screen point at any zoom.
    private func updateSnapGuides() {
        guard !activeSnapGuides.isEmpty else {
            for layer in guideLayers { layer.removeFromSuperlayer() }
            guideLayers.removeAll()
            return
        }
        while guideLayers.count < activeSnapGuides.count { guideLayers.append(makeGuideLayer()) }
        while guideLayers.count > activeSnapGuides.count {
            guideLayers.removeLast().removeFromSuperlayer()
        }
        for (layer, guide) in zip(guideLayers, activeSnapGuides) {
            let origin = transform.worldToScreen(
                CGPoint(x: guide.position, y: guide.position))
            layer.frame = guide.isVertical
                ? CGRect(x: origin.x, y: 0, width: 1, height: viewportSize.height)
                : CGRect(x: 0, y: origin.y, width: viewportSize.width, height: 1)
            // Set every time rather than only at creation: the pool recycles layers
            // between guides, so a layer that drew an equal-spacing line last tick
            // would keep its alpha for an alignment line this one (099 · P12).
            layer.backgroundColor = guide.kind == .equalSpacing
                ? CanvasChrome.equalSpacingGuide : CanvasChrome.snapGuide
            layer.zPosition = Self.chromeZ
        }
    }

    /// Wash the tiles a resizing frame is about to contain. Deliberately a FILL
    /// rather than a border: the selection highlight already owns the border idiom,
    /// and these tiles are not selected — conflating the two would read as "these
    /// are selected too", which is exactly the wrong message.
    private func updateMembershipHighlights(in visible: [Tile]) {
        guard !prospectiveMemberIDs.isEmpty else {
            for layer in membershipLayers.values { layer.removeFromSuperlayer() }
            membershipLayers.removeAll()
            return
        }
        var stale = Set(membershipLayers.keys)
        for tile in visible where prospectiveMemberIDs.contains(tile.id) {
            stale.remove(tile.id)
            let layer: CALayer
            if let existing = membershipLayers[tile.id] {
                layer = existing
            } else {
                layer = makeMembershipLayer()
                membershipLayers[tile.id] = layer
            }
            layer.frame = transform.worldToScreen(displayWorldFrame(for: tile))
            layer.zPosition = Self.chromeZ
        }
        // A tile that left the viewport (or the frame) gives its wash back.
        for id in stale {
            membershipLayers[id]?.removeFromSuperlayer()
            membershipLayers[id] = nil
        }
    }

    private func makeMembershipLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = CanvasChrome.membershipWash
        layer.cornerRadius = 3
        rootLayer.addSublayer(layer)
        return layer
    }

    private func makeGuideLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = CanvasChrome.snapGuide
        rootLayer.addSublayer(layer)
        return layer
    }

    private func makeHandleLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = CanvasChrome.handleFill
        layer.borderColor = CanvasChrome.handleBorder
        layer.borderWidth = 1.5
        rootLayer.addSublayer(layer)
        return layer
    }

    /// Synchronously decode the current visible set into the cache. One-time
    /// benchmark warming only — keeps async decode out of the measured frame.
    public func warmVisibleBlocking() {
        for tile in currentVisibleTiles() {
            let onScreenEdge = CGFloat(tile.longestWorldEdge) * transform.scale
            let tier = lod.tier(forOnScreenLongestEdge: onScreenEdge, previous: keyByTile[tile.id]?.tier)
            let key = ThumbnailCache.Key(imageID: images.imageKey(for: tile), tier: tier)
            guard cache.image(for: key) == nil else { continue }
            let data: Data?
            if let url = images.imageFileURL(for: tile, tier: tier) {
                data = try? Data(contentsOf: url)
            } else {
                data = images.imageData(for: tile, tier: tier)
            }
            guard let data else { continue }
            if let image = DecodeScheduler.decodeBlocking(
                data: data,
                maxPixelSize: Self.pixelSize(for: tier)
            ) {
                cache.insert(image, for: key)
            }
        }
    }

    // MARK: -

    /// Paints every active tile currently bound to `key` once it has decoded.
    private func applyDecoded(_ key: ThumbnailCache.Key) {
        guard let image = cache.image(for: key) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in active where keyByTile[id] == key {
            layer.contents = image
        }
        CATransaction.commit()
    }

    // MARK: Content painting (image path + vector elements)

    /// The image path (decision T3, untouched): pick an LOD tier, paint from the
    /// cache, and request an off-main decode on a miss. Records the tile's cache
    /// key so ``applyDecoded(_:)`` can back-fill it and ``sync()`` can retain it.
    private func paintImage(tile: Tile, layer: CALayer, neededKeys: inout Set<ThumbnailCache.Key>) {
        let onScreenEdge = CGFloat(tile.longestWorldEdge) * transform.scale
        let previous = keyByTile[tile.id]?.tier
        // Tiers are FROZEN for the duration of a pinch (086 · Phase 1). A zoom sweep
        // crosses tier boundaries, and each crossing asks for a decode the next event
        // may cancel — `LODPolicy`'s hysteresis narrows that band but cannot close it,
        // because the zoom does not oscillate around a boundary, it travels through
        // one. So a tile that already has a tier keeps it until the fingers lift, and
        // ``endZoomGesture()`` re-tiers everything once.
        //
        // A tile that has NO tier yet is not frozen: it just entered the viewport and
        // freezing it would mean freezing it blank.
        let tier = isZoomGestureActive && previous != nil
            ? previous!
            : lod.tier(forOnScreenLongestEdge: onScreenEdge, previous: previous)
        let key = ThumbnailCache.Key(imageID: images.imageKey(for: tile), tier: tier)
        keyByTile[tile.id] = key
        neededKeys.insert(key)

        if let image = cache.image(for: key) {
            layer.contents = image
        } else if let url = images.imageFileURL(for: tile, tier: tier) {
            // Disk-backed: file read + decode both leave the main thread (G7).
            scheduler.request(key: key, maxPixelSize: Self.pixelSize(for: tier)) {
                try? Data(contentsOf: url)
            }
        } else if let data = images.imageData(for: tile, tier: tier) {
            scheduler.request(
                key: key,
                data: data,
                maxPixelSize: Self.pixelSize(for: tier)
            )
        }
    }

    /// Reset a pooled layer's vector styling so a layer reused from a frame (or
    /// carrying stale border/fill) draws a clean image / transparent text base.
    private func clearVectorStyling(_ layer: CALayer) {
        layer.borderWidth = 0
        layer.borderColor = nil
        layer.backgroundColor = nil
        layer.cornerRadius = 0
    }

    /// Draw a `.frame` element on its pooled layer: fill + a world-thickness border
    /// (scaled to screen) + rounded corners. No decode — it's pure CA compositing.
    private func applyFrameStyling(_ layer: CALayer, style: FrameStyle) {
        layer.backgroundColor = style.fill?.cgColor
        if let stroke = style.stroke, style.strokeWidth > 0 {
            layer.borderColor = stroke.cgColor
            layer.borderWidth = CGFloat(style.strokeWidth) * transform.scale
        } else {
            layer.borderColor = nil
            layer.borderWidth = 0
        }
        layer.cornerRadius = CGFloat(max(0, style.cornerRadius)) * transform.scale
    }

    /// Show / update / hide a tile's `CATextLayer` overlay (a `.text` element's
    /// glyphs or a frame's label). Sized in on-screen points from a world font
    /// size, so it stays crisp at any zoom. `nil` / empty removes the overlay.
    ///
    /// `worldPadded` picks the inset policy (054 §4.4 · R12): a `.text` tile uses a
    /// **world-space** pad (``TextMetrics/padding`` `× scale`) so its drawn inset
    /// equals the world-space inset the app measured against at EVERY zoom; a frame
    /// label keeps the legacy **screen-space** pad (frames aren't auto-sized, so
    /// their labels stay byte-identical).
    private func setTextOverlay(_ style: TextStyle?, for tile: Tile, screenFrame: CGRect, worldPadded: Bool) {
        guard let style, !style.string.isEmpty else {
            removeTextOverlay(tile.id)
            return
        }
        // Inset a touch so glyphs don't kiss the tile edge. A `.text` tile insets by
        // the world-space measurement pad (`× scale`) so draw ≡ measure at any zoom;
        // a frame label keeps the legacy screen-space pad (054 §4.4).
        let pad = worldPadded
            ? TextMetrics.padding * transform.scale
            : min(6, screenFrame.width * 0.04)
        let frame = screenFrame.insetBy(dx: pad, dy: pad)
        let z = CGFloat(tile.z) + 0.25 // above its own tile, below its badge
        setGlyphOverlay(style, for: tile, frame: frame, worldPadded: worldPadded, zPosition: z)
    }

    /// Shape once in world space, then rasterize that layout at the current zoom.
    private func setGlyphOverlay(_ style: TextStyle, for tile: Tile, frame: CGRect,
                                 worldPadded: Bool, zPosition: CGFloat) {
        // The shaping box in WORLD units, taken from the tile's DISPLAYED world
        // frame — NOT from `frame ÷ scale`. Both would be algebraically equal for a
        // `.text` tile, but going through screen space would fold float noise from
        // the camera into the ``ShapeKey``, and a key that moves with the camera is
        // exactly the coupling this whole design removes.
        //
        // Displayed, not stored (062): a live resize changes the box the text must
        // wrap into, and shaping against the stored size would leave the glyphs laid
        // out for the OLD width for the whole drag — the box would move under text
        // that refused to reflow. ``displayWorldFrame`` is pure world arithmetic
        // (stored frame, or the live gesture's frame), so the camera still cannot
        // reach the key; only a deliberate resize can.
        //
        // A frame label subtracts no pad: its inset is a SCREEN pad (054 §4.4),
        // whose world equivalent shrinks as you zoom in, so folding it in would
        // make the label's shaping width zoom-dependent. Shaping against the full
        // world width keeps labels stable; the few points of pad only mean a very
        // long label meets the backing store's edge a touch sooner.
        let worldSize = displayWorldFrame(for: tile).size
        let inset = worldPadded ? TextMetrics.padding : 0
        // Truncate a frame LABEL, never a text TILE (062).
        //
        // A frame's box is user-controlled and owes nothing to its label, so a label
        // too long for it must be cut. A text tile is the opposite: its height is
        // DERIVED from the wrapped text, so it fits by construction and a height
        // limit can only ever hide content the model promised was visible. That
        // mattered under the old `.fixed` mode, which really could overflow; keeping
        // it now means a box whose stored height is stale — a row written before 062,
        // or one mid-migration — silently drops lines instead of showing its text.
        // Overflowing briefly is recoverable; invisible text is not.
        let maxHeight = worldPadded ? nil : max(1, worldSize.height - 2 * inset)
        let shaped = TextShaper.shape(
            style,
            maxWidth: max(1, worldSize.width - 2 * inset),
            maxHeight: maxHeight)

        let layer: TextRenderLayer
        if let existing = textLayers[tile.id] {
            layer = existing
        } else {
            layer = TextRenderLayer()
            textLayers[tile.id] = layer
            rootLayer.addSublayer(layer)
        }
        layer.contentsScale = max(1, backingScale)
        layer.setShaped(shaped)
        let (clamped, worldOffset) = clampedTextFrame(frame)
        layer.apply(scale: transform.scale, color: style.color.cgColor, worldOffset: worldOffset)
        layer.frame = clamped
        layer.zPosition = zPosition
    }

    /// 060 §2 backing-store cap. A text box zoomed deep enough is far bigger than
    /// the screen, and a layer's backing store is a GPU texture: past roughly
    /// 8192 px on a side it degrades silently, and its memory grows with zoom².
    /// Only oversized layers are clamped — everything at ordinary zooms keeps its
    /// full frame, so a pan leaves `bounds.size` untouched and re-rasterizes
    /// nothing. Returns the clamped frame plus how far into the layout its
    /// top-left now sits, in world units.
    private func clampedTextFrame(_ frame: CGRect) -> (frame: CGRect, worldOffset: CGPoint) {
        guard viewportSize.width > 0, viewportSize.height > 0, transform.scale > 0 else {
            return (frame, .zero)
        }
        // Slack keeps a margin of off-screen text rasterized, so nudging the pan
        // doesn't reveal a blank edge.
        let slack: CGFloat = 512
        let window = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -slack, dy: -slack)
        guard frame.width > window.width || frame.height > window.height else {
            return (frame, .zero)
        }
        let clamped = frame.intersection(window)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
            // Entirely outside the window (the tile is in the prefetch ring):
            // keep the layer, give it no backing store.
            return (CGRect(origin: frame.origin, size: .zero), .zero)
        }
        return (clamped, CGPoint(
            x: (clamped.minX - frame.minX) / transform.scale,
            y: (clamped.minY - frame.minY) / transform.scale))
    }

    /// Drop a tile's text overlay.
    private func removeTextOverlay(_ id: Int) {
        textLayers[id]?.removeFromSuperlayer()
        textLayers[id] = nil
    }

    /// Number of text overlays currently attached (introspection for E3 tests —
    /// mirrors the badge-count checks the video tests use).
    public var textOverlayCount: Int { textLayers.count }

    /// The text overlay for a tile, if attached. Introspection for the E3 / 2A /
    /// 060 tests, so it is internal — the layer type is a renderer detail no app
    /// caller should reach for (none does). Mirrors ``textOverlayCount``.
    func textLayer(forTileID id: Int) -> TextRenderLayer? { textLayers[id] }

    // MARK: Badges + hit-testing

    /// Show / size / hide a tile's badge overlay for the current frame. The badge
    /// is a fixed-ish screen size centred on the tile, hidden when the tile is too
    /// small on screen to badge legibly.
    private func updateBadge(for tile: Tile, screenFrame: CGRect) {
        let shorter = min(screenFrame.width, screenFrame.height)
        let size = min(48, shorter * 0.42)
        guard provider.badge(for: tile) == .play, size >= 16 else {
            badges[tile.id]?.removeFromSuperlayer()
            badges[tile.id] = nil
            return
        }
        let badge: CALayer
        if let existing = badges[tile.id] {
            badge = existing
        } else {
            badge = CALayer()
            badge.contents = playBadgeImage
            badge.contentsGravity = .resizeAspect
            badges[tile.id] = badge
            rootLayer.addSublayer(badge)
        }
        badge.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        badge.position = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        badge.zPosition = CGFloat(tile.z) + 0.5 // above its own tile
    }

    /// Whether ANY selection highlight is currently drawn (at least one selected
    /// tile is visible in the viewport). Introspection for the invariant tests.
    public var isSelectionHighlightVisible: Bool { !selectionLayers.isEmpty }

    /// The number of highlight layers currently attached — must stay bounded by the
    /// viewport (visible ∩ selected), never grow with the selection size (049 · D16
    /// / D12 tests).
    public var selectionHighlightCount: Int { selectionLayers.count }

    /// Show / position / drop `tile`'s highlight border for this frame. A selected
    /// AND visible tile gets a border framing its (drag-offset-aware) screen frame;
    /// a tile that isn't selected drops any highlight it still carries. Managed like
    /// ``badges`` — a per-tile sibling layer outside the recycled pool, kept above
    /// all tiles + badges. The dragged tile's `screenFrame` already includes the
    /// live-drag offset, so the highlight follows a drag with no extra bookkeeping.
    private func updateSelectionHighlight(for tile: Tile, screenFrame: CGRect) {
        guard selectedTileIDs.contains(tile.id) else {
            selectionLayers[tile.id]?.removeFromSuperlayer()
            selectionLayers[tile.id] = nil
            return
        }
        let layer: CALayer
        if let existing = selectionLayers[tile.id] {
            layer = existing
        } else {
            layer = makeSelectionLayer()
            selectionLayers[tile.id] = layer
        }
        layer.frame = screenFrame.insetBy(dx: -Self.selectionInset, dy: -Self.selectionInset)
        layer.zPosition = Self.chromeZ // always on top
    }

    private func makeSelectionLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1.5
        layer.borderColor = CanvasChrome.selection
        layer.cornerRadius = 3
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0) // border only
        rootLayer.addSublayer(layer)
        return layer
    }

    /// Screen-point outset of the highlight beyond the tile edge (so the border
    /// frames the image rather than covering it).
    private static let selectionInset: CGFloat = 2

    /// `zPosition` for chrome that must draw above every tile — the selection border,
    /// the resize handles, the snap guides, the membership wash, the create preview.
    ///
    /// A real number rather than `.greatestFiniteMagnitude`, which is what these all
    /// used to be. `zPosition` is a `CGFloat`, so its greatest finite value is a
    /// `Double`'s (~1.8e308), while Core Animation validates the property against
    /// **FLT_MAX** (~3.4e38) — every one of those assignments logged "zPosition
    /// should be within (-FLT_MAX, FLT_MAX) range" and was clamped anyway. A million
    /// is above any tile's z (a row index) by every margin that matters.
    static let chromeZ: CGFloat = 1_000_000

    /// The topmost visible tile whose on-screen frame contains `screenPoint`, or
    /// `nil`. Used by the host view to resolve a click to an asset.
    public func tile(atScreenPoint screenPoint: CGPoint) -> Tile? {
        currentVisibleTiles()
            .filter { transform.worldToScreen(displayWorldFrame(for: $0)).contains(screenPoint) }
            .max { $0.z < $1.z }
    }

    /// The ids of every tile whose stored world frame intersects the marquee's
    /// `worldRect` (049 · D2 / D14 — rubber-band selection). Hit-tests **all**
    /// provider tiles, offscreen included — NOT just the culled-visible set — so a
    /// marquee that grows under edge auto-pan still catches tiles the viewport has
    /// not reached (a visible-only test would be fast but wrong at the edges). It
    /// is z-independent (a box selects tiles at any stacking order) and skips
    /// degenerate tiles (the culler drops them too). O(N) per call at board scale
    /// — no spatial index (premature here). Pure + window-free, so the hit contract
    /// is unit-testable like the grid's `marqueeIndices`.
    public func tiles(inWorldRect worldRect: CGRect) -> Set<Int> {
        var hits = Set<Int>()
        for tile in provider.tiles where !tile.isDegenerate {
            if Self.marqueeIntersects(worldRect, tile.worldFrame) { hits.insert(tile.id) }
        }
        return hits
    }

    /// Overlap between a marquee rect `a` and a tile frame `b`, boundary-aware —
    /// the SAME rule the grid's `MarqueeMath.rectsIntersect` uses (replicated here,
    /// not shared, to keep this package dependency-free — the predicate is five
    /// lines and the two live in different modules):
    ///
    /// - A marquee WITH area uses STRICT overlap, so a drag stopping exactly on a
    ///   tile edge doesn't sweep that neighbour in.
    /// - A degenerate marquee (zero-area / axis-aligned thin, `isEmpty`) falls back
    ///   to edge-INCLUSIVE overlap so it still registers the tile it lands inside
    ///   (`CGRect.intersects` is false for a zero-area rect).
    static func marqueeIntersects(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.isEmpty {
            return a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
        }
        return a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// Render the ▶ glyph once: a white triangle in a translucent dark disc.
    private static func makePlayBadgeImage() -> CGImage? {
        let side = 128
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let s = CGFloat(side)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: 6, dy: 6))

        // Triangle nudged right of centre so it looks optically centred.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.move(to: CGPoint(x: s * 0.40, y: s * 0.30))
        ctx.addLine(to: CGPoint(x: s * 0.40, y: s * 0.70))
        ctx.addLine(to: CGPoint(x: s * 0.72, y: s * 0.50))
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Target decoded pixel size (longest edge) per LOD tier.
    static func pixelSize(for tier: LODTier) -> Int {
        switch tier {
        case .low: return 128
        case .medium: return 512
        case .full: return 1280
        }
    }
}
