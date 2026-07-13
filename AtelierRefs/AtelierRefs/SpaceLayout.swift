//
//  SpaceLayout.swift
//  AtelierRefs
//
//  Pure, testable placement math for spaces (005-E2). A space_item ALWAYS has a
//  concrete world rect (unlike the nullable folder `canvas_*`), so placements
//  are computed at ADD time — here — rather than lazily in the provider. The
//  justified-rows flow mirrors the folder canvas's `CanvasContent.layout`, kept
//  SwiftUI-free so it can be unit-tested directly (the `GridNavigation` pattern).
//

import AtelierCore
import Foundation

/// One computed world-space placement for a space item.
struct PlacedRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var z: Int
}

/// Placement helpers for spaces. All world units.
enum SpaceLayout {
    static let rowHeight: Double = 240
    static let spacing: Double = 16
    static let maxRowWidth: Double = 1600

    /// Display aspect ratio (w/h) of an asset; a safe `1` for missing dimensions.
    static func aspect(_ asset: Asset) -> Double {
        guard asset.width > 0, asset.height > 0 else { return 1 }
        return Double(asset.width) / Double(asset.height)
    }

    /// Flow a batch of NEW items into justified rows starting at `startY`, with
    /// z-order increasing from `startZ`. Each aspect packs left→right at
    /// ``rowHeight``, wrapping when the row would exceed ``maxRowWidth``. Used
    /// when adding assets to an existing space (appended below current content).
    static func flowIn(aspects: [Double], startY: Double, startZ: Int) -> [PlacedRect] {
        var rects: [PlacedRect] = []
        rects.reserveCapacity(aspects.count)
        var penX: Double = 0
        var penY: Double = startY
        var rowStart = true
        var z = startZ

        for aspect in aspects {
            let width = rowHeight * max(aspect, 0.01)
            if !rowStart, penX + spacing + width > maxRowWidth {
                penX = 0
                penY += rowHeight + spacing
                rowStart = true
            }
            if !rowStart { penX += spacing }
            rects.append(PlacedRect(x: penX, y: penY, w: width, h: rowHeight, z: z))
            penX += width
            rowStart = false
            z += 1
        }
        return rects
    }

    /// Seed placements for a NEW space from a collection's items (the "New Space
    /// from this collection" action). Items with an explicit folder-canvas
    /// placement (`canvas_x/y/w/h`) keep it; the rest flow into justified rows
    /// starting BELOW the bounding box of the placed ones — mirroring
    /// `CanvasContent.layout` so a seeded space reproduces the folder canvas the
    /// user last arranged. Index-aligned to `items`.
    static func placements(seedingFrom items: [CollectionItemDetail]) -> [PlacedRect] {
        // First pass: where does the free-flow region start (below placed tiles)?
        var flowStartY: Double = 0
        for detail in items {
            if detail.item.canvasX != nil, detail.item.canvasW != nil,
               let y = detail.item.canvasY, let h = detail.item.canvasH {
                flowStartY = max(flowStartY, y + h + spacing)
            }
        }

        var rects: [PlacedRect] = []
        rects.reserveCapacity(items.count)
        var penX: Double = 0
        var penY: Double = flowStartY
        var rowStart = true

        for (index, detail) in items.enumerated() {
            if let x = detail.item.canvasX, let y = detail.item.canvasY,
               let w = detail.item.canvasW, let h = detail.item.canvasH {
                rects.append(PlacedRect(x: x, y: y, w: w, h: h, z: detail.item.canvasZ ?? index))
                continue
            }
            let width = rowHeight * aspect(detail.asset)
            if !rowStart, penX + spacing + width > maxRowWidth {
                penX = 0
                penY += rowHeight + spacing
                rowStart = true
            }
            if !rowStart { penX += spacing }
            rects.append(PlacedRect(x: penX, y: penY, w: width, h: rowHeight, z: index))
            penX += width
            rowStart = false
        }
        return rects
    }
}
