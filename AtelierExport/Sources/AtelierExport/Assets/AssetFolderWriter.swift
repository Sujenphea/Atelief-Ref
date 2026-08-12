// AtelierExport — the plain-originals folder writer (011 · A2)
//
// The fourth output this package writes, and the simplest: no layout, no
// renderer, no HTML. A selection of refs becomes a folder of their original
// files under the names `AssetExport` already gives them.
//
//     <root>/nike-ad-3f2a91c4.jpg
//     <root>/poster-study-8b01de77.png
//     <root>/clip-c40f9a2e.mp4
//
// It shares `SiteExportWriter`'s two load-bearing properties, for the same
// reasons spelled out there:
//
// **Nothing is held in memory.** Every file is a `FileManager.copyItem` from the
// blob store to the destination — the kernel streams the bytes, so a 40 GB
// selection costs the same resident memory as a 40 MB one. Nowhere does this
// code read a file into a `Data`.
//
// **One bad ref never sinks the export.** A blob reaped between the plan and the
// write, or a copy the filesystem refuses, is a reported skip; the other N-1
// files still land. That is the repo's standing batch-outcome rule (N exported /
// N skipped, with reasons).
//
// Where it deliberately DIVERGES from the static-site writer is videos. That one
// copies only a poster frame, on the reasoning that an HTML page destined for
// email should not smuggle a 300 MB movie along. This writer has no such
// license: a folder of originals that quietly substituted stills would be
// answering a question nobody asked. It copies whatever bytes the plan names,
// and the plan (app-side `AssetFolderExport`) names the real video.

import Foundation

// MARK: - Shared vocabulary

/// One file to place in an export folder: where it is now, and what it is called
/// once it gets there. The name is `AssetExport`'s, already de-duplicated for the
/// destination by `ExportNameAllocator`.
///
/// Named for the job rather than the destination because two writers now share
/// it — the static site's `assets/` and this one's flat folder. ``SiteAsset`` is
/// the same type under its original name.
public struct ExportFile: Equatable, Sendable {
    public var source: URL
    public var filename: String

    public init(source: URL, filename: String) {
        self.source = source
        self.filename = filename
    }

    /// Whether ``filename`` is safe to append to a destination folder: exactly ONE
    /// path component, not a traversal, not absolute, no embedded `NUL`.
    ///
    /// Both writers build their destination as `root + filename`, so a name like
    /// `../../evil.png` would write OUTSIDE the folder the user chose. In this app
    /// that cannot currently happen — names come from `AssetExport.sanitize`, which
    /// maps `/` and `\` to spaces and trims leading dots, so `"../../etc/passwd"`
    /// arrives as `"etc passwd"`. But that safety argument lives in a DIFFERENT
    /// MODULE which this package does not import and cannot see, while the names
    /// themselves derive from captured web content (a post title). A filesystem
    /// write does not get to rely on a guarantee it has no way to check, so it is
    /// checked here, where the write happens.
    ///
    /// Backslash is deliberately allowed: on macOS it is an ordinary filename
    /// character, not a separator, so rejecting it would refuse legitimate names.
    ///
    /// Spelled out as three literal conditions rather than the tidier-looking
    /// `lastPathComponent == filename`, which LOOKS like it catches every separator
    /// case and does not: `("/" as NSString).lastPathComponent` is `"/"`, so a bare
    /// slash compared equal to itself and was accepted. The test matrix caught it.
    /// An explicit rejection of `/` is both stricter and easier to check by eye.
    public var hasSafeName: Bool {
        guard !filename.isEmpty else { return false }
        guard filename != ".", filename != ".." else { return false }
        guard !filename.contains("/"), !filename.contains("\0") else { return false }
        return true
    }
}

