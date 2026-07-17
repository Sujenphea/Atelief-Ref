//
//  DeletedSpaceBackup.swift
//  AtelierCore
//
//  UX-batch (146) · space-delete undo — a verbatim snapshot of everything
//  ``AppServices/deleteSpaceRecoverable(_:)`` removes: the ``Space`` row plus its
//  ``SpaceItem`` placements (which CASCADE at the DB level). Mirrors
//  ``DeletedAssetsBackup``: the underlying assets are never touched (only the
//  board's placements go), so a restore reinstates the board EXACTLY (stable ids,
//  positions, z-order, timestamps) as long as the referenced assets still exist.
//

import Foundation

/// The board a recoverable space delete captured: the space and its placements.
/// A GRDB-free public value (domain records, no bespoke DTOs), so a schema change
/// flows through without a parallel shape.
public struct DeletedSpaceBackup: Sendable, Equatable {
    /// The deleted space row, or `nil` if the space was already gone.
    public var space: Space?
    /// Its placements (asset + element rows), captured before the cascade ran.
    public var items: [SpaceItem]

    public init(space: Space? = nil, items: [SpaceItem] = []) {
        self.space = space
        self.items = items
    }

    public var isEmpty: Bool { space == nil }
}
