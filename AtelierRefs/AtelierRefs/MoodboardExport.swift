//
//  MoodboardExport.swift
//  AtelierRefs
//
//  052 · B3 — the app↔`AtelierExport` bridge. The package is pure and knows
//  nothing of `SpaceItem` / `AssetContent`; this file maps a board's
//  `SpaceItemDetail` rows into the package's world-space `MoodboardElement`
//  model, chooses the page layout for an `ExportConfig`, and vends the lazy
//  image provider backed by the shared `ImageDecoding` downsampler (052 · 16A).
//
//  Everything here except the provider's decode is PURE (given an image-URL
//  resolver closure), so the row→element mapping and the config→layout choice
//  are unit-tested host-free in `MoodboardExportTests`.
//

import AtelierCore
import AtelierExport
import AtelierIngestion
import CoreGraphics
import Foundation

// MARK: - Config

/// What the export popover produces: a container format plus the one
/// format-specific knob (PDF page layout, or PNG pixel scale).
enum ExportFormat: String, CaseIterable, Equatable {
    case pdf
    case png
}

/// PDF page strategy (the PDF-only second row of the popover).
enum PDFLayout: String, CaseIterable, Equatable {
    /// The whole board scaled onto a single page (a moodboard poster).
    case singlePage
    /// A fixed scale tiled across US-Letter pages (printable).
    case letterPages
}

/// The resolved export settings chosen in the popover.
struct ExportConfig: Equatable {
    var format: ExportFormat = .pdf
    var pdfLayout: PDFLayout = .singlePage
    /// PNG pixel scale (1×/2×/3× → pixels-per-point). Ignored for PDF.
    var pngScale: Int = 2

    /// The file extension the save panel should use for this config.
    var fileExtension: String { format == .pdf ? "pdf" : "png" }
}

// MARK: - Shared constants

/// The one home for the layout/render magic numbers, so the popover's page-count
/// preview and the actual render can't drift.
enum ExportDefaults {
    /// Uniform page margin in points.
    static let margin: Double = 24
    /// Longest edge of a single fit page, in points (≈ 28" at 72dpi — plenty).
    static let fitMaxDimension: Double = 2048
    /// US Letter in points.
    static let letterSize = CGSize(width: 612, height: 792)
    /// Pixels-per-point for images embedded in a PDF (2 = 144dpi).
    static let pdfImageScale: Double = 2
}

// MARK: - Mapping

/// The pure bridge from board rows to the render package.
enum MoodboardExport {

    /// The mapped result: renderable elements, the id→URL table the provider
    /// resolves, and a count of rows that couldn't be represented at all
    /// (media-less link/tweet, unknown) — surfaced as skips (052 · 7A).
    struct Mapping: Equatable {
        var elements: [MoodboardElement]
        var imageURLs: [String: URL]
        var skipped: Int

        var isEmpty: Bool { elements.isEmpty }
    }

    /// The rows an export considers (052 · B3 scope): the selection when any
    /// tiles are selected, else the whole board. Pure — takes plain values so
    /// it's unit-testable without a live `SpaceModel`.
    static func rows(items: [SpaceItemDetail], selected ids: Set<UUID>) -> [SpaceItemDetail] {
        ids.isEmpty ? items : items.filter { ids.contains($0.item.id) }
    }

    /// Map board rows → `MoodboardElement`s.
    ///
    /// - Asset rows: a `.color` renders as a swatch; any other kind renders as
    ///   an image when `imageURL` resolves one (covers image / video poster /
    ///   image-backed link & tweet cards uniformly), else it is skipped.
    /// - Element rows: `.text` / `.frame` render from their `ElementStyle`.
    ///
    /// - Parameter imageURL: resolves an asset to a decodable image URL (the app
    ///   passes `IngestionModel.previewImageURL(forAsset:)`); `nil` means the
    ///   asset has no rasterisable image.
    static func map(
        details: [SpaceItemDetail],
        imageURL: (Asset) -> URL?
    ) -> Mapping {
        var elements: [MoodboardElement] = []
        var urls: [String: URL] = [:]
        var skipped = 0

        for detail in details {
            let rect = CGRect(
                x: detail.item.x, y: detail.item.y,
                width: detail.item.w, height: detail.item.h)
            let z = detail.item.z

            guard let content = content(for: detail, imageURL: imageURL, urls: &urls) else {
                skipped += 1
                continue
            }
            elements.append(MoodboardElement(rect: rect, z: z, content: content))
        }
        return Mapping(elements: elements, imageURLs: urls, skipped: skipped)
    }

