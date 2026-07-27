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

    /// The tile whose text an app-layer inline editor currently owns (2B · 054
    /// §5.2), or `nil`. While set, that tile's `.text` glyphs are BLANKED in
    /// ``sync()`` so the live `NSTextView` above it isn't doubled by the
    /// `CATextLayer` beneath. Setting it re-syncs so the blank takes effect at once.
    public var editingTileID: Int? {
        didSet {
            guard editingTileID != oldValue else { return }
            sync()
        }
    }

    private var active: [Int: CALayer] = [:]
    private var keyByTile: [Int: ThumbnailCache.Key] = [:]
    /// Badge overlay layers (e.g. the ▶ for a video), keyed by tile id — siblings
    /// of the tile layers, so they never entangle with the recycling ``LayerPool``.
    private var badges: [Int: CALayer] = [:]
    /// Text overlay layers for freeform `.text` tiles and `.frame` labels (E3),
    /// keyed by tile id — `CATextLayer` siblings OUTSIDE the recycled ``LayerPool``
    /// (decision T3), created/dropped like ``badges``. A tile has at most one.
    private var textLayers: [Int: CATextLayer] = [:]

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

    /// The on-screen frame a tile is currently drawn at — its stored world frame
    /// plus any live-drag offset, mapped through the transform — or `nil` if the
    /// tile isn't among the currently visible tiles. Mirrors the math ``sync()``
    /// uses to place each layer; introspection for the drag tests.
    public func currentScreenFrame(forTileID id: Int) -> CGRect? {
        guard let tile = currentVisibleTiles().first(where: { $0.id == id }) else { return nil }
        return transform.worldToScreen(displayWorldFrame(for: tile))
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
    public func updateDrag(byScreenDelta screenDelta: CGSize) {
        guard dragTileID != nil else { return }
        dragWorldOffset = CGSize(
            width: screenDelta.width / transform.scale,
            height: screenDelta.height / transform.scale)
        sync()
    }

    /// Finalize the live drag: return the dragged tile's FINAL world origin
    /// (stored origin + offset) and clear the drag state, WITHOUT syncing.
    ///
    /// Ordering matters (avoids a viewport reset / snap-back): the host calls
    /// this, hands the origin to the provider (an in-memory placement update),
    /// then calls ``sync()`` — by then the provider reports the new geometry and
    /// the offset is cleared, so the tile stays exactly where it was dropped.
    /// Returns `nil` when nothing was being dragged.
    public func endDrag() -> (tileID: Int, worldOrigin: CGPoint)? {
        guard let id = dragTileID, let tile = tile(withID: id) else {
            dragTileID = nil
            dragGroupIDs = []
            dragWorldOffset = .zero
            return nil
        }
        let origin = CGPoint(
            x: tile.worldFrame.origin.x + dragWorldOffset.width,
            y: tile.worldFrame.origin.y + dragWorldOffset.height)
        dragTileID = nil
        dragGroupIDs = []
        dragWorldOffset = .zero
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

    /// The world frame a tile is drawn at this frame — its stored frame, offset
    /// by the live-drag delta when it's the dragged tile or one of its group.
    private func displayWorldFrame(for tile: Tile) -> CGRect {
        guard tile.id == dragTileID || dragGroupIDs.contains(tile.id) else { return tile.worldFrame }
        return tile.worldFrame.offsetBy(dx: dragWorldOffset.width, dy: dragWorldOffset.height)
    }

    /// Frames all content to fit the viewport (with fractional `padding` on each
    /// side), centred. The host calls this once on first layout so the canvas
    /// opens *over* the tiles instead of on empty world space. No-op if the
    /// viewport is empty or there are no drawable tiles.
    public func frameToContent(padding: CGFloat = 0.1) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        var content: CGRect?
        for tile in provider.tiles where !tile.isDegenerate {
            content = content.map { $0.union(tile.worldFrame) } ?? tile.worldFrame
        }
        guard let bounds = content, bounds.width > 0, bounds.height > 0 else { return }

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

    // MARK: The per-frame sync

    /// Reconciles the layer tree with the current transform. Cheap by design:
    /// only culled-visible tiles touch a layer; everything else is recycled.
    public func sync() {
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

        // Drop decodes whose tiles are no longer needed (decision P15).
        scheduler.retainOnly(neededKeys)
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
        let tier = lod.tier(forOnScreenLongestEdge: onScreenEdge, previous: keyByTile[tile.id]?.tier)
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
            textLayers[tile.id]?.removeFromSuperlayer()
            textLayers[tile.id] = nil
            return
        }
        let text: CATextLayer
        if let existing = textLayers[tile.id] {
            text = existing
        } else {
            text = CATextLayer()
            text.isWrapped = true
            text.truncationMode = .end
            text.alignmentMode = .left
            textLayers[tile.id] = text
            rootLayer.addSublayer(text)
        }
        text.contentsScale = max(1, backingScale)
        text.string = style.string
        // Typeface is cached by (family, weight); only fontSize is per-frame (cheap).
        text.font = CanvasFont.resolve(family: style.fontFamily, weight: style.weight)
        text.fontSize = CGFloat(max(1, style.fontSize)) * transform.scale
        text.alignmentMode = style.alignment.caAlignment
        text.foregroundColor = style.color.cgColor
        // Inset a touch so glyphs don't kiss the tile edge. A `.text` tile insets by
        // the world-space measurement pad (`× scale`) so draw ≡ measure at any zoom;
        // a frame label keeps the legacy screen-space pad (054 §4.4).
        let pad = worldPadded
            ? TextMetrics.padding * transform.scale
            : min(6, screenFrame.width * 0.04)
        text.frame = screenFrame.insetBy(dx: pad, dy: pad)
        text.zPosition = CGFloat(tile.z) + 0.25 // above its own tile, below its badge
    }

    /// Number of text overlays currently attached (introspection for E3 tests —
    /// mirrors the badge-count checks the video tests use).
    public var textOverlayCount: Int { textLayers.count }

    /// The `CATextLayer` overlay for a tile, if attached (introspection for 2A
    /// tests — asserts the applied font / alignment). Mirrors ``textOverlayCount``.
    public func textLayer(forTileID id: Int) -> CATextLayer? { textLayers[id] }

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
        layer.zPosition = .greatestFiniteMagnitude // always on top
    }

    private func makeSelectionLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 3
        layer.borderColor = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0) // accent blue
        layer.cornerRadius = 3
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0) // border only
        rootLayer.addSublayer(layer)
        return layer
    }

    /// Screen-point outset of the highlight beyond the tile edge (so the border
    /// frames the image rather than covering it).
    private static let selectionInset: CGFloat = 2

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
