// AtelierCapture — where the handoff lives on disk (092 · S2).
//
// The inbox is the directory the iOS share extension appends to and the host app
// drains (091 · D2). Both processes need to agree on its shape down to the file
// name, and they are compiled into different binaries with different link lines,
// so the shape is named exactly once — here.
//
// **Why this is in AtelierCapture and not AtelierIngestion**, where 092's prose put
// it: `AtelierIngestion` imports AppKit (`Input/DirectInputReader.swift`) and so
// cannot build for iOS at all; the share extension could never link it. This package
// is transport-free and platform-free by construction and the extension already
// links it. `LibraryLayout.inbox` delegates to ``InboxLayout/directoryName`` rather
// than spelling `"inbox"` a second time, so there is still exactly one authority on
// where the handoff lives — the dependency arrow just points the other way.
//
// **Staging is INSIDE the inbox**, not in the library's `cache/`. 092 said `cache/`,
// but `cache` is a name `LibraryLayout` owns, and a package that must not learn the
// library's directory structure should not learn a second directory name in order to
// write one file. `inbox/.staging/` is on the same volume as `inbox/`, which is the
// only property the atomic move actually needs, and it is invisible to the drain:
// ``pendingRecordURLs()`` enumerates the TOP LEVEL of `inbox/` and takes only
// `*.json`, so an in-flight staged record cannot be picked up mid-write.
//
//     <root>/inbox/.staging/<uuid>.bin      staged, then moved
//     <root>/inbox/.staging/<uuid>.json     staged, then moved
//     <root>/inbox/<uuid>.bin               the payload bytes, when there are any
//     <root>/inbox/<uuid>.json              the record — and the commit marker
//
// Everything here is pure path arithmetic and creates nothing, with two marked
// exceptions at the bottom — "which records are pending" and "is this one complete"
// cannot be answered without looking at the disk, and they are the two questions
// 092 · S3's drain opens with. They live beside the paths they interrogate rather
// than in a third type.

import Foundation

/// The on-disk shape of the capture inbox (092 · S2).
///
/// A value type wrapping the inbox `directory`. Constructing one touches no
/// filesystem; ``InboxWriter`` is what creates anything.
public struct InboxLayout: Sendable {
    /// The inbox's name under the Library root. The single authority — `LibraryLayout`
    /// reads this rather than repeating the literal.
    public static let directoryName = "inbox"

    /// Where a write stages its files before moving them into place. Dot-prefixed and
    /// nested inside the inbox: same volume as the destination (so the move is a
    /// rename, not a copy) and skipped by ``pendingRecordURLs()``.
    public static let stagingDirectoryName = ".staging"

    /// Where the drain puts a capture it has stopped retrying (092 · S3). A plain
    /// subdirectory rather than a dot-directory: `.staging/` hides because an
    /// in-flight write must be invisible, but a quarantined capture is something a
    /// human is meant to find. It is skipped by ``pendingRecordURLs()`` for a
    /// different reason — the enumeration takes only top-level `*.json`, and a
    /// directory has no extension.
    public static let failedDirectoryName = "failed"

    /// The record's extension. The drain's enumeration filter, so it is a constant.
    public static let recordExtension = "json"

    /// The payload sidecar's extension. Deliberately opaque — the inbox carries bytes
    /// whose type nobody in this package is allowed to sniff (091 · D2: the extension
    /// never decodes an image).
    public static let payloadExtension = "bin"

    /// The inbox directory itself.
    public let directory: URL

    /// Wrap an inbox directory. Pure path math — nothing is created.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The inbox under a Library root — `<root>/inbox/`. The same arithmetic
    /// `LibraryLayout.inbox` performs, for callers (the share extension) that have a
    /// root but cannot link `AtelierIngestion`.
    public init(libraryRoot: URL) {
        self.init(
            directory: libraryRoot.appendingPathComponent(
                InboxLayout.directoryName, isDirectory: true))
    }

    /// `<inbox>/.staging/` — the scratch directory a two-phase write stages into.
    public var staging: URL {
        directory.appendingPathComponent(
            InboxLayout.stagingDirectoryName, isDirectory: true)
    }

