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
    /// The collections the bound asset belongs to (name-ordered), refreshed after
    /// every membership edit (041 · Details "Collections" chips).
    @Published private(set) var collections: [Collection] = []
    /// Every collection in the library — the "Add" picker's menu (041). Loaded on
    /// bind; a small query, and collections rarely change while a page is open.
    @Published private(set) var allCollections: [Collection] = []
    /// The last write/read failure, for the host to surface on its alert.
    @Published var lastError: String?
    /// Fired (on the main actor) after a collection membership add/remove commits,
    /// so the host can refresh state the store doesn't own — the collection grid,
    /// sidebar counts, stack previews (041). Without it the chips update but the
    /// grid behind the overlay goes stale, reading as "the edit didn't take."
    var onMembershipChanged: (() -> Void)?

    private let services: AppServices
    /// The asset the store currently reflects; `nil` when unbound.
    private var assetID: UUID?

    init(services: AppServices) {
        self.services = services
    }

    /// Point the store at `assetID` (or clear with `nil`) and load its tags +
    /// collection memberships.
    func bind(to assetID: UUID?) {
        self.assetID = assetID
        tags = []
        collections = []
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

    // MARK: - Name / Note (041)

    /// Persist the asset's display name (empty → cleared). Fire-and-forget; the
    /// view's local draft is the edit source of truth, so no reload is needed.
    func setName(_ name: String) {
        guard let assetID else { return }
        Task {
            do { try await services.setName(name, for: assetID) }
            catch { lastError = "\(error)" }
        }
    }

    /// Persist the asset's note (empty → cleared). Fire-and-forget, as `setName`.
    func setNote(_ note: String) {
        guard let assetID else { return }
        Task {
            do { try await services.setNote(note, for: assetID) }
            catch { lastError = "\(error)" }
        }
    }

    // MARK: - Collections (041)

    /// Add the bound asset to `collection`, then reload the membership chips.
    /// Idempotent — an already-member asset is a no-op in the funnel.
    func addToCollection(_ collection: Collection) {
        guard let assetID else { return }
        Task {
            do {
                try await services.addAssets([assetID], to: collection.id)
                reloadIfCurrent(assetID)
                onMembershipChanged?()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Remove the bound asset from `collection`, then reload the chips. Never
    /// orphans: losing the last membership re-homes the asset to Unsorted — the
    /// funnel now owns that fallback (F3), in the same transaction as the removal,
    /// so this used to be a second round-trip that could fail on its own.
    func removeFromCollection(_ collection: Collection) {
        guard let assetID else { return }
        Task {
            do {
                try await services.removeAssets([assetID], from: collection.id)
                reloadIfCurrent(assetID)
                onMembershipChanged?()
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
                let loadedTags = try await services.tags(for: assetID)
                let loadedCollections = try await services.collections(for: assetID)
                let loadedAll = try await services.listCollections()
                guard self.assetID == assetID else { return }
                tags = loadedTags
                collections = loadedCollections
                allCollections = loadedAll
            } catch {
                lastError = "\(error)"
            }
        }
    }
}
