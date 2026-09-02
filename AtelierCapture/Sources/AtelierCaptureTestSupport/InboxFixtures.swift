// AtelierCaptureTestSupport — an inbox to test against, and the state a drain leaves it
// in (457).
//
// Seven suites across four packages each made a throwaway root by hand, and two of them
// hand-rolled the two moves a retaining `InboxDrain` makes — in the drain's order, from
// memory, with a comment promising `InboxDrainTests` pinned it. A change to the drain's
// order would have left both green. So the root maker is here once, and the retention
// fixture executes `InboxLayout.retentionMoves(for:)`, which is the same list the drain
// executes; the order is stated in one place and a fixture cannot drift from it.
//
// This target cannot import `AtelierIngestion` — it is what the share extension's test
// side links, and `InboxDrain` brings the whole pipeline — which is exactly why the plan
// lives on `InboxLayout` rather than being copied here.

import Foundation

import AtelierCapture

/// Throwaway inboxes and the drain's leftovers. A namespace — `static` only.
public enum InboxFixtures {
    /// A fresh, unique, empty directory under `<tmp>/<suite>/<uuid>/`, created.
    ///
    /// A LIBRARY root, not an inbox: `InboxLayout(libraryRoot:)` and `InboxWriter
    /// (libraryRoot:)` take it, and so does `AppServices.open(libraryRoot:)` for a suite
    /// that wants a database beside the inbox. The `suite` name keeps one suite's
    /// leftovers findable when a test forgets its `defer`.
    public static func temporaryLibraryRoot(suite: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An `InboxLayout` over a fresh ``temporaryLibraryRoot(suite:)``. Nothing under the
    /// inbox exists yet — the writer creating it on first use is part of what most suites
    /// are testing. Clean up with `removeItem(at: layout.directory)` or the root.
    public static func makeLayout(suite: String) throws -> InboxLayout {
        InboxLayout(libraryRoot: try temporaryLibraryRoot(suite: suite))
    }

    /// Leave `record` as a retaining `InboxDrain` leaves it: under `ingested/`, out of
    /// the pending set, still on disk.
    ///
    /// Executes `InboxLayout.retentionMoves(for:)` in order — the record, then the
    /// payload — with `moveItem`, so a missing record throws where the drain's
    /// best-effort move would not; a fixture that silently did nothing is worse than
    /// one that fails. A payload the record names but that is not on disk is skipped,
    /// for a media-less record and for a suite that deleted the bytes on purpose.
    ///
    /// `movingPayload: false` stops after the record, which reproduces the state a
    /// crash between the two moves leaves behind: an ingested record whose bytes are
    /// still in the inbox top level. `InboxArchive` reads that as a whole capture, and
    /// `InboxRetirement` reclaims the stray; both are tested against this.
    @discardableResult
    public static func retain(
        _ record: InboxRecord, in layout: InboxLayout, movingPayload: Bool = true
    ) throws -> InboxRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.ingested, withIntermediateDirectories: true)
        for move in layout.retentionMoves(for: record) {
            switch move.file {
            case .record:
                try fileManager.moveItem(at: move.from, to: move.to)
            case .payload:
                guard movingPayload, fileManager.fileExists(atPath: move.from.path) else {
                    continue
                }
                try fileManager.moveItem(at: move.from, to: move.to)
            }
        }
        return record
    }
}
