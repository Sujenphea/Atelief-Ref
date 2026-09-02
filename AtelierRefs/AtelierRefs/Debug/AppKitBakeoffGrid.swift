//
//  AppKitBakeoffGrid.swift
//  AtelierRefs
//
//  037 · mode `appKit` — 035 §5 Option B / 036 §2 A1, the READ-ONLY subset.
//
//  This is the CEILING probe for the 1–2 week `NSCollectionView` rewrite: an
//  `NSViewRepresentable` over `NSScrollView` → `NSCollectionView` with a custom
//  `NSCollectionViewLayout` that wraps the EXISTING `MasonryLayoutCache`
//  verbatim, and layer-backed cells that never host SwiftUI.
//
//  ── The two load-bearing claims, and how this file proves them ────────────
//  036 §2 asserts two facts the whole Option-B plan rests on. Both are cheap to
//  verify now and expensive to discover in week two, so both are instrumented
//  here rather than assumed:
//
//   1. **Flipped 1:1 mapping.** `MasonryLayout.layout` emits top-left-origin
//      frames and `NSCollectionView` is flipped, so frames map with ZERO
//      conversion. ``MasonryBakeoffDiagnostics/verifyRenderedFrames`` compares
//      every materialized cell's REAL `view.frame` against the analytic frame
//      and reports the worst delta; `AppKitBakeoffGridTests` asserts the same
//      thing over a live, scrolled `NSCollectionView`.
//      MEASURED: true as a coordinate-SPACE identity, with one correction —
//      AppKit pixel-snaps the item views it places, so a fractional masonry
//      frame renders up to half a backing pixel off its analytic value
//      (0.2333pt observed at 2×). The layout ATTRIBUTES are exact; the VIEWS
//      are exact-then-snapped. Harmless — marquee/nav/reorder ride the analytic
//      frames by design — but A2/A3 must not assume `cell.view.frame == frames[i]`.
//   2. **Zero invalidation while scrolling.** `shouldInvalidateLayout(forBoundsChange:)`
//      compares WIDTH ONLY. `prepare()` and every bounds-change query are
//      counted, and the count is snapshotted when a scroll starts — so an
//      "invalidation storm" (036 §A-risks) reports itself instead of silently
//      destroying the numbers.
//
//  Both readouts surface in a HUD that is HIDDEN while scrolling (so it costs
//  nothing on the measured path) and repainted once the scroll goes idle, and
//  are also printed to the console.
//
//  ── Read-only by specification (037 §2, §6) ──────────────────────────────
//  No selection, drag, drop, context menu, hover, or GIF. `context.wrappers` is
//  therefore ignored, exactly as the seam permits. A favourable number here is
//  an UPPER BOUND on Option B, never the shipping number — A2/A3 add all of
//  that cost back.
//
//  ── One confound, stated plainly ─────────────────────────────────────────
//  `layer.contents` needs a `CGImage`, which `ThumbnailCache` (an
//  `NSImage`-valued cache) cannot vend, so this file decodes through
//  ``BakeoffThumbnailStore`` — ImageIO downsampling to a size bucket, fully
//  off-main, `kCGImageSourceShouldCacheImmediately` so no lazy decode lands on
//  the main thread at first draw. That is 036 §C1's pipeline, which the SwiftUI
//  modes do NOT have yet. Consequence: the COLD comparison partly measures
//  Workstream C rather than the framework. The WARM comparison is clean — both
//  sides are then a memory-cache hit — so warm is the number to judge the
//  framework on. See the change-log entry.
//
//
//  099 · 8A — the whole bake-off harness is DEBUG-only.
//
//  It is 2,765 lines across seven files, and until this guard it compiled into
//  every Release build the user ever ran: a grid harness, a pinch harness, a
//  frame-time recorder and a scroll driver, none of them reachable without a
//  launch argument, all of them shipped. `#if DEBUG` is the whole fix — the
//  folder still deletes in one move, and the app the user installs no longer
//  carries it.
//

#if DEBUG

import AppKit
import AtelierCore
import CoreGraphics
import ImageIO
import SwiftUI

// MARK: - Entry point

struct AppKitBakeoffGrid: View {
    let context: GridBakeoffContext

    var body: some View {
        MasonryCollectionRepresentable(context: context)
    }
}

// MARK: - Diagnostics (Task 2)

