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

import AppKit
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

// MARK: - NSPasteboard bridge (036 §4 A3 — byte-compatible with the SwiftUI drag)

extension AssetDragPayload {
    /// The pasteboard type the AppKit drag writes under — the SAME identifier the
    /// `.assetIDs` `UTType` (and therefore the SwiftUI `CodableRepresentation`)
    /// uses, so a drag started on the AppKit grid lands on the still-SwiftUI drop
    /// rail / stack row / Spaces exactly as the SwiftUI `.draggable` did.
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.assetIDs.identifier)

    /// The wire bytes for this payload — plain `JSONEncoder`, which is precisely
    /// what SwiftUI's `CodableRepresentation(contentType:)` serializes (036 §4 A3).
    /// This IS the interop contract: `AssetDragPayloadTests` pins that these bytes
    /// decode back through the same `Codable` form the SwiftUI drop targets use, so
    /// a drift here silently breaks drag-to-rail and the test catches it.
    func pasteboardData() throws -> Data { try JSONEncoder().encode(self) }

    /// An `NSPasteboardItem` carrying this payload's JSON under `.pasteboardType`,
    /// for `NSDraggingItem(pasteboardWriter:)`. `nil` only if encoding fails (it
    /// cannot for this value type).
    func makePasteboardItem() -> NSPasteboardItem? {
        guard let data = try? pasteboardData() else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }

    /// Decode a payload from a drop's pasteboard bytes — the inverse of
    /// ``pasteboardData()``, used by the AppKit cell-drop delegate.
    static func decode(from data: Data) -> AssetDragPayload? {
        try? JSONDecoder().decode(AssetDragPayload.self, from: data)
    }
}
