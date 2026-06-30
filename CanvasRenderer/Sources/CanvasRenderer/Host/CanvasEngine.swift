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
    private let images: FixtureImageSet
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

    public init(
        provider: TileProvider,
        images: FixtureImageSet,
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

        // Recycle layers for tiles that left the viewport.
        for (id, layer) in active where !visibleIDs.contains(id) {
            pool.recycle(layer)
            active[id] = nil
            keyByTile[id] = nil
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

            layer.frame = transform.worldToScreen(tile.worldFrame)
            layer.zPosition = CGFloat(tile.z)

            let onScreenEdge = CGFloat(tile.longestWorldEdge) * transform.scale
            let tier = lod.tier(forOnScreenLongestEdge: onScreenEdge, previous: keyByTile[tile.id]?.tier)
            let key = ThumbnailCache.Key(imageID: tile.id % images.count, tier: tier)
            keyByTile[tile.id] = key
            neededKeys.insert(key)

            if let image = cache.image(for: key) {
                layer.contents = image
            } else {
                scheduler.request(
                    key: key,
                    data: images.data(forTileID: tile.id),
                    maxPixelSize: Self.pixelSize(for: tier)
                )
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
            let key = ThumbnailCache.Key(imageID: tile.id % images.count, tier: tier)
            guard cache.image(for: key) == nil else { continue }
            if let image = DecodeScheduler.decodeBlocking(
                data: images.data(forTileID: tile.id),
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

    /// Target decoded pixel size (longest edge) per LOD tier.
    static func pixelSize(for tier: LODTier) -> Int {
        switch tier {
        case .low: return 128
        case .medium: return 512
        case .full: return 1280
        }
    }
}