/// Counters and checks that turn 036 §2's two load-bearing ASSERTIONS into
/// evidence. Deliberately nothing but integer increments on the scroll path —
/// the string formatting and the frame comparison run only once the scroll has
/// gone idle, so measuring the grid never perturbs it.
@MainActor
final class MasonryBakeoffDiagnostics {
    /// Every `NSCollectionViewLayout.prepare()` — i.e. every full masonry
    /// re-solve. Must not move while scrolling.
    var prepareCount = 0
    /// Every `shouldInvalidateLayout(forBoundsChange:)` question AppKit asked.
    var boundsChangeQueries = 0
    /// The subset of those we answered `true` to (width genuinely changed).
    var widthInvalidations = 0
    /// Every `layoutAttributesForElements(in:)` — the intended hot path.
    var elementQueries = 0
    /// Clip-view bounds changes, i.e. scroll ticks.
    var scrollTicks = 0
    /// `prepareCount` sampled at the first scroll tick of the current gesture.
    var prepareCountAtScrollStart: Int?
    /// Whether the document view really is flipped (claim 1's precondition).
    var isFlipped: Bool?
    /// Result of the last rendered-vs-analytic frame comparison.
    var frameCheck: FrameCheck?

    /// The outcome of comparing materialized cell frames against the analytic
    /// `MasonryLayout` frames.
    ///
    /// The claim is a BOUND, not an equality — measured, not assumed. AppKit
    /// pixel-snaps every item view, and masonry heights (`columnWidth / aspect`)
    /// are routinely fractional, so a perfectly correct grid still deviates by
    /// up to half a backing pixel. What proves "same coordinate space" is that
    /// ``worstDelta`` never exceeds ``tolerance``: a missing flip or a wrong
    /// origin would show up as hundreds of points, not hundredths.
    /// ``backingMismatches`` (vs `alignAllEdgesNearest`) is recorded only to
    /// note that AppKit's exact snap rule is NOT that one.
    struct FrameCheck {
        var comparedCount: Int
        var worstDelta: CGFloat
        var worstIndex: Int
        var backingMismatches: Int
        var tolerance: CGFloat
        var sample: [(index: Int, analytic: CGRect, rendered: CGRect)]

        var isExact: Bool { comparedCount > 0 && worstDelta <= tolerance }
    }

    /// Compare EVERY materialized cell's real frame against the frame
    /// `MasonryLayout` computed for that index — the direct test of 036 §2's
    /// "zero conversion" claim. A non-zero worst delta means the flipped-space
    /// assumption is wrong and the whole A1 plan needs a coordinate transform.
    func verifyRenderedFrames(
        collectionView: NSCollectionView, layout: MasonryBakeoffLayout
    ) {
        isFlipped = collectionView.isFlipped
        var compared = 0
        var worst: CGFloat = 0
        var worstIndex = -1
        var backingMismatches = 0
        var sample: [(index: Int, analytic: CGRect, rendered: CGRect)] = []
        for item in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: item),
                  let analytic = layout.analyticFrame(at: path.item) else { continue }
            let rendered = item.view.frame
            let delta = max(
                max(abs(rendered.minX - analytic.minX), abs(rendered.minY - analytic.minY)),
                max(abs(rendered.width - analytic.width), abs(rendered.height - analytic.height)))
            compared += 1
            if delta > worst { worst = delta; worstIndex = path.item }

