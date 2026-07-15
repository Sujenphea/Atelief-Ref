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
//  The custom `UTType` is BOTH declared in `Info.plist`
//  (`UTExportedTypeDeclarations`, conforming to `public.data`) AND mirrored here
//  via `UTType(exportedAs:)`. The Info.plist declaration is load-bearing: without
//  it the OS doesn't recognize the identifier at a drop destination, so every
//  drag (reorder / stack-move / rail-move) shows an invalid cursor and snaps back.
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
