// AtelierExport — the static-site folder writer (014 · S3)
//
// Turns a ``SiteGallery`` + its ``SiteAsset`` list into
//
//     <root>/index.html
//     <root>/assets/…
//
// Two properties drive the shape of this file:
//
// **Nothing is held in memory.** Each ref is a `FileManager.copyItem` from the
// blob store to `assets/` — the kernel streams the bytes, so a 4 GB collection
// costs the same resident memory as a 4 MB one. Nowhere does this code read an
// image into a `Data`.
//
// **The page never promises a file that isn't there.** Assets are copied
// FIRST; `index.html` is rendered afterwards from only the items whose bytes
// actually landed. A blob reaped between the plan and the write becomes a
// reported skip, not a broken `<img>` the recipient discovers later. That is
// the repo's standing batch-outcome rule (N exported / N skipped, with
// reasons) applied to a folder.

import Foundation

/// Why one ref did not make it into `assets/` — ``ExportSkip`` under its
/// site-flavoured name. A partial export reads the same whether this writer or
/// the originals writer (011 · A2) produced it, because it is the same type.
public typealias SiteSkip = ExportSkip

/// What a finished folder export produced.
public struct SiteWriteResult: Equatable, Sendable {
    /// The written `index.html`.
    public var indexURL: URL
    /// Files placed in `assets/`.
    public var copied: Int
    /// Refs left out, with reasons.
    public var skipped: [SiteSkip]

    public init(indexURL: URL, copied: Int, skipped: [SiteSkip]) {
        self.indexURL = indexURL
        self.copied = copied
        self.skipped = skipped
    }
}

/// The folder writer. Synchronous and self-contained, exactly like
/// ``MoodboardRenderer`` (052 · 15A): the app calls it from a detached task and
/// passes its own cancel flag, so nothing here touches an actor.
public enum SiteExportWriter {

    /// The subfolder every ref is copied into.
    public static let assetsDirectoryName = "assets"
    /// The page's filename.
    public static let indexFileName = "index.html"

    /// Write `gallery` and `assets` into `root`, creating it if needed.
    ///
    /// - Parameters:
    ///   - gallery: the page. Items whose asset fails to copy are dropped from
    ///     the rendered HTML and reported instead.
    ///   - assets: the files to place in `assets/`, already uniquely named.
    ///     Duplicate names are copied once (the second occurrence is the same
    ///     bytes under the same name), so an item shown twice costs one file.
    ///   - isCancelled: polled before every copy; a `true` throws
    ///     `CancellationError` and leaves cleanup to the caller.
    ///   - onProgress: `0...1`, called after each asset and once more at the end.
    /// - Throws: ``ExportError/noPages`` for an empty gallery, `CancellationError`,
    ///   or any `FileManager` error from creating the folders / writing the page.
    ///   A single asset failing is a soft skip, never a throw.
    @discardableResult
    public static func write(
        gallery: SiteGallery,
        assets: [SiteAsset],
        to root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false },
        onProgress: (Double) -> Void = { _ in }
    ) throws -> SiteWriteResult {
        guard !gallery.isEmpty else { throw ExportError.noPages }

        let assetsDirectory = root.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

        var written = Set<String>()
        var skipped: [SiteSkip] = []
        let total = assets.count

        for (index, asset) in assets.enumerated() {
            if isCancelled() { throw CancellationError() }
            // The same blob can back two rows; copy it once.
            guard !written.contains(asset.filename) else {
                onProgress(fraction(index + 1, total))
                continue
            }
            let destination = assetsDirectory.appendingPathComponent(asset.filename)
            do {
                guard fileManager.fileExists(atPath: asset.source.path) else {
                    skipped.append(SiteSkip(filename: asset.filename, reason: .missingSource))
                    onProgress(fraction(index + 1, total))
                    continue
                }
                // Re-exporting over a previous run must refresh the file rather
                // than fail on "already exists".
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: asset.source, to: destination)
                written.insert(asset.filename)
            } catch {
                skipped.append(SiteSkip(
                    filename: asset.filename,
                    reason: .copyFailed(error.localizedDescription)))
            }
            onProgress(fraction(index + 1, total))
        }

        if isCancelled() { throw CancellationError() }

        // Only what is really on disk gets a cell.
        var page = gallery
        page.items = gallery.items.filter { item in
            guard let filename = item.media.assetFilename else { return true }  // colour
            return written.contains(filename)
        }

        let indexURL = root.appendingPathComponent(indexFileName)
        try Data(StaticSiteRenderer.indexHTML(page).utf8)
            .write(to: indexURL, options: .atomic)
        onProgress(1)

        return SiteWriteResult(indexURL: indexURL, copied: written.count, skipped: skipped)
    }

    private static func fraction(_ done: Int, _ total: Int) -> Double {
        total <= 0 ? 1 : Swift.min(1, Double(done) / Double(total))
    }
}
