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
import AtelierArchive
import AtelierCore
import Foundation

/// One selected asset's copy payload. A byte-backed kind copies as its on-disk
/// original (``AssetExportItem`` — file URL + filename + type); a media-less kind
/// copies as text (a color's hex, a link's / tweet's URL).
nonisolated enum AssetPasteboardEntry: Equatable {
    case file(AssetExportItem)
    case text(String)

    /// The words this entry contributes to a copy's plain-text flavour (464): a
    /// `.text` entry's string, and NOTHING for a `.file` — a picture's bytes are
    /// not words, and its file path is not what the user copied a picture for.
    var text: String? {
        if case .text(let string) = self { return string }
        return nil
    }
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

    /// The WORDS of an ordered asset selection (465) — Edit ▸ Copy as Text, where
    /// `⌘C`'s rich flavours are deliberately absent.
    ///
    /// The same per-asset rule ``pasteboardEntry(asset:source:blobURL:)`` uses, so
    /// what a text copy says about an asset never differs from what the fallback
    /// string of a rich copy said: media contribute nothing, a colour its hex, a
    /// link its URL, a tweet its permalink.
    static func copiedText(
        assets: [(asset: Asset, source: Source?)], blobURL: (Asset) -> URL?
    ) -> String? {
        CopyText.joined(assets.map { pair in
            pasteboardEntry(
                asset: pair.asset, source: pair.source,
                blobURL: blobURL(pair.asset))?.text
        })
    }

    /// Whether `asset` would contribute words — answered CHEAPLY, for menu
    /// validation (465).
    ///
    /// A missing / empty `blobHash` stands in for "has no bytes to copy", which is
    /// what ``pasteboardEntry(asset:source:blobURL:)`` establishes with a
    /// `FileManager.fileExists` probe. The two disagree on exactly one row: one that
    /// CLAIMS a blob whose file is gone — the exact rule falls back to the kind's
    /// words, this one says no, and Copy as Text greys out on a library that is
    /// already broken.
    ///
    /// Asking exactly would cost a `stat` per selected asset on every evaluation of
    /// the menu's body — which for ⌘A over a large collection is every keystroke
    /// that moves the selection. That is the trade, and it is why this is a separate
    /// function with its own name rather than a quiet shortcut inside the other one.
    static func mayHaveText(_ asset: Asset) -> Bool {
        (asset.blobHash?.isEmpty ?? true) && textFallback(for: asset) != nil
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

/// The plain-text flavour of a copy (464) — what a ⌘C means to an app that only
/// takes words: a message box, a note, a text field.
///
/// Two rules make it, both MEASURED against a real `NSPasteboard` rather than
/// assumed:
///
/// 1. **Media are cut out, never described.** They already are, for free: an
///    `NSURL` written to a pasteboard declares `public.file-url` and NOTHING else,
///    so a file item contributes no string at all and a text field pasting a mixed
///    copy never lands `/…/blobs/ab12.png`. Only pieces that ARE words go on — a
///    board text box's string, a colour's hex, a link's URL.
///
///    **Being on the pasteboard is not the same as being reached** (465). A
///    receiver picks by calling `availableType(from:)`, which answers in the order
///    the RECEIVER asks — and every app that can take a file asks for a file first.
///    So in Notes, Messages, Mail and every rich editor, a copy holding both a
///    picture and a text box pastes the picture and never asks for these words.
///    That is what Edit ▸ Copy as Text (⌥⌘C) exists for: the same words, with no
///    file rep beside them to outrank them. See ``CopyText/write(only:to:)``.
/// 2. **One joined string on ONE pasteboard item.** `string(forType:)` returns the
///    CONCATENATION of every item's string, joined by a single `\n` — so N string
///    items do reach the receiver, but separated by a newline this code never chose
///    and in an order the item list happens to hold. Joining here instead means the
///    copy says one thing, with our separator, in the selection's own order.
enum CopyText {
    /// A blank line between pieces: two text boxes are two paragraphs, and a piece
    /// may itself span lines, so a single newline would run them together — which
    /// is precisely what the pasteboard's own concatenation used to do.
    static let separator = "\n\n"

    /// Join `pieces` IN THE ORDER GIVEN — the caller's order is the selection's
    /// own — trimming each and dropping the ones carrying nothing.
    ///
    /// `nil` rather than `""` when nothing survives, the "nil, not empty" rule the
    /// two payloads already follow (065 §2.4): a copy with no words puts no string
    /// item on the board at all, rather than an empty one for a receiver to paste
    /// as a blank line.
    static func joined(_ pieces: [String?]) -> String? {
        let kept = pieces
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }

    /// Put `text` on `pasteboard` and NOTHING else (465) — Edit ▸ Copy as Text.
    ///
    /// The whole point is the absence: a ⌘C that also writes a file URL is a copy
    /// every file-capable app reads as a file, because `availableType(from:)` answers
    /// in the order the RECEIVER asks and every rich editor asks for a file first.
    /// One string item is the only way to hand such an app the words.
    ///
    /// No app-private types either: a text copy pasted back onto a board makes a text
    /// box out of the words, rather than silently rebuilding a layout the user asked
    /// to have as text.
    @discardableResult
    static func write(only text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
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
    /// - every `.text` entry is joined into ONE trailing string item (464), rather
    ///   than one item each: `string(forType:)` concatenates the items it finds with
    ///   a `\n` of its own choosing, so N items let the PASTEBOARD decide how a copy
    ///   of three colours reads. Last, so the file URL stays what an external
    ///   receiver meets first.
    ///
    /// `text` OVERRIDES those joined words for a caller holding pieces this
    /// selection cannot see — a board, whose text boxes are not assets at all (464).
    /// It is the whole selection's words or nothing: passing a `text` that omits an
    /// asset's own words drops them, which is what a board wants when it has already
    /// interleaved them into its z-order.
    ///
    /// Returns the number of ENTRIES written — the byte-side count the copy report
    /// is about, which is 0 for a words-only copy. A selection with neither entries
    /// nor words still clears the board. A single image whose `NSImage` fails to
    /// decode still writes the file URL — the copy is never wholly lost to a decode
    /// failure.
    @discardableResult
    static func write(
        _ selection: ExportSelection, to pasteboard: NSPasteboard, text: String? = nil
    ) -> Int {
        pasteboard.clearContents()
        let words = text ?? CopyText.joined(selection.entries.map(\.text))
        // Words with no entries is a real copy (a board's text boxes), not an empty
        // one — only NEITHER is nothing to write.
        guard !selection.entries.isEmpty || words != nil else { return 0 }

        let includeImageData = selection.entries.count == 1
        var objects: [NSPasteboardWriting] = []
        for entry in selection.entries {
            // `.text` entries are not written here — they are in `words` above.
            guard case .file(let item) = entry else { continue }
            objects.append(item.blobURL as NSURL)
            if includeImageData, let image = NSImage(contentsOf: item.blobURL) {
                objects.append(image)
            }
        }
        if let words { objects.append(words as NSString) }
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
