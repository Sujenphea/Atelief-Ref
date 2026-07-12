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

    private var active: [Int: CALayer] = [:]
    private var keyByTile: [Int: ThumbnailCache.Key] = [:]
    /// Badge overlay layers (e.g. the ▶ for a video), keyed by tile id — siblings
    /// of the tile layers, so they never entangle with the recycling ``LayerPool``.
    private var badges: [Int: CALayer] = [:]
    /// The ▶ glyph, rendered once and shared by every badge layer's `contents`.
    private lazy var playBadgeImage: CGImage? = Self.makePlayBadgeImage()

    /// The currently selected tile's id, or `nil`. Drives the selection highlight
    /// and is the target the host acts on for Delete / context-menu actions.
    public private(set) var selectedTileID: Int?
    /// The highlight border drawn around the selected tile. Created lazily on the
    /// first selection (so a canvas that's never selected keeps its exact
    /// sublayer count), then reused and hidden when there's nothing to highlight.
    private var selectionLayer: CALayer?

    /// The tile currently being live-dragged, or `nil`. While set, its world
    /// frame is displayed offset by ``dragWorldOffset`` (in ``sync()`` and
    /// hit-testing) so the tile, its badge, and the highlight follow the cursor
    /// without touching the provider until the drag ends.
    private var dragTileID: Int?
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
    }

    public func pan(byScreenDelta delta: CGSize) {
        transform = transform.panned(byScreenDelta: delta)
        sync()
    }

    public func zoom(by factor: CGFloat, aroundScreenPoint anchor: CGPoint) {
        transform = transform.zoomed(by: factor, aroundScreenPoint: anchor)
        sync()
    }

    /// Select a tile (or clear with `nil`) and redraw the highlight. Idempotent —
    /// re-selecting the same tile is a no-op, so it's cheap to call on every click.
    public func setSelected(_ id: Int?) {
        guard selectedTileID != id else { return }
        selectedTileID = id
        sync()
    }

    // MARK: Live drag (transient placement, no provider mutation)

    /// Begin live-dragging `tileID`. Records the tile and resets the offset; the
    /// tile doesn't move until ``updateDrag(byScreenDelta:)`` reports movement.
    public func beginDrag(tileID: Int) {
        dragTileID = tileID
        dragWorldOffset = .zero
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
        guard let id = dragTileID,
              let tile = provider.tiles.first(where: { $0.id == id }) else {
            dragTileID = nil
            dragWorldOffset = .zero
            return nil
        }
        let origin = CGPoint(
            x: tile.worldFrame.origin.x + dragWorldOffset.width,
            y: tile.worldFrame.origin.y + dragWorldOffset.height)
        dragTileID = nil
        dragWorldOffset = .zero
        return (id, origin)
    }

    /// The world frame a tile is drawn at this frame — its stored frame, offset
    /// by the live-drag delta when it's the tile under the drag.
    private func displayWorldFrame(for tile: Tile) -> CGRect {
        guard tile.id == dragTileID else { return tile.worldFrame }
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

        // Recycle layers for tiles that left the viewport (+ drop their badges).
        for (id, layer) in active where !visibleIDs.contains(id) {
            pool.recycle(layer)
            active[id] = nil
            keyByTile[id] = nil
            badges[id]?.removeFromSuperlayer()
            badges[id] = nil
        }

        // Place / update layers for visible tiles.
        var neededKeys = Set<ThumbnailCache.Key>()
        var selectedFrame: CGRect?
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
            if tile.id == selectedTileID { selectedFrame = screenFrame }

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

        // Draw / hide the selection highlight for this frame.
        updateSelectionHighlight(frame: selectedFrame)

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

    /// Whether the selection highlight is currently drawn (a tile is selected AND
    /// visible in the viewport). Introspection for the invariant tests.
    public var isSelectionHighlightVisible: Bool {
        selectionLayer.map { !$0.isHidden } ?? false
    }

    /// Position the highlight border around the selected tile's on-screen frame,
    /// or hide it when nothing is selected / the selected tile is off-screen. The
    /// layer is created on first use and kept above all tiles + badges.
    private func updateSelectionHighlight(frame: CGRect?) {
        guard let frame else {
            selectionLayer?.isHidden = true
            return
        }
        let layer = selectionLayer ?? makeSelectionLayer()
        selectionLayer = layer
        layer.isHidden = false
        layer.frame = frame.insetBy(dx: -Self.selectionInset, dy: -Self.selectionInset)
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
