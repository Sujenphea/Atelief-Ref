//
//  AssetPasteboard.swift
//  AtelierRefs
//
//  052 · B1 (export Copy path) — the kind-aware ⌘C contract (8A) and the general
//  pasteboard writer. Sits on top of the 011 out-flow layer: an image / video
//  reuses `AssetExport.exportItem` verbatim (one naming rule, one blob-URL truth),
//  while media-less kinds (color / link / tweet) copy as text. Selection retrieval
//  is unified (4A) — grid, canvas, and detail all map their selection to an ordered
//  `[(asset, source)]` and call `AssetExport.exportSelection`, so the "what gets
//  copied" logic exists once. Partial results are reported, never silent (7A).
//

import AppKit
import AtelierCore
import Foundation

/// One selected asset's copy payload. A byte-backed kind copies as its on-disk
/// original (``AssetExportItem`` — file URL + filename + type); a media-less kind
/// copies as text (a color's hex, a link's / tweet's URL).
nonisolated enum AssetPasteboardEntry: Equatable {
    case file(AssetExportItem)
    case text(String)
}

/// A selection resolved to ordered pasteboard entries plus the count of selected
/// assets that yielded nothing copyable (7A): a media-less `.unknown`, or an
/// image / video whose blob file is missing. `skipped` drives the partial-copy
/// report; it is never a silent drop.
struct ExportSelection: Equatable {
    let entries: [AssetPasteboardEntry]
    let skipped: Int

    var isEmpty: Bool { entries.isEmpty }
    /// Total assets considered (copied + skipped) — the report denominator.
    var considered: Int { entries.count + skipped }
}

extension AssetExport {

    /// The 8A kind-aware entry for one asset, or `nil` when there is nothing to
    /// copy. An asset with usable **image/video bytes copies as its on-disk
    /// original** — including a link's og:image and a tweet's card image, which
    /// render as image cards, so ⌘C must yield the image, not a URL (052 · B1 fix).
    /// Only a *byte-less* asset falls back to kind-specific text:
    /// - `.color` → the canonical `#rrggbb` hex.
    /// - `.link` (no og:image) → the saved URL.
    /// - `.tweet` (no card image) → the tweet's permalink (no URL field is stored,
    ///   so it is rebuilt from the handle + id, falling back to `/i/status/`).
    /// - `.image` / `.video` with a missing blob, or `.unknown` → `nil` (skip).
    static func pasteboardEntry(
        asset: Asset, source: Source?, blobURL: URL?
    ) -> AssetPasteboardEntry? {
        // Any asset backed by an on-disk image/video (still image, video, OR a
        // link/tweet whose image bytes were captured) copies as that file — the
        // asset's `blobHash` is the card/og image in the link/tweet cases.
        if let item = exportItem(asset: asset, source: source, blobURL: blobURL) {
            return .file(item)
        }
        // No copyable bytes → the kind's text fallback (or nothing).
        return textFallback(for: asset)
    }

    /// The words that stand in for an asset with no exportable bytes:
    /// - `.color` → the canonical `#rrggbb` hex.
    /// - `.link` → the saved URL.
    /// - `.tweet` → the tweet's permalink (no URL field is stored, so it is rebuilt
    ///   from the handle + id, falling back to `/i/status/`).
    /// - `.image` / `.video` / `.unknown` → `nil`; a picture is not text.
    ///
    /// Named and public rather than left inline inside
    /// ``pasteboardEntry(asset:source:blobURL:)`` because a second caller wanted
    /// exactly this and could only reach it by passing that function a nil `source`
    /// AND a nil `blobURL` so it would fail through to here — which worked, but
    /// asked for the fallback by arranging for everything else to fail rather than
    /// by saying so. It also meant the same asset could be described differently
    /// depending on which caller asked, since one passed a real `source` and the
    /// other could not.
    ///
    /// Reads only `asset.content`: none of the three branches needs a `Source`,
    /// which is what makes it safe to call where no source is at hand.
    static func textFallback(for asset: Asset) -> AssetPasteboardEntry? {
        switch asset.content {
        case .color(let hex):
            return .text(hex)
        case .link(let link):
            return .text(link.url)
        case .tweet(let tweet):
            return .text(tweetPermalink(tweet))
        case .image, .video, .unknown:
            return nil
        }
    }

