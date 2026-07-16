//
//  DeletedAssetsBackup.swift
//  AtelierCore
//
//  010 · delete-undo — a verbatim snapshot of everything
//  ``AppServices/deleteAssetsRecoverable(_:)`` removes, so ``AppServices/
//  restoreDeletedAssets(_:)`` can reinstate it EXACTLY (stable ids, order,
//  timestamps). Holds domain records, never blob bytes: blobs stay on disk until
//  the launch orphan-GC reclaims a delete that was never undone, so a restore
//  finds the media already present.
//

import Foundation

/// The graph a recoverable delete captured: the assets, their sources, collection
/// memberships (with manual order), tag links, and the collection covers the
/// delete `SET NULL`-ed. A GRDB-free public value (arrays of domain records — no
/// bespoke DTOs), so a schema change flows through without a parallel shape.
public struct DeletedAssetsBackup: Sendable, Equatable {
    public var assets: [Asset]
    public var sources: [Source]
    public var memberships: [CollectionItem]
    public var tagLinks: [AssetTag]
    /// Collections whose `cover_asset_id` pointed at a deleted asset (nulled by the
    /// FK); restored only if the collection still has no cover.
    public var covers: [CoverRef]

    public struct CoverRef: Sendable, Equatable {
        public var collectionID: UUID
        public var assetID: UUID
        public init(collectionID: UUID, assetID: UUID) {
            self.collectionID = collectionID
            self.assetID = assetID
        }
    }

    public init(
        assets: [Asset] = [], sources: [Source] = [],
        memberships: [CollectionItem] = [], tagLinks: [AssetTag] = [],
        covers: [CoverRef] = []
    ) {
        self.assets = assets
        self.sources = sources
        self.memberships = memberships
        self.tagLinks = tagLinks
        self.covers = covers
    }

    public var isEmpty: Bool {
        assets.isEmpty && sources.isEmpty && memberships.isEmpty
            && tagLinks.isEmpty && covers.isEmpty
    }
}
