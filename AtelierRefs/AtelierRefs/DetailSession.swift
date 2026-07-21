//
//  DetailSession.swift
//  AtelierRefs
//
//  036 §3 B1 — the item-detail overlay's state, extracted OFF the `IngestionModel`
//  god-object (root cause 3). Today opening the detail page fires 3–4 separate
//  `@Published` writes on `IngestionModel` (`previewImage = nil`, `selectedTags =
//  []`, then the async `previewImage`/`selectedTags` arrivals), and EACH of those
//  re-runs every view that observes the god-object — the whole screen, grid
//  included. Prev/next repeated that per step.
//
//  This object bundles the whole overlay state into ONE `@Published state` struct,
//  so `present()` is a SINGLE publish and each async image arrival is one more —
//  all reaching ONLY the overlay's host (`CollectionDetailHost`), never the grid.
//  Tags ride the existing `AssetTagsStore` (the Space board + search overlays'
//  path); prev/next mutate only `state`, so stepping touches `IngestionModel` not
//  at all — the lead is synced back to the model ONCE on close.
//
//  Presentation-only: it owns no folder context and performs no writes to the
//  library — the host feeds it details and forwards its state to the
//  presentation-only `ItemDetailView`.
//

import AppKit
import AtelierCore
import Combine
import Foundation

@MainActor
final class DetailSession: ObservableObject {

    /// The whole overlay state, published as ONE value so open/step is one
    /// invalidation of the host (not the 3–4 god-object publishes it replaces).
    struct State {
        /// The item currently shown in the overlay (open target, or the prev/next
        /// step's item). Its position in the grid's feed is resolved by the host.
        var detail: CollectionItemDetail
        /// The instant 1280-tier placeholder shown while full-res decodes; `nil`
        /// until it lands (or for a media-less kind with no thumbnail).
        var previewImage: NSImage?
        /// The LRU-cached full-res display image the overlay consumes instead of
        /// decoding full-res itself (036 §3 B2). A `CGImage` — already fully
        /// decoded off-main by ``DetailImageLoader`` and rendered via
        /// `Image(decorative:)`, avoiding the `NSImage` lazy-decode-at-first-draw
        /// cost C1 measured away. On a step the PREVIOUS image is retained here
        /// until the next one lands, so stepping never flashes blank.
        var displayImage: CGImage?
    }

    /// The overlay's whole state, or `nil` when nothing is presented. A single
    /// `@Published` so a step or a preview arrival is exactly ONE publish, reaching
    /// only the host — the grid never observes this object.
    @Published private(set) var state: State?

    /// The bound tags store (036 §3 B1: detail tags route through `AssetTagsStore`,
    /// the same store the Space board + search overlays use). `present()`/`step()`
    /// rebind it to the shown asset; the host observes it for the chips.
    let tags: AssetTagsStore

    /// Resolves the 1280-tier preview URL for an asset (injected so this object
    /// stays free of `MediaStore`). Returns `nil` for a media-less kind.
    private let previewURL: (Asset) -> URL?

    /// The full-res LRU + neighbour preload (036 §3 B2). Shared process-wide so the
    /// cache survives closing and reopening the overlay.
    private let loader: DetailImageLoader

    /// Resolves an asset's full-res source (content hash + on-disk blob URL) for
    /// the loader; `nil` for a media-less kind (no blob to decode). Injected so
    /// this object stays free of `MediaStore` (defaults to media-less-only, which
    /// keeps the B1 tests' two-argument `init` and single-publish semantics intact).
    private let displaySource: (Asset) -> DetailImageLoader.Source?

    // MARK: - B3 sizing state

    /// The feed the overlay is stepping through, kept so a later geometry/zoom
    /// report (``updateDisplayTarget(fitLongSidePx:zoom:)``) can re-drive prev/next
    /// preload without the view re-supplying it.
    private var currentItems: [CollectionItemDetail] = []
    /// The media area's FIT long side in PIXELS (points × display scale), reported
    /// by ``ItemDetailView`` (036 §3 B3). Zoom-independent — the fit size doesn't
    /// change when the image is magnified. Drives the display-decode tier AND the
    /// FIT-bucket neighbour preloads. `0` until the view first measures.
    private var fitLongSidePx: CGFloat = 0
    /// The overlay's current zoom (1 = fit). `> 1` upgrades the display decode to
    /// native; reset to 1 on every open/step (the view resets it on navigation).
    private var zoomLevel: CGFloat = 1
    /// The item+bucket the display image was last REQUESTED at, so a geometry
    /// jitter or a `1.1×→6×` pinch that stays in the native bucket is a no-op
    /// instead of a re-decode (the anti-storm de-dup). `nil` in the preview case
    /// (no decode) and cleared on every open/step (a new item must re-request).
    private var lastDisplayKey: DetailImageKey?
    /// The in-flight display + preload work, retained so a test can await it; also
    /// lets a step supersede the prior item's swap by identity re-check.
    private var displayTask: Task<Void, Never>?