            let snapped = collectionView.backingAlignedRect(
                analytic, options: [.alignAllEdgesNearest])
            if abs(rendered.minX - snapped.minX) > 0.001
                || abs(rendered.minY - snapped.minY) > 0.001
                || abs(rendered.width - snapped.width) > 0.001
                || abs(rendered.height - snapped.height) > 0.001 {
                backingMismatches += 1
            }
            if sample.count < 4 {
                sample.append((index: path.item, analytic: analytic, rendered: rendered))
            }
        }
        let scale = collectionView.window?.backingScaleFactor ?? 2
        frameCheck = FrameCheck(
            comparedCount: compared, worstDelta: worst, worstIndex: worstIndex,
            backingMismatches: backingMismatches,
            tolerance: 0.5 / max(1, scale) + 0.0001,
            sample: sample.sorted { $0.index < $1.index })
    }

    /// Human-readable evidence, built ONLY when the scroll is idle.
    func report() -> String {
        var lines: [String] = []

        // Claim 2 — zero layout invalidation while scrolling.
        let duringScroll = prepareCountAtScrollStart.map { prepareCount - $0 }
        let scrollVerdict: String
        if let duringScroll {
            scrollVerdict = duringScroll == 0
                ? "PASS — 0 prepare() during scroll"
                : "FAIL — \(duringScroll) prepare() during scroll (INVALIDATION STORM)"
        } else {
            scrollVerdict = "not yet scrolled"
        }
        lines.append(
            "invalidation: \(scrollVerdict) · prepare() total \(prepareCount) · "
                + "boundsChange asked \(boundsChangeQueries), answered true \(widthInvalidations) · "
                + "scroll ticks \(scrollTicks) · attrs(rect) queries \(elementQueries)")

        // Claim 1 — flipped 1:1 mapping.
        let flippedText = isFlipped.map { $0 ? "flipped=YES" : "flipped=NO (!!)" } ?? "flipped=?"
        if let check = frameCheck {
            let verdict = check.isExact
                ? String(
                    format: "PASS — same space, worst deviation %.4fpt (<= %.4fpt pixel snap)",
                    check.worstDelta, check.tolerance)
                : String(
                    format: "FAIL — worst deviation %.4fpt at index %d exceeds the "
                        + "%.4fpt pixel snap: real coordinate mismatch",
                    check.worstDelta, check.worstIndex, check.tolerance)
            lines.append(
                "coords: \(flippedText) · \(verdict) · compared \(check.comparedCount) cells")
            for entry in check.sample {
                lines.append(
                    "   [\(entry.index)] analytic \(short(entry.analytic))"
                        + "  rendered \(short(entry.rendered))")
            }
        } else {
            lines.append("coords: \(flippedText) · no cells materialized yet")
        }
        return lines.joined(separator: "\n")
    }

    private func short(_ rect: CGRect) -> String {
        String(
            format: "(%.1f, %.1f, %.1f, %.1f)",
            rect.minX, rect.minY, rect.width, rect.height)
    }
}

// MARK: - The layout

/// `NSCollectionViewLayout` over the EXISTING `MasonryLayoutCache` (036 §2 A1).
///
/// It reimplements no masonry math whatsoever: `prepare()` calls the same
/// memoized `MasonryLayoutCache.frames(...)` the production grid calls, and
/// `layoutAttributesForElements(in:)` is `masonryMarqueeIndices` — the
/// band-narrowed O(cols + hits + logN) rect query from `MarqueeMath.swift`,
/// which is exactly the question AppKit asks on every scroll tick.
///
/// The frames go onto `NSCollectionViewLayoutAttributes` with NO conversion, on
/// 036 §2's claim that a flipped `NSCollectionView` shares top-left-origin
/// content space with `MasonryLayout`. `MasonryBakeoffDiagnostics` checks that
/// against reality rather than trusting it.
@MainActor
final class MasonryBakeoffLayout: NSCollectionViewLayout {
    /// Per-item aspect ratios, index-aligned to the data source's items.
    var aspects: [Double] = []
    var density: GridDensity = .default
    var spacing: CGFloat = 8
    var topInset: CGFloat = 0
    /// Bumped by the host when the item set changes, so the memo key moves.
    var itemsVersion = 0
    /// Test seam: the width to solve at when there is no live collection view.
    /// Production always reads the clip view instead.
    var explicitWidth: CGFloat?

    let diagnostics: MasonryBakeoffDiagnostics

    /// The SAME memo the shipping grid uses — 036 §1 lists `MasonryLayoutCache`
    /// among the framework-independent pieces to KEEP, so the spike must pay its
    /// real cost, no more and no less.
    private let cache = MasonryLayoutCache()
    private var solved = MasonryFrames(
        frames: [], contentHeight: 0, columnWidth: 1, columns: 1)
    /// The width the current `solved` was computed at — the ONLY thing a bounds
    /// change is allowed to compare against.
    private(set) var preparedWidth: CGFloat = 0

    init(diagnostics: MasonryBakeoffDiagnostics) {
        self.diagnostics = diagnostics
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The analytic frame for an index, for the diagnostics comparison.
    func analyticFrame(at index: Int) -> CGRect? {
        guard index >= 0, index < solved.frames.count else { return nil }
        return solved.frames[index]
    }

    var solvedColumnWidth: CGFloat { solved.columnWidth }

    // MARK: Solving

    /// The width to lay out in: the CLIP view's width, not the collection view's
    /// own. The collection view's width is set FROM `collectionViewContentSize`,
    /// so reading it here would be circular and would latch the first value.
    private func availableWidth() -> CGFloat {
        if let clipWidth = collectionView?.enclosingScrollView?.contentSize.width,
           clipWidth > 0 {
            return clipWidth
        }
        if let explicitWidth { return explicitWidth }
        return max(collectionView?.bounds.width ?? 0, 1)
    }

    override func prepare() {
        super.prepare()
        diagnostics.prepareCount += 1
        let width = max(availableWidth(), 1)
        let columns = density.columns(forWidth: width)
        solved = cache.frames(
            version: itemsVersion, width: width, columns: columns,
            spacing: spacing, topInset: topInset,
            aspects: { [aspects] in aspects })
        preparedWidth = width
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: preparedWidth, height: max(solved.contentHeight, 1))
    }

