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
public nonisolated struct AssetExportItem: Equatable {
    /// The on-disk full-resolution original (verified to exist at build time).
    public let blobURL: URL
    /// `<title-or-source>-<shorthash>.<ext>`, sanitized.
    public let filename: String
    /// The drag/promise file type, derived from the blob's extension.
    public let utType: UTType

    /// Spelled out rather than synthesized: a memberwise initializer is internal, and
    /// this type crosses a module boundary now that the naming rule is shared with the
    /// phone (092 · S6).
    public init(blobURL: URL, filename: String, utType: UTType) {
        self.blobURL = blobURL
        self.filename = filename
        self.utType = utType
    }
}

/// The naming rule for an exported/copied original, plus the shared
/// asset → ``AssetExportItem`` assembly. Pure except `exportItem`, which stats the
/// blob (5A) and is temp-file testable.
///
/// The naming members are `nonisolated` (008 · H6): the app target is
/// `MainActor` by default, and the library archive names thousands of files from
/// a detached writer. They were always pure — the annotation says so to the
/// compiler as well as to the reader. `dragProvider` stays main-actor, since its
/// caller is a view.
public enum AssetExport {

    /// The human base name for an asset, in priority order: source title, then the
    /// author handle (a leading `@` dropped), then the source URL's host (`www.`
    /// dropped), else a bare `"image"`. The short blob hash appended by
    /// ``filename(base:blobHash:ext:)`` guarantees uniqueness, so the base only has
    /// to be *recognisable*, not unique.
    public nonisolated static func baseName(title: String?, authorHandle: String?, sourceURL: String?) -> String {
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
    public nonisolated static func sanitize(_ raw: String) -> String {
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
    public nonisolated static func filename(base: String, blobHash: String, ext: String) -> String {
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
    public nonisolated static func exportItem(asset: Asset, source: Source?, blobURL: URL?) -> AssetExportItem? {
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

}

/// Keeps ``AssetExport/filename(base:blobHash:ext:)`` results unique WITHIN ONE
/// DESTINATION FOLDER (014 · S3).
///
/// Drag-out never needed this: one drop, one name, and the receiving folder is
/// the Finder's problem. A folder export is the first caller to write many of
/// those names side by side, and there the short hash stops being a guarantee.
/// It is the first 8 characters of a longer digest, so two different blobs can
/// land on the same one; and the base is a human title, which repeats freely.
///
/// The trap this exists for is quieter than a plain duplicate. macOS volumes are
/// **case-insensitive** by default, so `Hero-ab12cd34.png` and
/// `hero-ab12cd34.png` are the SAME path. Writing the second name does not
/// produce a second file — it lands on the first one. In a writer that refreshes
/// an existing destination (which `SiteExportWriter` must, so a re-export is not
/// a "file exists" failure) that shows up as a silent overwrite: the export ships
/// one image twice while reporting two. Uniqueness is therefore decided
/// case-INSENSITIVELY here, while the name the recipient sees keeps the casing
/// the asset's own title gave it.
///
/// Pure and order-dependent by design: the same input sequence always produces
/// the same names, so an export is reproducible.
public nonisolated struct ExportNameAllocator {
    /// Lowercased forms of every name handed out so far.
    private var taken: Set<String> = []

    public init() {}

    /// A name for `filename` that no earlier ``claim(_:)`` has taken, compared
    /// case-insensitively. The first claim comes back verbatim; a collision gets
    /// `-2`, `-3`, … inserted BEFORE the extension (`hero-ab12cd34-2.png`),
    /// where a reader expects a duplicate marker and where the extension still
    /// says what the file is.
    public mutating func claim(_ filename: String) -> String {
        var candidate = filename
        var suffix = 1
        while !taken.insert(candidate.lowercased()).inserted {
            suffix += 1
            candidate = Self.disambiguated(filename, suffix: suffix)
        }
        return candidate
    }

    /// `name.ext` → `name-<suffix>.ext`; an extension-less name just gains the
    /// suffix.
    public static func disambiguated(_ filename: String, suffix: Int) -> String {
        let path = filename as NSString
        let ext = path.pathExtension
        let base = path.deletingPathExtension
        return ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
    }
}