    init(
        tags: AssetTagsStore,
        previewURL: @escaping (Asset) -> URL?,
        loader: DetailImageLoader = .shared,
        displaySource: @escaping (Asset) -> DetailImageLoader.Source? = { _ in nil }
    ) {
        self.tags = tags
        self.previewURL = previewURL
        self.loader = loader
        self.displaySource = displaySource
    }

    /// The membership id currently presented — the host's check for auto-dismiss
    /// (did this id vanish from the reloaded feed?) and its lead-sync-on-close key.
    var currentID: UUID? { state?.detail.item.id }

    /// Present `detail` in the overlay (a fresh open). ONE publish: the new item
    /// with a cleared placeholder; the preview then arrives asynchronously as a
    /// second publish. Binds tags to the asset. `items` is the feed the overlay
    /// steps through — used to preload prev/next and bound the loader's cache to
    /// the current window.
    func present(_ detail: CollectionItemDetail, in items: [CollectionItemDetail] = []) {
        load(detail, in: items, isStep: false)
    }

    /// Step the overlay to `detail` (prev/next). Identical mechanics to
    /// ``present(_:in:)`` — the DISTINCTION that matters is that this NEVER touches
    /// `IngestionModel` (no lead/selection write): only `state` moves, so the grid
    /// does not re-render per step. The caller records the view separately. The
    /// previous display image is kept on screen until this item's resolves.
    func step(to detail: CollectionItemDetail, in items: [CollectionItemDetail] = []) {
        load(detail, in: items, isStep: true)
    }

    /// Tear down the overlay: clear the state and unbind tags. Called by the host
    /// on close (Back / Escape) and on auto-dismiss when the item is deleted.
    func dismiss() {
        state = nil
        tags.bind(to: nil)
    }

    /// Set the shown item (one publish), rebind tags, and kick off the placeholder
    /// + display decode. Shared by open + step so the two paths can never drift.
    ///
    /// Retention is DECODE-AWARE so a step never flashes blank (036 §3 B2), whichever
    /// image the media area will fall back to under the current sizing (036 §3 B3):
    ///  • a FIT/native display → keep the previous full-res up until the new one
    ///    lands (the preview sits behind it, unseen);
    ///  • a preview-only display (≤1280 viewport) → keep the previous PREVIEW up and
    ///    hold NO full-res (`displayImage == nil`), so the sufficient 1280 preview
    ///    shows through until the new preview lands.
    /// A fresh open starts with neither.
    private func load(_ detail: CollectionItemDetail, in items: [CollectionItemDetail], isStep: Bool) {
        currentItems = items
        zoomLevel = 1              // navigation resets zoom (the view does the same)
        lastDisplayKey = nil       // a new item invalidates the de-dup key
        let decode = detailDisplayDecode(fitLongSidePx: fitLongSidePx, zoom: zoomLevel)
        let retainedDisplay: CGImage?
        let retainedPreview: NSImage?
        switch decode {
        case .decode:
            retainedDisplay = isStep ? state?.displayImage : nil
            retainedPreview = nil
        case .preview:
            retainedDisplay = nil
            retainedPreview = isStep ? state?.previewImage : nil
        }
        state = State(detail: detail, previewImage: retainedPreview, displayImage: retainedDisplay)
        tags.bind(to: detail.asset.id)
        loadPreview(for: detail)
        loadDisplayImage(for: detail)
    }

    /// The media area's FIT pixel long side (points × display scale) and the current
    /// zoom, reported by ``ItemDetailView`` (036 §3 B3 — `onGeometryChange` + the
    /// zoom state). Re-drives the display decode when either changes so a larger
    /// viewport upgrades to a FIT decode and a zoom>1 upgrades to native; the loader
    /// request itself is de-duped in ``loadDisplayImage(for:)`` so an in-bucket
    /// change costs nothing. No-op when nothing is presented.
    func updateDisplayTarget(fitLongSidePx: CGFloat, zoom: CGFloat) {
        let changed = self.fitLongSidePx != fitLongSidePx || zoomLevel != zoom
        self.fitLongSidePx = fitLongSidePx
        zoomLevel = zoom
        guard changed, let detail = state?.detail else { return }
        loadDisplayImage(for: detail)
    }

