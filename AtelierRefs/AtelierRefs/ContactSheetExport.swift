//
//  ContactSheetExport.swift
//  AtelierRefs
//
//  052 · B4 — the app↔`AtelierExport` bridge for a COLLECTION contact sheet.
//  Unlike a Space board, a collection has no spatial layout, so this GENERATES
//  one: the app's own round-robin masonry (`MasonryLayout` — the exact grid the
//  collection screen shows) packs the assets into cells, each an image element
//  plus an optional caption text element below it. The result is a
//  `MoodboardExport.Mapping`, so the sheet flows through the identical B2/B3
//  pipeline (`MoodboardExport.pages` → `MoodboardRenderer` → `ExportController`)
//  — renderer, image provider, save panel, progress ring and toast are all
//  reused wholesale; B4 adds no package code.
//
//  Pure given the image-URL resolver, so the cell geometry + caption mapping are
//  unit-tested host-free in `ContactSheetExportTests`.
//

import AtelierCore
import AtelierExport
import CoreGraphics
import Foundation

// MARK: - Config

/// Contact-sheet–specific knobs layered on the shared ``ExportConfig`` (format /
/// PDF layout / PNG scale). These change the GENERATED element set (geometry), so
/// they feed the mapping here rather than the page plan.
struct ContactSheetConfig: Equatable {
    /// Masonry column count (clamped ≥ 1 at use).
    var columns: Int = 4
    /// Draw a caption (asset name / source) under each image.
    var captions: Bool = true
}

// MARK: - Bridge

enum ContactSheetExport {

    /// Layout constants for the generated sheet, in WORLD points. The page plan
    /// scales these to the chosen paper / PNG exactly like a moodboard, so the
    /// absolute values only set the working resolution + caption/image ratio.
    enum Defaults {
        /// The world-space width one masonry column spans (the image/cell width).
        static let columnWidth: Double = 240
        /// Gap between cells, both axes.
        static let spacing: Double = 12
        /// Height reserved for the caption block under an image.
        static let captionHeight: Double = 18
        /// Gap between an image's bottom edge and its caption.
        static let captionGap: Double = 4
        /// Caption font size (world units).
        static let captionFontSize: Double = 12
        /// Caption colour (muted grey).
        static let captionColor = RGBA(hex: "#6B6B6B") ?? .black
    }

    /// The rows an export considers: the selection when any are selected, else the
    /// whole collection (mirrors the moodboard's selection-or-all rule, 052 · B3).
    static func rows(
        items: [CollectionItemDetail], selectedIDs: Set<UUID>
    ) -> [CollectionItemDetail] {
        selectedIDs.isEmpty ? items : items.filter { selectedIDs.contains($0.item.id) }
    }

    /// Map collection rows → a contact-sheet ``MoodboardExport/Mapping``.
    ///
    /// Renderable rows keep their input order and are packed round-robin into
    /// `config.columns` masonry columns (the same `MasonryLayout` the grid uses).
    /// Each becomes an image element at its cell; with captions on, a text element
    /// (asset name / source) sits below it, its height reserved in the cell so it
    /// never overlaps the next row. A row whose asset resolves to neither an image
    /// nor a colour is skipped and counted (reported like the moodboard, 052 · 7A)
    /// — and, crucially, occupies NO cell, so the grid stays gap-free.
    ///
    /// - Parameter imageURL: resolves an asset to a decodable image URL (the app
    ///   passes `IngestionModel.previewImageURL(forAsset:)`); `nil` ⇒ no raster.
    static func map(
        details: [CollectionItemDetail],
        config: ContactSheetConfig,
        imageURL: (Asset) -> URL?
    ) -> MoodboardExport.Mapping {
        let columns = max(1, config.columns)
        let colWidth = Defaults.columnWidth
        let spacing = Defaults.spacing

        // Keep only rows that draw something; skips take no cell (no holes).
        var kept: [(content: MoodboardContent, caption: String, aspect: Double)] = []
        var urls: [String: URL] = [:]
        var skipped = 0
        for detail in details {
            guard let content = content(for: detail.asset, imageURL: imageURL, urls: &urls) else {
                skipped += 1
                continue
            }
            kept.append((content, caption(for: detail), aspect(for: detail)))
        }
        guard !kept.isEmpty else {
            return MoodboardExport.Mapping(elements: [], imageURLs: urls, skipped: skipped)
        }

        // Reserve caption space by inflating each cell's height before masonry
        // packing: a cell's effective aspect is colWidth / (imageH + captionBlock),
        // so the round-robin column heights already account for the caption.
        let captionBlock = config.captions ? Defaults.captionGap + Defaults.captionHeight : 0
        let effAspects = kept.map { colWidth / (colWidth / $0.aspect + captionBlock) }
        let availableWidth = Double(columns) * colWidth + Double(columns - 1) * spacing
        let frames = MasonryLayout.layout(
            aspects: effAspects, availableWidth: CGFloat(availableWidth),
            columns: columns, spacing: CGFloat(spacing)).frames

        var elements: [MoodboardElement] = []
        elements.reserveCapacity(kept.count * (config.captions ? 2 : 1))
        for (i, cell) in kept.enumerated() {
            let frame = frames[i]
            let imageH = colWidth / cell.aspect
            elements.append(MoodboardElement(
                rect: CGRect(x: frame.minX, y: frame.minY, width: colWidth, height: imageH),
                z: 0, content: cell.content))
            if config.captions, !cell.caption.isEmpty {
                let capY = Double(frame.minY) + imageH + Defaults.captionGap
                elements.append(MoodboardElement(
                    rect: CGRect(x: Double(frame.minX), y: capY,
                                 width: colWidth, height: Defaults.captionHeight),
                    z: 1,
                    content: .text(TextStyle(
                        string: cell.caption,
                        fontSize: Defaults.captionFontSize,
                        color: Defaults.captionColor))))
            }
        }
        return MoodboardExport.Mapping(elements: elements, imageURLs: urls, skipped: skipped)
    }

    // MARK: - Row content

    /// One asset's ``MoodboardContent``: a colour swatch, else an image when a URL
    /// resolves (image / video poster / image-backed card), registering its URL.
    /// `nil` for a row with nothing to draw (a skip).
    private static func content(
        for asset: Asset,
        imageURL: (Asset) -> URL?,
        urls: inout [String: URL]
    ) -> MoodboardContent? {
        switch asset.content {
        case .color(let hex):
            return RGBA(hex: hex).map { .color($0) }
        default:
            guard let url = imageURL(asset) else { return nil }
            let id = asset.id.uuidString
            urls[id] = url
            return .image(id: id)
        }
    }

    /// The caption under a cell: asset name → source title → author handle → the
    /// origin host, whichever resolves first; empty string when nothing does (the
    /// caption element is then omitted).
    static func caption(for detail: CollectionItemDetail) -> String {
        if let name = detail.asset.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty { return name }
        if let title = detail.source.title, !title.isEmpty { return title }
        if let handle = detail.source.authorHandle, !handle.isEmpty { return handle }
        if let raw = detail.source.originalURL, let host = URL(string: raw)?.host { return host }
        return ""
    }
}
