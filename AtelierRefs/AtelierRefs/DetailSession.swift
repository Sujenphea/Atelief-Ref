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
        /// B2 seam (`DetailImageLoader` / decode strategy): the LRU-cached
        /// display image the overlay will consume instead of decoding full-res
        /// itself. Unused in B1 — `ItemDetailView` still decodes its own full-res
        /// off `blobURL`; this field carries the shape B2 fills in. Always `nil`
        /// here.
        var displayImage: NSImage?
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

    init(tags: AssetTagsStore, previewURL: @escaping (Asset) -> URL?) {
        self.tags = tags
        self.previewURL = previewURL
    }

    /// The membership id currently presented — the host's check for auto-dismiss
    /// (did this id vanish from the reloaded feed?) and its lead-sync-on-close key.
    var currentID: UUID? { state?.detail.item.id }

    /// Present `detail` in the overlay (a fresh open). ONE publish: the new item
    /// with a cleared placeholder; the preview then arrives asynchronously as a
    /// second publish. Binds tags to the asset.
    func present(_ detail: CollectionItemDetail) { load(detail) }

    /// Step the overlay to `detail` (prev/next). Identical mechanics to
    /// ``present(_:)`` — the DISTINCTION that matters is that this NEVER touches
    /// `IngestionModel` (no lead/selection write): only `state` moves, so the grid
    /// does not re-render per step. The caller records the view separately.
    func step(to detail: CollectionItemDetail) { load(detail) }

    /// Tear down the overlay: clear the state and unbind tags. Called by the host
    /// on close (Back / Escape) and on auto-dismiss when the item is deleted.
    func dismiss() {
        state = nil
        tags.bind(to: nil)
    }

    /// Set the shown item (one publish), rebind tags, and kick off the placeholder
    /// decode. Shared by open + step so the two paths can never drift.
    private func load(_ detail: CollectionItemDetail) {
        state = State(detail: detail, previewImage: nil, displayImage: nil)
        tags.bind(to: detail.asset.id)
        loadPreview(for: detail)
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
