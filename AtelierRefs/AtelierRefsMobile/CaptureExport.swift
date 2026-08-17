// AtelierRefsMobile — handing this phone's captures to the Mac (092 · S6b).
//
// **What this is exporting, and why it is not the library.** iOS never drains its inbox
// (`InboxDrain` is macOS-only), so a share made on this phone is a record plus a payload
// file and never becomes an asset here. What there is to send is the INBOX, and
// `InboxArchive` turns it into a `LibraryArchive`-shaped folder the Mac already knows how
// to import.
//
// **Nothing is deleted.** After an export the records stay exactly where they were. That
// is not laziness, it is the property 091 · D4 bought with the archive format: provenance
// crosses verbatim, so 18A blob-hash dedup collapses a re-import instead of forking a
// second asset. Deleting would mean trusting that a share sheet the user may have
// cancelled, an AirDrop that may have failed, and an import that may not have happened yet,
// all succeeded. Keeping means the worst case is importing the same capture twice, which
// the format is built to make a no-op.
//
// **Where the folder goes.** Caches, under a timestamped name. It is a copy of bytes the
// inbox still holds, so the system is free to reclaim it; it exists for as long as it takes
// the user to hand it somewhere.

import AtelierArchive
import AtelierCapture
import Foundation
import Observation

@MainActor
@Observable
final class CaptureExport {
    enum Phase: Equatable {
        case idle
        case working
        /// The archive is written; `url` is the folder to hand to a share sheet.
        case ready(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Pending captures on this device, or `nil` before the first count.
    ///
    /// Drives whether the export control is shown at all: an empty inbox has nothing to
    /// offer, and a button that always says "0" is chrome apologising for itself.
    private(set) var pending: Int?

    private let layout: InboxLayout
    private let appVersion: String

    init(libraryRoot: URL, appVersion: String) {
        layout = InboxLayout(libraryRoot: libraryRoot)
        self.appVersion = appVersion
    }

    /// Re-count the inbox. Cheap — a directory listing — and safe to call on every
    /// appearance, which is what keeps the control honest after a share.
    func refresh() {
        pending = (try? layout.pendingRecordURLs().count) ?? 0
    }

    /// Write the archive, off the main actor.
    func export(now: Date = Date()) async {
        phase = .working
        let layout = layout
        let appVersion = appVersion
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try Self.write(layout: layout, appVersion: appVersion, now: now)
            }.value
            phase = .ready(url)
        } catch {
            phase = .failed(Self.message(for: error))
        }
        refresh()
    }

    /// Dismissing the share sheet returns the control to its resting state; the folder is
    /// left in Caches for the system to reclaim.
    func finish() {
        phase = .idle
    }

    // MARK: - The run

    private nonisolated static func write(
        layout: InboxLayout, appVersion: String, now: Date
    ) throws -> URL {
        // Capture-time order, the same order the drain walks (405) — so a folder opened on
        // the Mac reads in the order the user actually saved things.
        let records = try layout.pendingRecordURLs()
            .compactMap { try? JSONDecoder().decode(InboxRecord.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString) }

        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(Self.folderName(now), isDirectory: true)
        // A fresh folder every run: writing into a previous export would leave last time's
        // files beside this time's manifest, which is the one thing a manifest must never
        // be wrong about.
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try InboxArchive.write(
            records: records, layout: layout, to: root,
            appVersion: appVersion, exportedAt: now)
        return root
    }

    /// `Atelier 2026-08-17 1830` — sortable, and it says what it is on a Mac desktop where
    /// it will sit beside whatever else was AirDropped that day.
    private nonisolated static func folderName(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Atelier \(formatter.string(from: now))"
    }

    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case InboxArchive.WriteError.nothingToExport:
            "There are no captures waiting to be sent."
        case InboxArchive.WriteError.nothingCopied:
            "None of the waiting captures could be read."
        default:
            "The captures couldn't be written."
        }
    }
}