/// Why one file did not make it into the destination folder. Shared by both
/// folder writers, so a partial export reads the same whichever produced it;
/// ``SiteSkip`` is the same type under its original name.
public struct ExportSkip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The source was gone from disk by the time the copy ran (reaped,
        /// trashed, or on an unmounted volume).
        case missingSource
        /// The copy itself failed — permissions, a full destination disk.
        case copyFailed(String)
        /// The name would not have stayed inside the destination folder — a path
        /// separator, a `..` traversal, or an absolute path. Refused rather than
        /// written; see ``ExportFile/hasSafeName``.
        case unsafeName
    }

    /// The name the file would have had in the folder.
    public var filename: String
    public var reason: Reason

    public init(filename: String, reason: Reason) {
        self.filename = filename
        self.reason = reason
    }
}

/// What a finished originals export produced.
public struct AssetFolderResult: Equatable, Sendable {
    /// The folder the files were written into.
    public var root: URL
    /// Files that actually landed.
    public var copied: Int
    /// Files left out, with reasons.
    public var skipped: [ExportSkip]

    public init(root: URL, copied: Int, skipped: [ExportSkip]) {
        self.root = root
        self.copied = copied
        self.skipped = skipped
    }
}

// MARK: - Writer

/// The originals writer. Synchronous and self-contained, exactly like
/// ``SiteExportWriter`` and ``MoodboardRenderer`` (052 · 15A): the app calls it
/// from a detached task and passes its own cancel flag, so nothing here touches
/// an actor.
public enum AssetFolderWriter {

    /// Copy every file in `files` into `root`, creating the folder if needed.
    ///
    /// - Parameters:
    ///   - files: the originals to copy, already uniquely named. A repeated
    ///     `filename` is copied ONCE (the second occurrence is the same bytes
    ///     under the same name), so one blob backing two selected rows costs one
    ///     file — and is not double-counted in ``AssetFolderResult/copied``.
    ///   - root: the destination folder. Files land flat inside it; no
    ///     subdirectory, since there is nothing here to separate them from.
    ///   - isCancelled: polled before every copy; a `true` throws
    ///     `CancellationError` and leaves cleanup to the caller.
    ///   - onProgress: `0...1`, called after each file and once more at the end.
    /// - Throws: ``ExportError/noPages`` for an empty file list, `CancellationError`,
    ///   or any `FileManager` error from creating the folder. A single file
    ///   failing is a soft skip, never a throw.
    @discardableResult
    public static func write(
        files: [ExportFile],
        to root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false },
        onProgress: (Double) -> Void = { _ in }
    ) throws -> AssetFolderResult {
        guard !files.isEmpty else { throw ExportError.noPages }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var written = Set<String>()
        var skipped: [ExportSkip] = []
        let total = files.count

        for (index, file) in files.enumerated() {
            if isCancelled() { throw CancellationError() }

            // Refused BEFORE the name is joined to `root`, so an escaping name is
            // never turned into a path at all.
            guard file.hasSafeName else {
                skipped.append(ExportSkip(filename: file.filename, reason: .unsafeName))
                onProgress(fraction(index + 1, total))
                continue
            }

            // The same blob can back two selected rows; copy it once.
            guard !written.contains(file.filename) else {
                onProgress(fraction(index + 1, total))
                continue
            }

            let destination = root.appendingPathComponent(file.filename)
            do {
                guard fileManager.fileExists(atPath: file.source.path) else {
                    skipped.append(ExportSkip(filename: file.filename, reason: .missingSource))
                    onProgress(fraction(index + 1, total))
                    continue
                }
                // Re-exporting over a previous run must refresh the file rather
                // than fail on "already exists". Only names this run writes are
                // touched — anything else already in the folder is the user's.
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: file.source, to: destination)
                written.insert(file.filename)
            } catch {
                skipped.append(ExportSkip(
                    filename: file.filename,
                    reason: .copyFailed(error.localizedDescription)))
            }
            onProgress(fraction(index + 1, total))
        }

        onProgress(1)
        return AssetFolderResult(root: root, copied: written.count, skipped: skipped)
    }

    private static func fraction(_ done: Int, _ total: Int) -> Double {
        total <= 0 ? 1 : Swift.min(1, Double(done) / Double(total))
    }
}
