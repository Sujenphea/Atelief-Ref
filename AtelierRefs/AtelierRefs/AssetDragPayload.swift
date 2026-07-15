//
//  AssetDragPayload.swift
//  AtelierRefs
//
//  The payload carried by an intra-app grid drag (drag-to-reorder). A DISTINCT
//  `Transferable` type — not a bare `String`/`URL` — so the grid's per-tile drop
//  target only ever matches an internal reorder drag. External content (a Finder
//  file, a browser image, a dragged web URL) advertises `.image`/`.fileURL`/`.url`
//  and never decodes as this type, so it falls THROUGH the tile to the collection's
//  container `.onDrop` for import instead of being mis-read as a reorder. The
//  routing is correct by type, not by hit-test luck.
//
//  Single-asset today; the multi-select `assetIDs` + ⌥-copy variant is deferred to
//  009 (`.docs/feature-todo/009-multiselect-move.md`) — this is its seed.
//
//  The transfer representation rides on `.json` (a concrete `public.json`) rather
//  than a bespoke exported UTI: the app builds its Info.plist via
//  GENERATE_INFOPLIST_FILE, which can't express a `UTExportedTypeDeclarations`
//  array, and `.json` is already non-overlapping with every external drop type +
//  plain text — so it gives the same type-separation guarantee with no plist work.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The `Transferable` payload for an intra-app grid reorder drag: the asset being
/// moved. Its `Codable`/`Transferable` round-trip is unit-tested (`AssetDragPayloadTests`).
struct AssetDragPayload: Codable, Equatable, Transferable {
    /// The dragged asset's stable id (the grid drag payload is asset-keyed, matching
    /// the reorder math in `GridReorder.swift`).
    let assetID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
