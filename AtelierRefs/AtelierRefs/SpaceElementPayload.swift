//
//  SpaceElementPayload.swift
//  AtelierRefs
//
//  065 — copying a piece of a board to the pasteboard, so ⌘C / ⌘V works on text
//  boxes and frames rather than silently doing nothing.
//
//  Before this, `SpaceView.onCopyTiles` `compactMap`ed the selection down to rows that
//  HAVE an asset, so ⌘C on a text box put nothing on the pasteboard and ⌘V had nothing
//  to rebuild it from. Assets already had a representation — ``AssetDragPayload`` — but
//  that one carries asset *ids* for a collection to reference, which says nothing about
//  where on a board the tiles sat or what a text box's style was.
//
//  So this is a second, complementary representation, written ALONGSIDE the asset one
//  rather than instead of it: a copied selection can then be pasted onto a board as a
//  faithful piece of layout, or onto a collection as plain references, and neither
//  destination has to know about the other's needs.
//
//  Geometry is stored RELATIVE to the copied selection's top-left, never absolute.
//  That is what lets a paste land where the user is looking — at the viewport centre,
//  or the drop point — while keeping the pieces' arrangement intact.
//
//  Unlike ``AssetDragPayload`` this needs no `Info.plist` `UTExportedTypeDeclarations`
//  entry: that declaration exists so the OS recognises the identifier at a DRAG
//  destination, and this type is only ever read from the general pasteboard by this
//  app's own paste. Keeping it out of the plist keeps it honestly app-private.
//

import AppKit
import AtelierCore
import Foundation

/// A copied piece of a board: its rows, with geometry relative to the selection's
/// top-left corner.
struct SpaceElementPayload: Codable, Equatable {
    /// One copied row. Deliberately NOT a `SpaceItem`: an id, a `spaceID` and the
    /// timestamps are facts about the row it was copied from, and carrying them would
    /// invite a paste that re-uses them. What survives a copy is what the user can see.
    struct Row: Codable, Equatable {
        var kind: SpaceItemKind
        /// Set for asset rows — a paste makes another *placement* of the same asset,
        /// never a second asset.
        var assetID: UUID?
        /// `ElementStyle` JSON for element rows; `nil` for asset rows.
        var style: String?
        /// Offset from the copied selection's top-left.
        var dx: Double
        var dy: Double
        var w: Double
        var h: Double
        /// Relative stacking within the copy, normalised to start at 0, so a paste can
        /// stack the pieces correctly on top of whatever is already on the board.
        var z: Int
    }

    var rows: [Row]

    /// Build a payload from board rows. Empty in → empty out, so a caller need not
    /// pre-check.
    ///
    /// The anchor is the selection's own bounding-box origin, and `z` is normalised to
    /// start at zero: both make the payload independent of *where* it was copied from,
    /// which is the whole point of a clipboard.
    init(items: [SpaceItem]) {
        let ordered = items.sorted { $0.z < $1.z }
        let originX = ordered.map(\.x).min() ?? 0
        let originY = ordered.map(\.y).min() ?? 0
        let baseZ = ordered.map(\.z).min() ?? 0
        rows = ordered.map { item in
            Row(kind: item.kind, assetID: item.assetID, style: item.style,
                dx: item.x - originX, dy: item.y - originY,
                w: item.w, h: item.h, z: item.z - baseZ)
        }
    }

    /// Rebuild board rows for `spaceID`, with the copy's top-left at `origin` and
    /// stacked from `startZ`. Fresh ids: a paste is a create, never a restore.
    func rows(
        forSpaceID spaceID: UUID, at origin: CGPoint, startZ: Int,
        now: Date = Date(), makeID: () -> UUID = UUID.init
    ) -> [SpaceItem] {
        rows.map { row in
            SpaceItem(
                id: makeID(), spaceID: spaceID, kind: row.kind, assetID: row.assetID,
                x: Double(origin.x) + row.dx, y: Double(origin.y) + row.dy,
                w: row.w, h: row.h, z: startZ + row.z,
                style: row.style, createdAt: now, updatedAt: now)
        }
    }

    /// The copy's size, so a caller can centre it on a paste point rather than hanging
    /// it off to the bottom-right.
    var size: CGSize {
        let maxX = rows.map { $0.dx + $0.w }.max() ?? 0
        let maxY = rows.map { $0.dy + $0.h }.max() ?? 0
        return CGSize(width: maxX, height: maxY)
    }
}

// MARK: - NSPasteboard bridge

extension SpaceElementPayload {
    /// App-private, and distinct from ``AssetDragPayload/pasteboardType`` so both can
    /// sit on one pasteboard without either shadowing the other.
    static let pasteboardType = NSPasteboard.PasteboardType("com.ref-atelier.space-elements")

    func pasteboardData() throws -> Data { try JSONEncoder().encode(self) }

    /// Decode a payload off a pasteboard, or `nil` when it carries none / carries a
    /// malformed one. A copy with no rows reads as `nil` too — an empty payload is
    /// indistinguishable from nothing to paste, and treating it as a hit would let it
    /// swallow the paste from the branches below it.
    static func decode(from pasteboard: NSPasteboard) -> SpaceElementPayload? {
        guard let data = pasteboard.data(forType: pasteboardType),
              let payload = try? JSONDecoder().decode(SpaceElementPayload.self, from: data),
              !payload.rows.isEmpty else { return nil }
        return payload
    }
}
