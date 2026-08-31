// AtelierRefsMobile — handing this phone's captures to the Mac (092 · S6b, 096 · 4).
//
// **What this is exporting, and why it is not the library.** What there is to send is the
// INBOX, and `InboxArchive` turns it into a `LibraryArchive`-shaped folder the Mac already
// knows how to import. That was once true because iOS never drained its inbox at all; it
// is still true now that it does, and for a better reason: the phone's SQLite library holds
// only what the Mac has synced back to it, so the inbox record and its original payload are
// the only copy of a phone-made capture that can cross. 096 · 4's
// `InboxDrain.Retention.retainForExport` is what keeps them there after ingest.
//
// **"Pending" means pending EXPORT.** Since a drained record moves to `inbox/ingested/`
// rather than being deleted, the set this controller counts and sends is the union of
// `inbox/` and `inbox/ingested/` — which is exactly what `InboxArchive.pendingRecords(in:)`
// reads. Counting only the pending directory would make the toolbar's number fall to zero
// the moment the drain ran and quietly withdraw the send control from a phone with three
// captures still owed to the Mac.
//
// **The inbox is taken exclusively.** A drain pass moves records between those same two
// directories, so one running underneath an archive write would let a payload move out from
// under a copy that had already resolved its site. The export therefore runs inside
// ``InboxExclusion`` — see `InboxDrainPolicy`'s header for why the id-dedup inside
// `pendingRecords(in:)` is not an answer to that race.
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
import AtelierBrowse
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

    /// Takes the inbox away from the drain for the duration of a body (096 · 4).
    ///
    /// **No default**, for the same reason `InboxDrain.Retention` has none: a default would
    /// be a decision about who else is writing this directory, taken silently on behalf of
    /// every future caller, and the caller that gets it wrong loses a payload mid-copy
    /// rather than failing a build.
    private let exclusion: InboxExclusion

    init(libraryRoot: URL, appVersion: String, exclusion: @escaping InboxExclusion) {
        layout = InboxLayout(libraryRoot: libraryRoot)
        self.appVersion = appVersion
        self.exclusion = exclusion
    }

    /// Re-count what is waiting to be sent. Cheap — two directory listings — and safe to
    /// call on every appearance, which is what keeps the control honest after a share.
    ///
    /// **Both directories**, per the note at the top of this file: a record the drain has
    /// ingested has left `inbox/` for `inbox/ingested/` and is still owed to the Mac.
    ///
    /// Counted rather than decoded. `InboxArchive.pendingRecords(in:)` is the authority on
    /// what will actually be sent and it dedups ids across the two sets, so a hand-edited
    /// inbox holding one id in both places would be counted twice here and sent once. That
    /// is not a state the drain can produce — retention MOVES a record — and paying a
    /// decode of every record on every activation to be exact about it would spend a real
    /// cost on an impossible one.
    func refresh() {
        let waiting = (try? layout.pendingRecordURLs().count) ?? 0
        let drained = (try? layout.ingestedRecordURLs().count) ?? 0
        pending = waiting + drained
    }

    /// Write the archive, off the main actor and with the inbox to ourselves.
    ///
    /// `.working` is set BEFORE the wait rather than after it: the send button disables on
    /// that phase, and a control that stays live while an export queues behind a drain pass
    /// is a control that can be pressed twice.
    func export(now: Date = Date()) async {
        phase = .working
        await exclusion { [weak self] in
            guard let self else { return }
            await writeArchive(now: now)
        }
    }

    /// The archive write itself, once the inbox is ours.
    private func writeArchive(now: Date) async {
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

    /// Retire the last export's captures — the user asserting the Mac has them (096 · 3B).
    ///
    /// A record still in `inbox/` moves to `inbox/sent/`; one the drain has already
    /// ingested is DELETED, because the phone's own library holds the asset and its blob
    /// and a second copy under `sent/` would defer the unbounded growth 449 was written to
    /// end (096 · 4 · `InboxRetirement`). Which fate applies is read off the disk, not
    /// passed in: this is a button, and it knows what the user asserted rather than which
    /// directory the drain left a capture in.
    ///
    /// Under the same exclusion the export runs under, and for a sharper version of the
    /// same reason: this MOVES and DELETES records the drain may be reading in the middle
    /// of a pass. A capture that will not move stays where it is and will simply be sent
    /// again; re-import collapses on blob hash, which is the property 091 · D4 bought.
    func retire() async {
        let layout = layout
        let ids = exported
        guard !ids.isEmpty else {
            phase = .idle
            return
        }
        await exclusion { [weak self] in
            // The summary is counts the phone has nothing to say about: 449 argues the
            // user asked how many captures left the waiting set, and the toolbar answers
            // that by re-counting the inbox below.
            _ = await Task.detached(priority: .userInitiated) {
                InboxRetirement.retire(ids, in: layout)
            }.value
            guard let self else { return }
            exported = []
            phase = .idle
            refresh()
        }
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