    /// Choose the display decode for `detail` from the current sizing state and act
    /// on it (036 §3 B3). On the FIT/native path: request the loader at the chosen
    /// bucket and swap ``State/displayImage`` when it lands (the prior image stays up
    /// meanwhile — no blank on open, step, or zoom-in). On the preview path: decode
    /// NOTHING and leave `displayImage` as-is (a fresh open left it nil so the 1280
    /// preview shows; a zoom-OUT keeps whatever higher-res image we already have,
    /// which downscales crisply). Either way, prev/next preloads run afterward at the
    /// FIT bucket only, then the window is retained.
    private func loadDisplayImage(for detail: CollectionItemDetail) {
        let items = currentItems
        let window = retentionWindow(for: detail.item.id, in: items)

        guard let source = displaySource(detail.asset) else {
            // Media-less current — clear the retained image ONLY if there is one, so
            // a media-less open stays a single publish (the B1 invariant).
            if state?.displayImage != nil { state?.displayImage = nil }
            lastDisplayKey = nil
            displayTask = Task { [weak self] in
                await self?.preloadAndRetain(
                    window: window, for: detail.item.id, in: items, preload: false)
            }
            return
        }

        switch detailDisplayDecode(fitLongSidePx: fitLongSidePx, zoom: zoomLevel) {
        case .preview:
            // ≤1280 & not zoomed: the eagerly-generated 1280 preview already covers
            // the media area — do NOT decode the blob. Neighbours in a ≤1280 viewport
            // step from their own previews too, so skip their preload (no wasted
            // decode); this is what makes the common laptop case truly decode-free.
            lastDisplayKey = nil
            displayTask = Task { [weak self] in
                await self?.preloadAndRetain(
                    window: window, for: detail.item.id, in: items, preload: false)
            }
        case .decode(let target):
            let key = DetailImageKey(
                hash: source.hash, bucket: detailPixelBucket(longSidePx: target))
            // Anti-storm: this exact item+bucket is already requested (cached or
            // coalescing in the loader) — a geometry jitter or a native-staying pinch
            // is a no-op. `load` cleared the key, so the first request per item runs.
            guard key != lastDisplayKey else { return }
            lastDisplayKey = key
            let targetID = detail.item.id
            let loader = self.loader
            displayTask = Task { [weak self] in
                let image = await loader.displayImage(
                    hash: source.hash, url: source.url, targetLongSidePx: target)
                guard let self, self.state?.detail.item.id == targetID else { return }
                if let image { self.state?.displayImage = image }  // swap when it lands
                await self.preloadAndRetain(
                    window: window, for: targetID, in: items, preload: true)
            }
        }
    }

    /// The set of content hashes the loader should keep decoding for: {prev,
    /// current, next} restricted to displayable kinds. Always contains the current
    /// item's hash (when it has one), which is what makes ``DetailImageLoader/retainOnly(hashes:)``
    /// safe against cancelling the visible decode.
    private func retentionWindow(for currentID: UUID, in items: [CollectionItemDetail]) -> Set<String> {
        let neighbors = detailNeighbors(items: items, currentID: currentID)
        return Set([neighbors.current, neighbors.previous, neighbors.next]
            .compactMap { $0 }
            .compactMap { displaySource($0.asset)?.hash })
    }

    /// Warm prev/next (when `preload`), then cancel any preload outside `window`.
    /// No-op when there is nothing displayable in reach (keeps the shared loader —
    /// and the B1 tests — untouched for a media-less feed). Runs as one ordered task
    /// so the just-started preloads (whose hashes are in `window`) are never the ones
    /// `retainOnly` cancels.
    ///
    /// Neighbours ALWAYS preload at the FIT bucket (``fitLongSidePx``), never native —
    /// even when the current image is a zoom>1 native decode (036 §3 B3): stepping
    /// wants a fit-sized neighbour instantly, and a native neighbour would just burn
    /// memory the byte budget then evicts.
    private func preloadAndRetain(
        window: Set<String>, for currentID: UUID, in items: [CollectionItemDetail], preload: Bool
    ) async {
        guard !window.isEmpty else { return }
        if preload {
            let neighbors = detailNeighbors(items: items, currentID: currentID)
            let neighborSources = [neighbors.previous, neighbors.next]
                .compactMap { $0 }
                .compactMap { displaySource($0.asset) }
            let fit = fitLongSidePx
            for source in neighborSources {
                await loader.preload(hash: source.hash, url: source.url, targetLongSidePx: fit)
            }
        }
        await loader.retainOnly(hashes: window)
    }

    /// Test support: await the in-flight display + preload work so a threading test
    /// can assert which buckets the loader was asked for. Not used in production.
    func waitForDisplayWorkForTesting() async {
        await displayTask?.value
        await loader.waitForPendingWork()
    }

    /// Decode the 1280-tier placeholder off-main, then publish it into `state` only
    /// if the shown item hasn't changed underneath it (guards rapid stepping) — the
    /// exact guard the deleted `IngestionModel.loadPreview` used, now scoped to the
    /// overlay. One publish on arrival.
    private func loadPreview(for detail: CollectionItemDetail) {
        guard let url = previewURL(detail.asset) else { return }
        let targetID = detail.item.id
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self, self.state?.detail.item.id == targetID else { return }
                self.state?.previewImage = image
            }
        }
    }
}
