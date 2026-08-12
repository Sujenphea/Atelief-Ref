//
//  AssetFolderExport.swift
//  AtelierRefs
//
//  011 · A2 — the app↔`AtelierExport` bridge for a selection exported as a FOLDER
//  OF ORIGINALS:
//
//      <chosen folder>/nike-ad-3f2a91c4.jpg
//      <chosen folder>/clip-c40f9a2e.mp4
//
//  The fourth consumer of one export layer, and the one that adds least: no
//  layout, no captions, no renderer. It is `AssetExport`'s naming rule plus
//  `ExportNameAllocator`'s folder-uniqueness, handed to `AssetFolderWriter`.
//  011's out-flow cluster shipped the per-item half of this (drag-out, ⌘C) and
//  named this the missing piece; `AssetExport.swift:6` has pointed at it since,
//  and `ExportNameAllocator` was written for exactly this caller — many names
//  side by side in one destination.
//
//  Two places where it deliberately differs from `CollectionSiteExport`, which is
//  otherwise its closest sibling:
//
//   • **Videos export as the video.** The web page copies a poster frame on
//     purpose (a page meant for email should not smuggle a 300 MB movie). Here
//     the originals ARE the product, so a video contributes its own bytes; a
//     folder that silently substituted stills would answer a question nobody
//     asked.
//   • **Nothing is invented for a byte-less ref.** A colour swatch, or a link /
//     tweet whose image was never captured, has no file — so it is counted in
//     `skipped` and reported in the completion toast, never turned into a
//     sidecar the user never asked for. (`AssetExport.pasteboardEntry`'s text
//     fallbacks stay a ⌘C affordance, where the destination is a text field.)
//
//  Everything here is PURE given the blob-URL resolver, so the mapping, the skips
//  and the collision handling are unit-tested host-free in
//  `AssetFolderExportTests`.
//

import AtelierCore
import AtelierExport
import Foundation

// Isolation follows `CollectionSiteExport`'s (the app target defaults to
// `MainActor`): every call site is a view or the export controller, and the
// off-main work happens later, on package value types that are `Sendable`.
enum AssetFolderExport {

    /// A ready-to-write export: the files to copy, and how many selected refs had
    /// nothing to copy at all.
    struct Plan: Equatable {
        /// The originals to place in the folder, in feed order and uniquely named.
        var files: [ExportFile]
        /// Refs with no bytes to export — a media-less colour / link / tweet, or a
        /// blob already gone from disk. Reported, never silently dropped.
        var skipped: Int

        var isEmpty: Bool { files.isEmpty }
    }

    /// The rows an export considers: the selection when any are selected, else the
    /// whole collection. Delegated rather than re-implemented — this is the one
    /// scope rule all four exports share (052 · B3), and a fourth copy of a
    /// one-line filter is a fourth thing that can drift.
    static func rows(
        items: [CollectionItemDetail], selectedIDs: Set<UUID>
    ) -> [CollectionItemDetail] {
        ContactSheetExport.rows(items: items, selectedIDs: selectedIDs)
    }

    /// Map collection rows → a ``Plan``.
    ///
    /// - Parameters:
    ///   - details: the rows to export, in feed order.
    ///   - blobURL: full-resolution original for an asset (the app passes
    ///     `IngestionModel.blobURL(forAsset:)`). EVERY byte-backed kind resolves
    ///     through this one resolver, video included — see the file note.
    static func plan(
        details: [CollectionItemDetail],
        blobURL: (Asset) -> URL?
    ) -> Plan {
        var files: [ExportFile] = []
        var names = ExportNameAllocator()
        // The same blob backing two rows keeps ONE name (and one copy) instead of
        // being disambiguated into two identical files.
        var assigned: Set<URL> = []
        var skipped = 0

        for detail in details {
            // `exportItem` is the shared naming + existence check (011 · 5A): a
            // media-less kind, a missing URL and a reaped blob all come back nil,
            // which is precisely the set this export has to skip.
            guard let export = AssetExport.exportItem(
                asset: detail.asset, source: detail.source,
                blobURL: blobURL(detail.asset))
            else {
                skipped += 1
                continue
            }

            // A second row on the same blob is not a skip and not a second file —
            // it is the file already claimed.
            guard assigned.insert(export.blobURL).inserted else { continue }

            files.append(ExportFile(
                source: export.blobURL, filename: names.claim(export.filename)))
        }

        return Plan(files: files, skipped: skipped)
    }

    /// The folder name the save panel suggests. The web page's rule verbatim —
    /// the collection's name through the shared sanitizer, with a whitespace-only
    /// name falling back to `"Refs"` rather than to `sanitize`'s `"image"` (which
    /// is the right word for one file and the wrong one for a folder of many).
    static func folderName(for collectionName: String) -> String {
        CollectionSiteExport.folderName(for: collectionName)
    }
}
