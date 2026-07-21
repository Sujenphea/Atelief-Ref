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
    /// + full-res decodes. Shared by open + step so the two paths can never drift.
    ///
    /// On a STEP the previous ``State/displayImage`` is carried into the new state
    /// so the last item's image stays on screen until the new one lands (no blank
    /// flash on step, per 036 §3 B2); a fresh open starts with none.
    private func load(_ detail: CollectionItemDetail, in items: [CollectionItemDetail], isStep: Bool) {
        let retained = isStep ? state?.displayImage : nil
        state = State(detail: detail, previewImage: nil, displayImage: retained)
        tags.bind(to: detail.asset.id)
        loadPreview(for: detail)
        loadDisplayImage(for: detail, in: items)
    }

    /// Request the full-res display image for `detail` from the loader; on arrival
    /// publish it (guarded against rapid stepping), THEN — and only then, so the
    /// preloads don't contend with the visible decode — warm prev/next and retain
    /// only the current window. A media-less kind has no blob: drop any retained
    /// image and skip the decode.
    private func loadDisplayImage(for detail: CollectionItemDetail, in items: [CollectionItemDetail]) {
        let window = retentionWindow(for: detail.item.id, in: items)
        guard let source = displaySource(detail.asset) else {
            // Media-less current — clear the retained image ONLY if there is one, so
            // a media-less open stays a single publish (the B1 invariant).
            if state?.displayImage != nil { state?.displayImage = nil }
            applyRetentionAndPreload(window: window, for: detail.item.id, in: items)
            return
        }
        let targetID = detail.item.id
        let loader = self.loader
        Task { [weak self] in
            let image = await loader.displayImage(
                hash: source.hash, url: source.url, targetLongSidePx: nil)
            guard let self, self.state?.detail.item.id == targetID else { return }
            if let image { self.state?.displayImage = image }
            self.applyRetentionAndPreload(window: window, for: targetID, in: items)
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

    /// Warm prev/next, then cancel any preload outside `window`. No-op when there is
    /// nothing displayable in reach (keeps the shared loader — and the B1 tests —
    /// untouched for a media-less feed). The loader calls run in one ordered task so
    /// the just-started preloads (whose hashes are in `window`) are never the ones
    /// `retainOnly` cancels.
    private func applyRetentionAndPreload(
        window: Set<String>, for currentID: UUID, in items: [CollectionItemDetail]
    ) {
        guard !window.isEmpty else { return }
        let neighbors = detailNeighbors(items: items, currentID: currentID)
        let neighborSources = [neighbors.previous, neighbors.next]
            .compactMap { $0 }
            .compactMap { displaySource($0.asset) }
        let loader = self.loader
        Task {
            for source in neighborSources {
                await loader.preload(hash: source.hash, url: source.url, targetLongSidePx: nil)
            }
            await loader.retainOnly(hashes: window)
        }
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
