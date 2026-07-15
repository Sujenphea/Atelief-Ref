//
//  AssetDragPayload.swift
//  AtelierRefs
//
//  009 · N3 — the ONE drag payload shared by in-grid reorder, the Unsorted stack
//  row, the drop rail, and (future) the gallery. Carries the dragged asset ids
//  PLUS their source collection, so a drop can tell a same-collection reorder
//  from a cross-collection move without guessing. Replaces the old bare-UUID
//  `String` payload everywhere.
//
//  The custom `UTType` is declared at runtime via `UTType(exportedAs:)` — the app
//  only drags within itself, so a full `UTExportedTypeDeclarations` Info.plist
//  entry isn't required for the OS to round-trip it; the exported-as form
//  registers the identifier for this process's drag sessions.
//

import AtelierCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The app-private drag identifier for a set of asset ids + their source.
    static let assetIDs = UTType(exportedAs: "com.ref-atelier.asset-ids")
}

/// A dragged set of assets and where they came from (009 · N3). `Codable` for the
/// transfer representation; `Equatable` for tests.
struct AssetDragPayload: Codable, Equatable, Transferable {
    /// The dragged assets, in the source's feed order.
    var assetIDs: [UUID]
    /// The collection the drag started from — lets a drop distinguish a
    /// same-collection reorder from a cross-collection move, and enforce the
    /// `from == to` no-op.
    var sourceCollectionID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .assetIDs)
    }
}
