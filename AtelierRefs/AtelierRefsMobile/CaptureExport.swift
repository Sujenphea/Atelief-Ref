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
        /// The share sheet has been dismissed and there are captures the user could now
        /// retire (096 · 3B). `count` is how many actually reached the manifest — not how
        /// many were pending, which is a superset.
        case sent(Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Pending captures on this device, or `nil` before the first count.
    ///
    /// Drives whether the export control is shown at all: an empty inbox has nothing to
    /// offer, and a button that always says "0" is chrome apologising for itself.
    private(set) var pending: Int?

    /// The ids that reached the last export's manifest, and therefore the only ones the
    /// clear control may retire.
    ///
    /// **Not "everything pending".** `InboxArchive` skips records its funnel refuses, and a
    /// share made while the share sheet was open was never in the export at all. Retiring
    /// either would take a capture out of the pending set on the strength of a send it was
    /// not in — which is how "nothing is lost" quietly stops being true.
    private var exported: [UUID] = []

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
            let written = try await Task.detached(priority: .userInitiated) {
                try Self.write(layout: layout, appVersion: appVersion, now: now)
            }.value
            exported = written.exported
            phase = .ready(written.url)
        } catch {
            exported = []
            phase = .failed(Self.message(for: error))
        }
        refresh()
    }

    /// Dismissing the share sheet leaves the folder in Caches for the system to reclaim,
    /// and — if anything actually went into it — offers to retire what was sent.
    ///
    /// **The offer is here rather than on the send button, because this is the first moment
    /// the phone knows anything happened.** `UIActivityViewController`'s completion cannot
    /// tell us whether the AirDrop landed or the user cancelled, and the Mac says nothing
    /// back (091 · D4 — no second transport direction). So the app does not infer; it asks,
    /// once, at the point where the user has just watched the transfer and is the only
    /// party who knows.
    func finish() {
        phase = exported.isEmpty ? .idle : .sent(exported.count)
    }

    /// Move the last export's captures into `inbox/sent/` — the user asserting the Mac has
    /// them (096 · 3B).
    ///
    /// Nothing is deleted. The captures leave the pending set, so the next export is what
    /// was saved since rather than everything ever, and the toolbar count means "waiting"
    /// again. A capture that will not move stays pending and will simply be sent again;
    /// re-import collapses on blob hash, which is the property 091 · D4 bought.
    func retire() async {
        let layout = layout
        let ids = exported
        guard !ids.isEmpty else {
            phase = .idle
            return
        }
        await Task.detached(priority: .userInitiated) {
            InboxRetirement.retire(ids, in: layout)
        }.value
        exported = []
        phase = .idle
        refresh()
    }

    /// Decline the offer: the captures stay pending and will go out again next time. The
    /// safe answer, and the one a user picks when they are not sure the transfer worked.
    func keep() {
        exported = []
        phase = .idle
    }

    // MARK: - The run

    /// The folder, and which captures are in it.
    private struct Written: Sendable {
        let url: URL
        let exported: [UUID]
    }

    private nonisolated static func write(
        layout: InboxLayout, appVersion: String, now: Date
    ) throws -> Written {
        // Capture-time order, the same order the drain walks (405) — so a folder opened on
        // the Mac reads in the order the user actually saved things. Asked for by name
        // rather than spelled here, so the Mac-side round-trip test exercises THIS order.
        let records = try InboxArchive.pendingRecords(in: layout)

        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(Self.folderName(now), isDirectory: true)
        // A fresh folder every run: writing into a previous export would leave last time's
        // files beside this time's manifest, which is the one thing a manifest must never
        // be wrong about.
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let summary = try InboxArchive.write(
            records: records, layout: layout, to: root,
            appVersion: appVersion, exportedAt: now)
        return Written(url: root, exported: summary.exported)
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
