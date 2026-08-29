//
//  AssetExportDrag.swift
//  AtelierRefs
//
//  The half of `AssetExport` that could not follow it into `AtelierArchive`.
//
//  The naming rule — base name, sanitizer, `<title-or-source>-<shorthash>.<ext>`, and
//  `ExportNameAllocator` — is a pure function over a `Source` and is now shared with the
//  phone (092 · S6), which writes archives and therefore names files. THIS is the part
//  that is macOS and stays: an `NSItemProvider`, the app-private `.assetIDs` pasteboard
//  type, and the internal-drag guard that reads it. None of it means anything on a phone
//  with no pasteboard promises and no drag session.
//

import AtelierArchive
import AtelierCore
import Foundation
import UniformTypeIdentifiers

extension AssetExport {
    /// The detail view's drag provider (7A + the 192 internal-drag guard): vends
    /// the original blob file for an external drop AND registers the app-private
    /// `.assetIDs` payload so an in-app drop is recognised as internal — the
    /// collection pane's import guard refuses it instead of re-ingesting the
    /// app's own file (the grid's file-promise drag gets the same guarantee from
    /// `AssetFilePromiseProvider`). Hosts with a collection context pass a real
    /// payload; the others pass ``AssetDragPayload/internalMarker``.
    static func dragProvider(item: AssetExportItem, payload: AssetDragPayload) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: item.blobURL) ?? NSItemProvider()
        provider.suggestedName = item.filename
        if let data = try? payload.pasteboardData() {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.assetIDs.identifier, visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}
