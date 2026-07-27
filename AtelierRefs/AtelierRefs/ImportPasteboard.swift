//
//  ImportPasteboard.swift
//  AtelierRefs
//
//  059 · SP3 — the ONE reader for "is there a web URL to import on this
//  pasteboard?", shared by every import surface that starts from a pasteboard:
//  the grid paste (`CollectionView.paste`), the canvas external DROP (the AppKit
//  dragging destination hands over `sender.draggingPasteboard`), and the canvas
//  PASTE (SP4). Extracted from `CollectionView` so the three can never disagree
//  on what counts as a link (they feed the same `dispatch` decision order).
//

import AppKit
import AtelierIngestion
import Foundation

enum ImportPasteboard {
    /// The first WEB (http/https) URL carried by `pasteboard`, or `nil`. Checks, in
    /// order: typed `NSURL` objects (skipping file URLs), the `.URL` string, then a
    /// dotted-host guess from plain text — a URL copied as PLAIN TEXT (the address
    /// bar, a message, a doc) carries only `public.utf8-plain-text`, so it is parsed
    /// too, with `webURL(fromPastedText:)`'s dotted-host guard so arbitrary text
    /// isn't mistaken for a link (001 · C2b).
    static func firstWebURL(on pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = objects.first(where: { !$0.isFileURL && DirectInputReader.isWebURL($0) }) {
            return url
        }
        if let string = pasteboard.string(forType: .URL),
           let url = URL(string: string), DirectInputReader.isWebURL(url) {
            return url
        }
        if let text = pasteboard.string(forType: .string),
           let url = IngestionModel.webURL(fromPastedText: text) {
            return url
        }
        return nil
    }

    /// A CHEAP "is there anything importable here?" check for the drag-hover accept
    /// decision (059 · SP3) — presence of a file URL, an image representation, or a
    /// web URL, WITHOUT reading any image bytes. The authoritative decode
    /// (`DirectInputReader.inputs(from:…)`, which does read bytes) runs once on the
    /// actual drop, not per hover tick.
    static func hasImportableContent(on pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil { return true }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return firstWebURL(on: pasteboard) != nil
    }
}