    /// `<inbox>/failed/` — where 092 · S3 quarantines a capture that has failed its
    /// three attempts, or that is malformed in a way no retry can fix.
    public var failed: URL {
        directory.appendingPathComponent(
            InboxLayout.failedDirectoryName, isDirectory: true)
    }

    /// `<uuid>.json` — the record's file name.
    public static func recordFileName(for id: UUID) -> String {
        "\(id.uuidString).\(recordExtension)"
    }

    /// `<uuid>.bin` — the payload sidecar's file name, and the value that goes into
    /// ``InboxRecord/payloadFile``.
    public static func payloadFileName(for id: UUID) -> String {
        "\(id.uuidString).\(payloadExtension)"
    }

    /// Where a record commits to: `<inbox>/<uuid>.json`.
    public func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            InboxLayout.recordFileName(for: id), isDirectory: false)
    }

    /// Where a payload commits to: `<inbox>/<uuid>.bin`.
    public func payloadURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            InboxLayout.payloadFileName(for: id), isDirectory: false)
    }

    /// Where a record is staged before its move: `<inbox>/.staging/<uuid>.json`.
    public func stagedRecordURL(for id: UUID) -> URL {
        staging.appendingPathComponent(
            InboxLayout.recordFileName(for: id), isDirectory: false)
    }

    /// Where a payload is staged before its move: `<inbox>/.staging/<uuid>.bin`.
    public func stagedPayloadURL(for id: UUID) -> URL {
        staging.appendingPathComponent(
            InboxLayout.payloadFileName(for: id), isDirectory: false)
    }

    /// Resolve a ``InboxRecord/payloadFile`` value against this inbox, or `nil` when
    /// the name could not have been written by ``InboxWriter``.
    ///
    /// The name arrives from a file that crossed a process boundary, so it is treated
    /// as data rather than as a path: anything that is not a single, non-relative path
    /// component is refused instead of being resolved into a URL that escapes the
    /// inbox. A record naming such a payload is unreadable by construction — S3 should
    /// treat it as a failure, not as a not-yet-complete write, since no amount of
    /// waiting will make it resolve.
    public func payloadURL(named name: String) -> URL? {
        guard InboxLayout.isPlainComponent(name) else { return nil }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// The quarantined location of a file currently sitting in the inbox, under the
    /// same guard as ``payloadURL(named:)`` — a name too dangerous to read from is
    /// equally too dangerous to move.
    public func failedURL(named name: String) -> URL? {
        guard InboxLayout.isPlainComponent(name) else { return nil }
        return failed.appendingPathComponent(name, isDirectory: false)
    }

    /// Whether a file name written by another process may be appended to a
    /// directory URL at all: one plain component, nothing relative, no separator.
    /// The single authority both `named:` resolvers ask, so they cannot drift.
    private static func isPlainComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    /// The payload a record refers to, or `nil` for a media-less record (and for a
    /// record whose `payloadFile` is refused by ``payloadURL(named:)``).
    public func payloadURL(for record: InboxRecord) -> URL? {
        guard let name = record.payloadFile else { return nil }
        return payloadURL(named: name)
    }

    // MARK: - The two questions that need the disk

    /// Every committed record in the inbox, oldest-name-first, and nothing else.
    ///
    /// Touches the filesystem. The top level only, `*.json` only — which is what makes
    /// `.staging/` invisible and therefore what makes the two-phase write safe, and
    /// what keeps ``failed/`` out too: both are directories, and a directory has no
    /// `json` extension, so neither they nor anything under them can be returned. An
    /// absent inbox is an empty inbox, not an error: nothing has ever been shared.
    public func pendingRecordURLs() throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        return entries
            .filter { $0.pathExtension == InboxLayout.recordExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether a record's payload has landed — the predicate 092 · S3's drain skips on.
    ///
    /// Touches the filesystem. A media-less record is complete on sight; a record
    /// naming a payload is complete only once that payload exists. The writer commits
    /// the payload BEFORE the record (see ``InboxWriter``), so a false here on a record
    /// the writer produced means the answer changes shortly — skip the item this pass
    /// rather than failing it.
    public func isComplete(_ record: InboxRecord) -> Bool {
        guard let name = record.payloadFile else { return true }
        guard let url = payloadURL(named: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
