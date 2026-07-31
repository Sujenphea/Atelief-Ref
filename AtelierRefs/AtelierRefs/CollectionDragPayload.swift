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

import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The app-private drag identifier for a single collection being reparented.
    /// `nonisolated` so the AppKit drag seams can read it off the main actor —
    /// under MainActor-by-default a bare `static let` in this target infers
    /// main-actor isolation, which a pasteboard type constant has no use for.
    nonisolated static let collectionID = UTType(exportedAs: "com.ref-atelier.collection-id")
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

// MARK: - NSPasteboard bridge (043 · Phase C)

/// The `NSOutlineView` sidebar drags via AppKit, so — like ``AssetDragPayload`` —
/// the folder payload needs an `NSPasteboard` form under the same `.collectionID`
/// identifier the SwiftUI `CodableRepresentation` uses. Byte-compatible (plain
/// `JSONEncoder`), so a drag started in the outline view is still readable by any
/// SwiftUI `.dropDestination(for:)` and vice-versa.
extension CollectionDragPayload {
    nonisolated static let pasteboardType =
        NSPasteboard.PasteboardType(UTType.collectionID.identifier)

    /// The wire bytes — exactly what `CodableRepresentation(contentType:)`
    /// serializes, so the two drag channels interoperate.
    func pasteboardData() throws -> Data { try JSONEncoder().encode(self) }

    /// Decode a payload from a drop's pasteboard bytes.
    static func decode(from data: Data) -> CollectionDragPayload? {
        try? JSONDecoder().decode(CollectionDragPayload.self, from: data)
    }

    /// An `NSPasteboardItem` carrying this payload under `.pasteboardType`, for the
    /// outline view's drag session. `nil` only if encoding fails (it cannot for
    /// this value type).
    func makePasteboardItem() -> NSPasteboardItem? {
        guard let data = try? pasteboardData() else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }
}

/// The resolved outcome of an outline-view drop (043 · Phase C), produced by the
/// pure `CollectionTargets.routeOutlineDrop(...)` and consumed by the coordinator.
/// Both a reparent and a same-parent reorder collapse to `.move` — they are the
/// same `moveCollection(id:toParent:index:)` op — so there is one path, not two.
nonisolated enum CollectionDrop: Equatable {
    /// Not a legal drop (self / descendant / protected / Unsorted target).
    case reject
    /// Apply `moveCollection(id: dragged, toParent:, index:)`. `index == nil`
    /// appends (a nest-onto-row drop); a value is the normalized slot.
    case move(toParent: UUID?, index: Int?)
}
