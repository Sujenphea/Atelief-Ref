//
//  AssetShare.swift
//  AtelierRefs
//
//  011 · A3 — the share sheet, the last third of the out-flow cluster (A1 was
//  drag-out, A2 ⌘C and the originals folder). It adds no new export vocabulary at
//  all: `AssetExport.exportSelection` already resolves a selection to ordered
//  entries with a skip count, and this maps those entries to what AppKit's share
//  services accept.
//
//   • a byte-backed ref shares as its ON-DISK ORIGINAL (a file URL) — so AirDrop
//     sends the real image, Mail attaches it, and Messages does not re-encode a
//     thumbnail;
//   • a byte-less ref shares as the text ⌘C would have put on the board — a
//     colour's hex, a link's / tweet's URL.
//
//  Multi-select shares N items, not the first one: the whole Finder-scope selection
//  goes to the service, so "share these twelve refs" is one AirDrop of twelve files.
//
//  ## Two questions, deliberately different costs
//
//  Building a menu asks "should Share appear here?". Clicking it asks "what exactly
//  is being shared?". Those were the same call once, and it was measured at ~77 ms
//  for a 1,000-ref selection — paid synchronously before the right-click menu could
//  draw (`ShareMenuProbeTests`; the cost is ~66 µs per asset, spread across URL
//  building, `stat` and name sanitizing, with no single hot call to cache away).
//
//  So they are now two calls:
//
//   • ``canShare(_:)`` reads `blobHash` and, only for a byte-less kind, the decoded
//     content. No URL, no filesystem, no sanitizing. Callers ask it through
//     `contains(where:)`, which stops at the FIRST shareable ref — so the menu
//     usually answers after examining one asset, whatever the selection size.
//   • ``picker(for:)`` does the real work, once the user has actually chosen to
//     share.
//
//  The tradeoff is honest and small: `blobHash != nil` says a file SHOULD be on
//  disk, not that it is. A selection whose blobs were all reaped since the grid drew
//  them would offer Share and then have nothing to hand over, in which case the
//  click does nothing. That is strictly better than making every right-click pay for
//  certainty nobody asked for.
//

import AppKit
import AtelierCore
import Foundation

enum AssetShare {

    // MARK: - The cheap question

    /// Whether `asset` has anything shareable AT ALL, answered without touching the
    /// filesystem — see the file note for why this exists separately from
    /// ``picker(for:)``.
    ///
    /// `blobHash` first because it is a stored column and covers the overwhelming
    /// majority of refs; only a byte-less kind falls through to `AssetContent`,
    /// which decodes the payload JSON. So the expensive branch runs exactly for the
    /// assets that need it, and `.image` / `.video` never pay it.
    static func canShare(_ asset: Asset) -> Bool {
        if asset.blobHash != nil { return true }
        return AssetExport.textFallback(for: asset) != nil
    }

    // MARK: - The real payload

    /// The share payload for a resolved selection, in selection order: file URLs
    /// for originals, strings for byte-less refs.
    ///
    /// `[Any]` because that is what `NSSharingService` takes, and the two element
    /// types are exactly the two cases of ``AssetPasteboardEntry`` — the
    /// heterogeneity is AppKit's, not this app's. `NSURL` / `NSString` rather than
    /// their Swift twins for the same reason: they are what the services bridge to.
    static func items(for selection: ExportSelection) -> [Any] {
        selection.entries.map { entry in
            switch entry {
            case .file(let item): return item.blobURL as NSURL
            case .text(let string): return string as NSString
            }
        }
    }

    /// A picker over the selection's payload, or `nil` when there is nothing to
    /// share (every ref byte-less AND text-less, or an empty selection) — in which
    /// case the caller presents nothing rather than an empty sheet.
    ///
    /// The caller owns the returned picker and must keep it alive until the sheet is
    /// dismissed; `NSSharingServicePicker` does not retain itself while shown.
    static func picker(for selection: ExportSelection) -> NSSharingServicePicker? {
        let payload = items(for: selection)
        guard !payload.isEmpty else { return nil }
        return NSSharingServicePicker(items: payload)
    }
}