    /// Map an ordered selection to its pasteboard entries, preserving order and
    /// counting the skips (7A). The single selection→entries assembly shared by
    /// grid, canvas, and detail (4A) — each surface only supplies its ordered
    /// `(asset, source)` pairs and a blob-URL resolver.
    static func exportSelection(
        assets: [(asset: Asset, source: Source?)], blobURL: (Asset) -> URL?
    ) -> ExportSelection {
        var entries: [AssetPasteboardEntry] = []
        entries.reserveCapacity(assets.count)
        var skipped = 0
        for pair in assets {
            if let entry = pasteboardEntry(
                asset: pair.asset, source: pair.source, blobURL: blobURL(pair.asset)) {
                entries.append(entry)
            } else {
                skipped += 1
            }
        }
        return ExportSelection(entries: entries, skipped: skipped)
    }

    /// An x.com permalink for a tweet: `@handle` (a leading `@` dropped) + status id
    /// when a handle is known, else the handle-less `/i/status/` form Twitter/X
    /// resolves. `TweetContent` stores no canonical URL, so it is reconstructed.
    private static func tweetPermalink(_ tweet: TweetContent) -> String {
        if let handle = tweet.authorHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !handle.isEmpty {
            let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            return "https://x.com/\(bare)/status/\(tweet.tweetID)"
        }
        return "https://x.com/i/status/\(tweet.tweetID)"
    }
}

/// Writes a resolved ``ExportSelection`` to an `NSPasteboard` per the 8A contract.
/// Stateless — the general pasteboard is passed in so a scratch board can be used
/// under test (11A).
enum AssetPasteboardWriter {

    /// Clear `pasteboard` and write the selection's representations:
    /// - a `.file` entry writes its blob's **file URL** (Finder + drag-target apps),
    ///   and — only when a SINGLE image/video is copied — also the decoded `NSImage`
    ///   so editors get pixels; multi-select stays URL-only to avoid N eager decodes.
    /// - a `.text` entry writes its string.
    ///
    /// Returns the number of entries written (0 for an empty selection, which still
    /// clears the board). A single image whose `NSImage` fails to decode still
    /// writes the file URL — the copy is never wholly lost to a decode failure.
    @discardableResult
    static func write(_ selection: ExportSelection, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        guard !selection.entries.isEmpty else { return 0 }

        let includeImageData = selection.entries.count == 1
        var objects: [NSPasteboardWriting] = []
        for entry in selection.entries {
            switch entry {
            case .file(let item):
                objects.append(item.blobURL as NSURL)
                if includeImageData, let image = NSImage(contentsOf: item.blobURL) {
                    objects.append(image)
                }
            case .text(let string):
                objects.append(string as NSString)
            }
        }
        pasteboard.writeObjects(objects)
        return selection.entries.count
    }

    /// Append the app-private ``AssetDragPayload`` representation of the SAME copy
    /// to a board ``write(_:to:)`` has just filled (019 · C1) — the second half of
    /// the dual write the board already does for its elements (065 §2.4).
    ///
    /// **Order is load-bearing**: ``write(_:to:)`` calls `clearContents()`, so this
    /// can only ever run AFTER it, never before. Writing it last also keeps the file
    /// URL the PREFERRED type for an external receiver — the `.assetIDs` identifier
    /// conforms to `public.data`, so a promiscuous app could otherwise match it.
    ///
    /// The ids are the WHOLE selection, not just ``ExportSelection/entries``: a
    /// paste by id needs no bytes, so a media-less `.unknown` or a missing-blob
    /// image — which the byte representation had to skip — still pastes in-app.
    ///
    /// "nil, not empty" (065 §2.4): an EMPTY selection writes NOTHING rather than an
    /// empty payload, so a later ⌘V falls through to the importer instead of
    /// matching a copy that carried no assets. Returns whether bytes went on.
    @discardableResult
    static func appendAssetIDs(
        _ assetIDs: [UUID], from sourceCollectionID: UUID, to pasteboard: NSPasteboard
    ) -> Bool {
        guard !assetIDs.isEmpty else { return false }
        let payload = AssetDragPayload(
            assetIDs: assetIDs, sourceCollectionID: sourceCollectionID)
        guard let data = try? payload.pasteboardData() else { return false }
        return pasteboard.setData(data, forType: AssetDragPayload.pasteboardType)
    }
}