    /// Resolve one row's ``MoodboardContent``, registering an image URL as a side
    /// effect. Returns `nil` for a row that has nothing to draw (a skip).
    private static func content(
        for detail: SpaceItemDetail,
        imageURL: (Asset) -> URL?,
        urls: inout [String: URL]
    ) -> MoodboardContent? {
        // Element rows (frame / text) carry no asset — draw from their style.
        if let asset = detail.asset {
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

        let style = ElementStyle(jsonString: detail.item.style)
        switch detail.item.kind {
        case .text:
            return .text(textStyle(from: style))
        case .frame:
            return .frame(frameStyle(from: style))
        case .asset:
            // An asset-kind row with no resolved asset (reaped) — nothing to draw.
            return nil
        }
    }

    /// A ``TextStyle`` from an `ElementStyle`, applying moodboard defaults.
    private static func textStyle(from style: ElementStyle?) -> TextStyle {
        TextStyle(
            string: style?.text ?? "",
            fontSize: style?.fontSize ?? 17,
            color: style?.textColor.flatMap(RGBA.init(hex:)) ?? .black)
    }

    /// A ``FrameStyle`` from an `ElementStyle` (fill / stroke + optional label).
    private static func frameStyle(from style: ElementStyle?) -> FrameStyle {
        let label = (style?.text?.isEmpty == false) ? textStyle(from: style) : nil
        return FrameStyle(
            fill: style?.fillColor.flatMap(RGBA.init(hex:)),
            stroke: style?.strokeColor.flatMap(RGBA.init(hex:)),
            strokeWidth: style?.strokeWidth ?? 0,
            label: label)
    }

    // MARK: - Page plan

    /// Choose the pages for a config. Returns `[]` for an empty board (the caller
    /// treats that as nothing-to-export). `letterPages` derives a scale that fits
    /// the board WIDTH to one page and tiles downward, so the output is a normal
    /// top-to-bottom multi-page document rather than an unbounded grid.
    static func pages(for elements: [MoodboardElement], config: ExportConfig) -> [LayoutPage] {
        let layout = MoodboardLayout(margin: ExportDefaults.margin)
        switch (config.format, config.pdfLayout) {
        case (.png, _):
            return layout.fitToSinglePage(elements, maxDimension: ExportDefaults.fitMaxDimension)
        case (.pdf, .singlePage):
            return layout.fitToSinglePage(elements, maxDimension: ExportDefaults.fitMaxDimension)
        case (.pdf, .letterPages):
            guard let board = MoodboardLayout.boundingBox(of: elements), board.width > 0
            else { return [] }
            let contentWidth = ExportDefaults.letterSize.width - 2 * ExportDefaults.margin
            let scale = contentWidth / board.width
            return layout.paginate(
                elements, pageSize: ExportDefaults.letterSize, scale: scale)
        }
    }

    // MARK: - Render dispatch

    /// Render pre-laid-out pages to the container the config asks for. PDF takes
    /// every page; PNG is single-page (fit) at the chosen pixel scale.
    static func render(
        pages: [LayoutPage],
        provider: MoodboardImageProvider,
        config: ExportConfig,
        isCancelled: () -> Bool,
        onProgress: (Double) -> Void
    ) throws -> RenderResult {
        switch config.format {
        case .pdf:
            return try MoodboardRenderer.renderPDF(
                pages: pages, provider: provider,
                options: RenderOptions(background: .white, pixelsPerPoint: ExportDefaults.pdfImageScale),
                isCancelled: isCancelled, onProgress: onProgress)
        case .png:
            guard let page = pages.first else { throw ExportError.noPages }
            return try MoodboardRenderer.renderPNG(
                page: page, provider: provider,
                options: RenderOptions(background: .white, pixelsPerPoint: Double(config.pngScale)),
                isCancelled: isCancelled, onProgress: onProgress)
        }
    }
}

// MARK: - Image provider

/// A ``MoodboardImageProvider`` backed by an id→URL table, decoding each request
/// to its on-page footprint with the shared ``ImageDecoding`` downsampler
/// (052 · 13A/16A). A value type holding only `Sendable` state, so it rides into
/// the off-main render task cleanly.
struct MoodboardURLImageProvider: MoodboardImageProvider, Sendable {
    let urls: [String: URL]

    func cgImage(forID id: String, maxPixelSize: Int) -> CGImage? {
        guard let url = urls[id] else { return nil }
        return try? ImageDecoding.thumbnailCGImage(from: url, maxPixelSize: maxPixelSize)
    }
}
