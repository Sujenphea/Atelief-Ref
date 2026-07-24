//
//  SpaceDragPayload.swift
//  AtelierRefs
//
//  043 (spaces) — the drag payload for REORDERING a space in the sidebar's flat
//  space list. The space analog of ``CollectionDragPayload``: it carries ONE space
//  id — the board being repositioned. Spaces don't nest, so there is no reparent —
//  only a slot change. Kept a separate `UTType` so a space drag can never be
//  mistaken for a collection or asset drag at a drop target, and vice-versa.
//
//  The `NSOutlineView` sidebar drags via AppKit, so — like the collection payload —
//  this needs an `NSPasteboard` form under a stable identifier. The `UTType` is
//  ALSO declared in `Info.plist` (`UTExportedTypeDeclarations`) so the OS
//  recognizes it at the drop destination (without it the drag shows an invalid
//  cursor and snaps back).
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The app-private drag identifier for a single space being reordered.
    static let spaceID = UTType(exportedAs: "com.ref-atelier.space-id")
}

/// A dragged space (the board to reposition). `Codable` for the pasteboard wire
/// form; `Equatable` for tests.
struct SpaceDragPayload: Codable, Equatable {
    /// The space being dragged / reordered.
    var spaceID: UUID

    static let pasteboardType = NSPasteboard.PasteboardType(UTType.spaceID.identifier)

    /// The wire bytes (plain `JSONEncoder`, mirroring ``CollectionDragPayload``).
    func pasteboardData() throws -> Data { try JSONEncoder().encode(self) }

    /// Decode a payload from a drop's pasteboard bytes.
    static func decode(from data: Data) -> SpaceDragPayload? {
        try? JSONDecoder().decode(SpaceDragPayload.self, from: data)
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

/// The resolved outcome of a spaces outline-view drop (043 · Phase C, spaces),
/// produced by the pure ``SpaceTargets/routeOutlineDrop(dragged:childIndex:spaces:)``
/// and consumed by the coordinator. Spaces are flat, so a drop is only ever a
/// same-list reorder — there is no nest / reparent case.
enum SpaceDrop: Equatable {
    /// Not a legal drop (e.g. an unknown dragged id).
    case reject
    /// Apply `moveSpace(id: dragged, index:)`. `index == nil` appends (a drop past
    /// the last row); a value is the normalized slot.
    case move(index: Int?)
}