    // MARK: Queries

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        diagnostics.elementQueries += 1
        // `masonryMarqueeIndices` (MarqueeMath.swift:77) IS this query: analytic
        // column membership culls whole columns in O(1), and the y-monotonic
        // stacking within a column makes the vertical span a binary search.
        let hits = masonryMarqueeIndices(
            in: rect, frames: solved.frames, columns: solved.columns)
        return hits.map { index in
            let attributes = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: index, section: 0))
            // ZERO conversion — the claim under test.
            attributes.frame = solved.frames[index]
            return attributes
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let frame = analyticFrame(at: indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    /// WIDTH ONLY (036 §2 A1). Scrolling changes the bounds ORIGIN, never the
    /// width, so this answers `false` for every scroll tick and the masonry is
    /// never re-solved mid-scroll. Answering `true` here — the obvious mistake,
    /// and what a naive `return true` or a full-rect comparison would do — is
    /// the "invalidation storm" of 036 §A-risks: it would re-run the O(N) solve
    /// on every frame and silently destroy the measurement.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        diagnostics.boundsChangeQueries += 1
        let changed = abs(newBounds.width - preparedWidth) > 0.5
        if changed { diagnostics.widthInvalidations += 1 }
        return changed
    }
}

// MARK: - The cell

/// A layer-backed grid cell — NO `NSHostingView` (036 §2: per-cell SwiftUI
/// hosting was the ORIGINAL measured bottleneck, 035 §1). The whole cell is one
/// `CALayer` with `contents` + `.resizeAspectFill` + a corner radius, which is
/// what the dominant "image tile" cell kind actually needs.
final class MasonryBakeoffItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MasonryBakeoffItem")

    /// Bumped on every (re)configure and on reuse. An in-flight decode that
    /// completes after the cell was recycled sees a stale token and drops its
    /// result — the identity re-check that stops a fast scroll from painting
    /// item A's thumbnail into item B's cell.
    private var loadToken = 0
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .never
        if let layer = container.layer {
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.cornerRadius = 8
            layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        view = container
    }

    func configure(hash: String?, url: URL?, bucket: Int) {
        loadToken &+= 1
        let token = loadToken
        loadTask?.cancel()
        loadTask = nil

        guard let hash, let url else {
            view.layer?.contents = nil
            return
        }
        // Synchronous cache hit paints with no async hop at all — the common
        // case on a warm run, and the reason a recycled cell does not flash.
        if let hit = BakeoffThumbnailStore.shared.cached(hash: hash, bucket: bucket) {
            view.layer?.contents = hit
            return
        }
        view.layer?.contents = nil
        loadTask = Task { [weak self] in
            await BakeoffThumbnailStore.shared.load(hash: hash, url: url, bucket: bucket)
            guard let self, !Task.isCancelled, self.loadToken == token else { return }
            self.view.layer?.contents =
                BakeoffThumbnailStore.shared.cached(hash: hash, bucket: bucket)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        view.layer?.contents = nil
    }
}

// MARK: - Thumbnails

