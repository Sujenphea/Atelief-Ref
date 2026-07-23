//
//  CollectionDragPayload.swift
//  AtelierRefs
//
//  043 — the drag payload for REPARENTING a collection (a collection dragged onto
//  another to nest it, or onto empty space to un-nest). Distinct from
//  ``AssetDragPayload``: that carries a set of assets + their source collection
//  for asset moves; this carries ONE collection id — the folder being reparented.
//  Kept a separate `UTType` so a folder drag can never be mistaken for an asset
//  drag at a drop target, and vice-versa.
//
//  Both the drag source (gallery cards, sidebar rows) and the drop targets are
//  pure SwiftUI, so the SwiftUI-native `.draggable` / `.dropDestination` path is
//  enough — the provider carries `.collectionID`. The `UTType` is ALSO declared in
//  `Info.plist` (`UTExportedTypeDeclarations`), mirroring the asset-ids type, so
//  the OS recognizes the identifier at the drop destination (without it the drag
//  shows an invalid cursor and snaps back).
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The app-private drag identifier for a single collection being reparented.
    static let collectionID = UTType(exportedAs: "com.ref-atelier.collection-id")
}

/// A dragged collection (the folder to reparent). `Codable` for the transfer
/// representation; `Equatable` for tests.
struct CollectionDragPayload: Codable, Equatable, Transferable {
    /// The collection being dragged / reparented.
    var collectionID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .collectionID)
    }
}
