//
//  AssetTagsStore.swift
//  AtelierRefs
//
//  A small, selection-free tag store for one asset — the tags surface for the
//  detail page opened from a Space board (023-item-detail-plan F3b). The
//  collection grid drives tags through `IngestionModel`'s folder-scoped
//  selection; a Space places assets with no folder context, so it binds this
//  store to the asset instead. Both talk to the same `AppServices` funnel.
//

import AtelierCore
import Combine
import Foundation

@MainActor
final class AssetTagsStore: ObservableObject {
    /// The bound asset's tags (name-ordered), refreshed after every edit.
    @Published private(set) var tags: [Tag] = []
    /// The last write/read failure, for the host to surface on its alert.
    @Published var lastError: String?

    private let services: AppServices
    /// The asset the store currently reflects; `nil` when unbound.
    private var assetID: UUID?

    init(services: AppServices) {
        self.services = services
    }

    /// Point the store at `assetID` (or clear with `nil`) and load its tags.
    func bind(to assetID: UUID?) {
        self.assetID = assetID
        tags = []
        guard let assetID else { return }
        refresh(assetID)
    }

    /// Apply a user tag, then refresh. Empty / whitespace names are rejected in
    /// the funnel (`Validation.tagName`); a duplicate is idempotent.
    func add(_ name: String) {
        guard let assetID else { return }
        Task {
            do {
                try await services.applyTag(name, to: assetID, source: .user)
                reloadIfCurrent(assetID)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Remove `tag`, then refresh. Idempotent if the link is already gone.
    func remove(_ tag: Tag) {
        guard let assetID else { return }
        Task {
            do {
                try await services.removeTag(tag.name, from: assetID, source: tag.source)
                reloadIfCurrent(assetID)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Reload only if `assetID` is still the bound asset (an edit that lands after
    /// the page was closed / re-bound must not repopulate a stale asset).
    private func reloadIfCurrent(_ assetID: UUID) {
        guard self.assetID == assetID else { return }
        refresh(assetID)
    }

    private func refresh(_ assetID: UUID) {
        Task {
            do {
                let loaded = try await services.tags(for: assetID)
                guard self.assetID == assetID else { return }
                tags = loaded
            } catch {
                lastError = "\(error)"
            }
        }
    }
}
