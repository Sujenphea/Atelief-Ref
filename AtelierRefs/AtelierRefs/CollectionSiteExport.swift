//
//  CollectionSiteExport.swift
//  AtelierRefs
//
//  014 · S3 — the app↔`AtelierExport` bridge for a COLLECTION exported as a
//  self-contained static web page:
//
//      <chosen folder>/index.html      zero JS, no network requests
//      <chosen folder>/assets/…        the image files
//
//  The third consumer of one export layer, and it adds no new naming, no new
//  layout math and no new concurrency shape:
//
//   • names come from `AssetExport` — the same sanitizer, the same 60-char cap,
//     the same `<base>-<shorthash>.<ext>` shape as drag-out — plus
//     `ExportNameAllocator`, which is the one thing a FOLDER needs that a single
//     drop never did (see there for the case-insensitive collision);
//   • captions come from `ContactSheetExport.caption(for:)`, so an image is
//     labelled identically whether it lands in a PDF or on a page;
//   • the page itself is `AtelierExport.StaticSiteRenderer`, golden-file pinned;
//   • the run is `ExportController`'s — same progress, same cancel flag, same
//     toast.
//
//  Everything here is PURE given the two URL resolvers, so the mapping, the
//  skips and the collision handling are unit-tested host-free in
//  `CollectionSiteExportTests`.
//
//  Videos are poster frames (014 · settled). The video file is not copied: an
//  HTML export that silently carried a 300 MB movie into a folder someone means
//  to email is not a favour, and `StaticSiteRenderer` marks the still with a
//  play glyph so the page says what it is.
//

import AtelierCore
import AtelierExport
import Foundation

// MARK: - Config

/// The web-page-specific knobs. Format has no meaning here (the output is
/// always a folder), so this replaces ``ExportConfig`` rather than layering on
/// it — the contact sheet's `ContactSheetConfig` pattern.
struct SiteExportConfig: Equatable {
    /// Masonry column count for the page (clamped by `SiteLayout`).
    var columns: Int = 4
    /// Draw the title line under each ref.
    var captions: Bool = true
    /// Draw the source link under each ref.
    ///
    /// Defaults to ON deliberately (014 · provenance option). Handing someone
    /// else's work on with its origin removed is a posture the user chooses,
    /// not one the app picks for them by leaving a box unticked.
    var sourceLinks: Bool = true
}

// MARK: - Bridge

// Isolation follows `ContactSheetExport`'s (the app target defaults to
// `MainActor`): every call site is a view or the export controller, and the
// off-main work happens later, on package value types that are `Sendable`.
enum CollectionSiteExport {

    /// A ready-to-write export: the page, the files it needs, and the rows that
    /// could not be represented at all.
    struct Plan: Equatable {
        var gallery: SiteGallery
        /// The files to place in `assets/`, in page order and uniquely named.
        var assets: [SiteAsset]
        /// Rows with nothing to put on a page — a media-less link/tweet, or a
        /// blob already gone from disk. Reported, never silently dropped.
        var skipped: Int

        var isEmpty: Bool { gallery.isEmpty }
    }

    /// The rows an export considers: the selection when any are selected, else
    /// the whole collection — the same rule the moodboard and contact sheet use.
    static func rows(
        items: [CollectionItemDetail], selectedIDs: Set<UUID>
    ) -> [CollectionItemDetail] {
        selectedIDs.isEmpty ? items : items.filter { selectedIDs.contains($0.item.id) }
    }

    /// Map collection rows → a ``Plan``.
    ///
    /// - Parameters:
    ///   - title: the page heading and `<title>` — the collection's name.
    ///   - blobURL: full-resolution original for an asset (the app passes
    ///     `IngestionModel.blobURL(forAsset:)`). Originals are copied rather
    ///     than re-encoded: a byte copy streams, needs no decoder, and keeps
    ///     `AssetExport`'s "the extension comes from the blob file" contract
    ///     exactly true.
    ///   - posterURL: the still for a video (the app passes
    ///     `IngestionModel.previewImageURL(forAsset:)`).
    static func plan(
        title: String,
        details: [CollectionItemDetail],
        config: SiteExportConfig,
        blobURL: (Asset) -> URL?,
        posterURL: (Asset) -> URL?
    ) -> Plan {
        var items: [SiteItem] = []
        var assets: [SiteAsset] = []
        var names = ExportNameAllocator()
        // The same blob backing two rows keeps ONE name (and one copy) instead
        // of being disambiguated into two identical files.
        var assigned: [URL: String] = [:]
        var skipped = 0

        for detail in details {
            let asset = detail.asset

            // A colour ref costs no file at all — CSS paints it.
            if case .color(let hex) = asset.content {
                guard RGBA(hex: hex) != nil else { skipped += 1; continue }
                items.append(SiteItem(
                    media: .color(hex: hex),
                    caption: ContactSheetExport.caption(for: detail),
                    sourceURL: detail.source.originalURL))
                continue
            }

            let isVideo: Bool
            if case .video = asset.content { isVideo = true } else { isVideo = false }
            // A video contributes its poster; everything else its original.
            let source = isVideo ? posterURL(asset) : blobURL(asset)

            // `exportItem` is the shared naming + existence check (5A): a
            // media-less kind, a missing URL and a reaped blob all come back nil.
            guard let export = AssetExport.exportItem(
                asset: asset, source: detail.source, blobURL: source)
            else {
                skipped += 1
                continue
            }

            let filename: String
            if let already = assigned[export.blobURL] {
                filename = already
            } else {
                filename = names.claim(export.filename)
                assigned[export.blobURL] = filename
                assets.append(SiteAsset(source: export.blobURL, filename: filename))
            }

            items.append(SiteItem(
                media: isVideo
                    ? .video(posterFile: filename,
                             pixelWidth: asset.width, pixelHeight: asset.height)
                    : .image(file: filename,
                             pixelWidth: asset.width, pixelHeight: asset.height),
                caption: ContactSheetExport.caption(for: detail),
                sourceURL: detail.source.originalURL))
        }

        return Plan(
            gallery: SiteGallery(
                title: title, items: items, columns: config.columns,
                includeCaptions: config.captions, includeSources: config.sourceLinks),
            assets: assets,
            skipped: skipped)
    }

    /// The folder name the save panel suggests for `collectionName`, run through
    /// the shared sanitizer so a collection called `Refs / Q3` cannot propose a
    /// path separator.
    ///
    /// A name that is nothing but whitespace short-circuits: `sanitize` falls
    /// back to `"image"`, which is the right word for one file and the wrong one
    /// for a folder of many.
    static func folderName(for collectionName: String) -> String {
        let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Refs" : AssetExport.sanitize(trimmed)
    }
}