/// A `CGImage` cache with an off-main ImageIO decode (036 §C1's pipeline).
///
/// `ThumbnailCache` is not reusable here: it is `NSCache<NSString, NSImage>`,
/// and `layer.contents` wants a `CGImage`. Converting per cell would push a
/// decode onto the main thread during scroll — precisely what must not happen.
/// Mirrors `ThumbnailCache`'s discipline of returning nothing from the async
/// call and re-reading through the synchronous `cached`, so no non-`Sendable`
/// value crosses an isolation boundary.
// `nonisolated` to match the `@unchecked Sendable` already asserted here: the
// store's only state is an `NSCache`, which is thread-safe, and its loader hands
// that cache to a `Task.detached`. Under MainActor-by-default the class would
// otherwise infer main-actor isolation and contradict its own Sendable claim.
nonisolated final class BakeoffThumbnailStore: @unchecked Sendable {
    static let shared = BakeoffThumbnailStore()

    /// NSCache needs a class value; `Box` also lets us pay a real byte cost
    /// instead of a meaningless count limit.
    /// `nonisolated` because it is constructed on the DECODE thread, not the
    /// main actor (the project defaults to main-actor isolation).
    nonisolated private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init() {
        // Byte-based, unlike the 512-COUNT limit that 036 §1 flags as thrashing
        // at target scale.
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    /// The pixel ladder from 036 §C1 — coarse on purpose, so a density step
    /// usually stays in-bucket and re-decodes nothing. 512 is the on-disk tier
    /// ceiling, so nothing above it can add detail.
    static func bucket(forLongSide points: CGFloat, scale: CGFloat) -> Int {
        let pixels = points * max(1, scale)
        for step in [128, 192, 256, 384, 512] where CGFloat(step) >= pixels { return step }
        return 512
    }

    private func key(_ hash: String, _ bucket: Int) -> NSString { "\(hash)#\(bucket)" as NSString }

    func cached(hash: String, bucket: Int) -> CGImage? {
        cache.object(forKey: key(hash, bucket))?.image
    }

    func load(hash: String, url: URL, bucket: Int) async {
        if cache.object(forKey: key(hash, bucket)) != nil { return }
        let cacheKey = key(hash, bucket)
        await Task.detached(priority: .userInitiated) { [cache] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Force the pixels NOW, on this background thread. Without it
                // the decode is lazy and lands on the main thread at first
                // draw — 036 §1's `NSImage(data:)` complaint, mid-scroll.
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: bucket,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else { return }
            cache.setObject(
                Box(image), forKey: cacheKey, cost: image.bytesPerRow * image.height)
        }.value
    }
}

// MARK: - The representable

private struct MasonryCollectionRepresentable: NSViewRepresentable {
    let context: GridBakeoffContext

    func makeCoordinator() -> MasonryBakeoffCoordinator {
        MasonryBakeoffCoordinator(context: context)
    }

    func makeNSView(context nsContext: Context) -> NSView {
        nsContext.coordinator.makeContainer(registering: context.registerScrollTarget)
    }

    func updateNSView(_ nsView: NSView, context nsContext: Context) {
        nsContext.coordinator.update(context: context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: MasonryBakeoffCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - The coordinator

/// Owns the AppKit objects and the data source. Read-only: no delegate methods
/// for selection, dragging, or menus are implemented, by specification.
@MainActor
final class MasonryBakeoffCoordinator: NSObject, NSCollectionViewDataSource {
    private var context: GridBakeoffContext
    private let diagnostics = MasonryBakeoffDiagnostics()
    private lazy var layout = MasonryBakeoffLayout(diagnostics: diagnostics)

    private var scrollView: NSScrollView?
    private var collectionView: NSCollectionView?
    private var hud: NSTextField?
    private var idleTimer: Timer?

    private var items: [CollectionItemDetail] = []
    private var isScrolling = false
    private var lastSeenTicks = 0
    private var didVerifyOnce = false

    init(context: GridBakeoffContext) {
        self.context = context
        super.init()
    }

    // MARK: Construction

    func makeContainer(
        registering register: @escaping (BakeoffScrollTarget) -> Void
    ) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        let scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false

        let collectionView = NSCollectionView(frame: scrollView.bounds)
        // Native selection is bypassed entirely (036 §2 A1) — and the spike is
        // read-only regardless.
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.register(
            MasonryBakeoffItem.self, forItemWithIdentifier: MasonryBakeoffItem.identifier)
        scrollView.documentView = collectionView

        container.addSubview(scrollView)

        // Evidence HUD. Pinned bottom-left in the (unflipped) container, hidden
        // for the entire duration of any scroll so it composites nothing on the
        // measured path.
        let hud = NSTextField(labelWithString: "")
        hud.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hud.textColor = .white
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        hud.drawsBackground = true
        hud.isSelectable = true
        hud.maximumNumberOfLines = 0
        hud.frame = NSRect(x: 8, y: 8, width: 720, height: 96)
        hud.autoresizingMask = [.maxXMargin, .maxYMargin]
        hud.isHidden = true
        container.addSubview(hud)

        self.scrollView = scrollView
        self.collectionView = collectionView
        self.hud = hud

        observeClipView(scrollView.contentView)
        startIdleTimer()

        applyContext()

        // Registered from `makeNSView` per the seam contract, but deferred one
        // runloop turn: `registerScrollTarget` writes the harness's `@State`,
        // and doing that synchronously inside a SwiftUI view update is exactly
        // the "modifying state during view update" trap. The target reads live
        // geometry, so a turn's delay costs nothing.
        DispatchQueue.main.async {
            register(NSScrollViewBakeoffTarget(scrollView: scrollView))
        }

        return container
    }

    func tearDown() {
        idleTimer?.invalidate()
        idleTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Updates

    func update(context: GridBakeoffContext) {
        self.context = context
        applyContext()
    }

    /// Push the context's inputs into the layout + data source, reloading only
    /// when the item set genuinely changed. A bake-off run holds `items` fixed,
    /// so this must be a no-op on every body pass or the grid would relayout
    /// under the measurement.
    private func applyContext() {
        layout.density = context.density
        layout.spacing = context.spacing
        layout.topInset = context.topInset

        let changed = items.count != context.items.count
            || items.first?.item.id != context.items.first?.item.id
            || items.last?.item.id != context.items.last?.item.id
        guard changed else { return }

        items = context.items
        layout.aspects = items.map { aspect(for: $0) }
        layout.itemsVersion &+= 1
        layout.invalidateLayout()
        collectionView?.reloadData()
        didVerifyOnce = false
    }

    // MARK: Clip-view observation

    private func observeClipView(_ clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clipView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView)
    }

    /// A scroll tick. Kept to integer arithmetic ONLY — anything heavier here
    /// would be measuring-instrument cost showing up in the measurement.
    @objc private func clipBoundsChanged() {
        diagnostics.scrollTicks += 1
        if !isScrolling {
            isScrolling = true
            diagnostics.prepareCountAtScrollStart = diagnostics.prepareCount
            hud?.isHidden = true
        }
    }

    /// The viewport RESIZED — the one event that legitimately re-solves the
    /// masonry. AppKit will not necessarily ask `shouldInvalidateLayout` for
    /// this (the collection view's own width is derived from the content size,
    /// so waiting for its bounds to move is circular), hence the explicit
    /// invalidation off the clip view instead.
    @objc private func clipFrameChanged() {
        guard let width = scrollView?.contentSize.width, width > 0 else { return }
        if abs(width - layout.preparedWidth) > 0.5 {
            layout.invalidateLayout()
        }
    }

    // MARK: Idle reporting

    /// A 2 Hz poll rather than a rescheduled per-tick timer: the per-tick
    /// version would allocate a work item on every scroll frame, i.e. on the
    /// path being measured.
    private func startIdleTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func pollIdle() {
        let ticks = diagnostics.scrollTicks
        let quiet = ticks == lastSeenTicks
        lastSeenTicks = ticks

        guard quiet else { return }
        if isScrolling {
            isScrolling = false
            publishReport(reason: "scroll idle")
        } else if !didVerifyOnce, let collectionView,
                  !collectionView.visibleItems().isEmpty {
            didVerifyOnce = true
            publishReport(reason: "first layout")
        }
    }

    private func publishReport(reason: String) {
        guard let collectionView else { return }
        diagnostics.verifyRenderedFrames(collectionView: collectionView, layout: layout)
        let text = "AppKit spike · \(reason)\n" + diagnostics.report()
        hud?.stringValue = text
        hud?.isHidden = false
        print("[037 Option B] " + text)
    }

    // MARK: Data source

    func collectionView(
        _ collectionView: NSCollectionView, numberOfItemsInSection section: Int
    ) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: MasonryBakeoffItem.identifier, for: indexPath)
        guard let cell = item as? MasonryBakeoffItem, indexPath.item < items.count else {
            return item
        }
        let detail = items[indexPath.item]
        // The bucket comes from the ANALYTIC frame, not from the cell's own
        // bounds (036 §C3: "the cell never guesses its own size").
        let frame = layout.analyticFrame(at: indexPath.item)
        let longSide = max(frame?.width ?? layout.solvedColumnWidth, frame?.height ?? 0)
        let scale = collectionView.window?.backingScaleFactor ?? 2
        cell.configure(
            hash: detail.asset.blobHash,
            url: context.thumbnailURL(detail),
            bucket: BakeoffThumbnailStore.bucket(forLongSide: longSide, scale: scale))
        return cell
    }
}

#endif  // DEBUG
