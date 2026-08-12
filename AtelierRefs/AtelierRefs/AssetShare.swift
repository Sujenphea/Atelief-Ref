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
//     colour's hex, a link's / tweet's URL. Here that fallback is right where it
//     was wrong for the folder export: a share destination is very often a text
//     field, and Messages has nothing to do with a `.txt` sidecar.
//
//  Multi-select shares N items, not the first one (the decision A3 was gated on):
//  the whole Finder-scope selection goes to the service, so "share these twelve
//  refs" is one AirDrop of twelve files.
//
//  The mapping is pure and directly tested; the `NSMenuItem` builder is the only
//  AppKit-touching member, and it is a two-line wrapper over the system-standard
//  share menu so the services, their order and their icons are macOS's rather
//  than a list this app would have to maintain.
//

import AppKit
import Foundation

enum AssetShare {

    /// The share payload for a resolved selection, in selection order: file URLs
    /// for originals, strings for byte-less refs.
    ///
    /// `[Any]` because that is what `NSSharingService` takes, and the two element
    /// types are exactly the two cases of ``AssetPasteboardEntry`` — the
    /// heterogeneity is AppKit's, not this app's. `NSURL` / `NSString` rather than
    /// their Swift twins for the same reason: they are what the services bridge
    /// to, and passing the value types leaves the bridging to a cast at the far
    /// end.
    static func items(for selection: ExportSelection) -> [Any] {
        selection.entries.map { entry in
            switch entry {
            case .file(let item): return item.blobURL as NSURL
            case .text(let string): return string as NSString
            }
        }
    }

    /// The system-standard `Share ▸` submenu for a resolved selection, or `nil`
    /// when the selection has nothing shareable (every ref byte-less AND
    /// text-less, or an empty selection) — in which case the caller adds no item
    /// at all rather than a dead one.
    ///
    /// `NSSharingServicePicker.standardShareMenuItem` rather than a hand-built
    /// list off `NSSharingService.sharingServices(forItems:)` — which is
    /// deprecated in favour of exactly this since macOS 13. The system item
    /// carries the user's own service configuration, their recent AirDrop targets
    /// and the current ordering, none of which this app has any business
    /// reproducing.
    ///
    /// The picker is parked in the item's `representedObject` deliberately: the
    /// menu item's submenu is populated lazily BY the picker, so a picker released
    /// at the end of this function would leave an item that opens an empty
    /// submenu. The menu item owns it for as long as the menu lives.
    static func menuItem(for selection: ExportSelection) -> NSMenuItem? {
        let payload = items(for: selection)
        guard !payload.isEmpty else { return nil }
        let picker = NSSharingServicePicker(items: payload)
        let item = picker.standardShareMenuItem
        item.representedObject = picker
        return item
    }
}
