//
//  AssetExport.swift
//  AtelierRefs
//
//  011 · Cluster A (out-flow) — the shared naming + item layer for getting refs
//  OUT of the app: drag-out (file promises), and the future ⌘C / 008 export all
//  name a dropped/copied original the same way: `<title-or-source>-<shorthash>.<ext>`.
//
//  The base-name pick + sanitizer are PURE (unit-tested, no AppKit / Vision / MIME
//  table). The exported file's extension is read from the blob file itself
//  (`blobURL.pathExtension`) — the ONE place extension is decided (inside
//  `IngestionModel.blobURL(forAsset:)`), so the name, the on-disk file, and the
//  drag `UTType` can never disagree. Lives in the app for now; promotes verbatim
//  when 008's `AtelierBackup` exporter lands (one export naming rule, not two).
//

import AtelierCore
import Foundation
import UniformTypeIdentifiers

/// One asset's export payload: the on-disk original, the human filename it drops
/// as, and the type the file promise advertises. Built by
/// ``AssetExport/exportItem(asset:source:blobURL:)`` and consumed by the grid's
/// file-promise drag and the detail view's `.onDrag`.
nonisolated struct AssetExportItem: Equatable {
    /// The on-disk full-resolution original (verified to exist at build time).
    let blobURL: URL
    /// `<title-or-source>-<shorthash>.<ext>`, sanitized.
    let filename: String
    /// The drag/promise file type, derived from the blob's extension.
    let utType: UTType
}

/// The naming rule for an exported/copied original, plus the shared
/// asset → ``AssetExportItem`` assembly. Pure except `exportItem`, which stats the
/// blob (5A) and is temp-file testable.
enum AssetExport {

    /// The human base name for an asset, in priority order: source title, then the
    /// author handle (a leading `@` dropped), then the source URL's host (`www.`
    /// dropped), else a bare `"image"`. The short blob hash appended by
    /// ``filename(base:blobHash:ext:)`` guarantees uniqueness, so the base only has
    /// to be *recognisable*, not unique.
    static func baseName(title: String?, authorHandle: String?, sourceURL: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let handle = authorHandle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            return handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        }
        if let sourceURL, let host = URL(string: sourceURL)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return "image"
    }

    /// Reduce an arbitrary base to a filesystem-safe segment: path-hostile and
    /// control characters (`/ \ : NUL` + controls) become spaces, whitespace runs
    /// collapse to one space, leading/trailing spaces / dots / dashes are trimmed
    /// (no hidden-file dot, no dangling separators), the result is capped at 60
    /// characters, and an empty result falls back to `"image"`.
    static func sanitize(_ raw: String) -> String {
        let hostile = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters)
        let replaced = String(String.UnicodeScalarView(
            raw.unicodeScalars.map { hostile.contains($0) ? Unicode.Scalar(32) : $0 }))
        var s = replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimSet = CharacterSet(charactersIn: " .-")
        s = s.trimmingCharacters(in: trimSet)
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: trimSet) }
        return s.isEmpty ? "image" : s
    }

    /// Assemble `<sanitized-base>-<shorthash>.<ext>`. The short hash is the first 8
    /// of the (already-lowercased) content hash; the extension is reduced to bare
    /// alphanumerics. A missing hash or extension simply drops that segment.
    static func filename(base: String, blobHash: String, ext: String) -> String {
        let name = sanitize(base)
        let shortHash = String(blobHash.prefix(8))
        let cleanExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let hashPart = shortHash.isEmpty ? "" : "-\(shortHash)"
        let extPart = cleanExt.isEmpty ? "" : ".\(cleanExt)"
        return "\(name)\(hashPart)\(extPart)"
    }

    /// The shared assembly (3A): an ``AssetExportItem`` for a byte-backed asset, or
    /// `nil` when there is nothing to export — a media-less kind (no `blobHash`), a
    /// missing on-disk URL, or a blob whose file is gone (reaped/trashed since it
    /// was rendered). The filename's extension and the promise `UTType` both come
    /// from the blob's own `pathExtension` (1A/6A).
    ///
    /// `source` is optional (052 · B1): a canvas ``SpaceItemDetail`` carries no
    /// source for an element row and none for some asset rows, so a nil source just
    /// drops the naming hints and falls back to the blob-derived `"image"` base.
    static func exportItem(asset: Asset, source: Source?, blobURL: URL?) -> AssetExportItem? {
        guard let blobHash = asset.blobHash, !blobHash.isEmpty,
              let blobURL,
              FileManager.default.fileExists(atPath: blobURL.path) else { return nil }
        let ext = blobURL.pathExtension
        let name = filename(
            base: baseName(
                title: source?.title, authorHandle: source?.authorHandle,
                sourceURL: source?.originalURL),
            blobHash: blobHash, ext: ext)
        return AssetExportItem(
            blobURL: blobURL, filename: name, utType: UTType(filenameExtension: ext) ?? .data)
    }

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
