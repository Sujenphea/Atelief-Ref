// AtelierRefsMobile — the inbox side of the export, and the folder it leaves behind
// (092 · S6b, 096 · 4, 098 · P3).
//
// The phase machine that used to be here — `.idle → .working → .ready → .sent → .idle`,
// the offer to retire, and the invariant that a "Clear" may only retire the ids that
// reached the last manifest — is `AtelierBrowse/CaptureExportController.swift` now, with
// 23 tests. What is left in this file is the I/O those tests inject: three closures over
// `InboxArchive` and `InboxRetirement`, each hopping off the main actor, plus the one
// directory this app owns.
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
// `inbox/` and `inbox/ingested/` — which is exactly what `InboxArchive.pending(in:)`
// reads. Counting only the pending directory would make the toolbar's number fall to zero
// the moment the drain ran and quietly withdraw the send control from a phone with three
// captures still owed to the Mac. And it is that call's RECORDS that are counted, not the
// `.json` files beside them: one file that will not decode is one capture the export can
// never carry, and the button used to promise it anyway, forever (098 · finding 8).
//
// **The inbox is taken exclusively.** A drain pass moves records between those same two
// directories, so one running underneath an archive write would let a payload move out from
// under a copy that had already resolved its site. The export therefore runs inside
// ``InboxExclusion`` — see `InboxDrainPolicy`'s header for why the id-dedup inside
// `InboxArchive.pending(in:)` is not an answer to that race.
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
// the user to hand it somewhere. Exactly one exists: `InboxArchive.writeExport` clears
// every sibling under `Exports/` before it writes (098 · finding 4).

import AtelierArchive
import AtelierBrowse
import AtelierCapture
import Foundation

/// The export controller as this app builds it.
typealias CaptureExport = CaptureExportController

extension CaptureExportController {
    /// Wire the controller to this device's inbox.
    ///
    /// Each seam is `@MainActor` (see the typealiases) and each of the two that touch more
    /// than a directory listing hops off it here. The count does NOT: it is a read of a few
    /// hundred ~350-byte records on an activation, it is the number the toolbar draws with,
    /// and making it async would mean the control flickering in on a frame of its own.
    convenience init(
        libraryRoot: URL, appVersion: String, exclusion: @escaping InboxExclusion
    ) {
        let layout = InboxLayout(libraryRoot: libraryRoot)
        self.init(
            exportsParent: Self.exportsDirectory,
            exclusion: exclusion,
            pendingCount: { try InboxArchive.pending(in: layout).records.count },
            write: { parent, folderName, now in
                try await Task.detached(priority: .userInitiated) {
                    try Self.write(
                        layout: layout, parent: parent, folderName: folderName,
                        appVersion: appVersion, now: now)
                }.value
            },
            retire: { ids in
                // The summary is counts the phone has nothing to say about: 449 argues the
                // user asked how many captures left the waiting set, and the toolbar
                // answers that by re-counting the inbox afterwards.
                _ = await Task.detached(priority: .userInitiated) {
                    InboxRetirement.retire(ids, in: layout)
                }.value
            })
    }

    /// The archive write, off the main actor and with the inbox already ours.
    private nonisolated static func write(
        layout: InboxLayout, parent: URL, folderName: String, appVersion: String, now: Date
    ) throws -> Written {
        do {
            // Capture-time order, the same order the drain walks (405) — so a folder opened
            // on the Mac reads in the order the user actually saved things. Asked for by
            // name rather than spelled here, so the Mac-side round-trip test exercises THIS
            // order. The pair carries what would not decode alongside it, so the manifest's
            // `skipped` and the count on the button describe the same inbox (098 · 8).
            let pending = try InboxArchive.pending(in: layout)

            // The folder lifecycle belongs to the package that owns the format (098 ·
            // finding 4): it clears EVERY sibling under `Exports/`, not just a folder of
            // this minute's name, so two sends a minute apart cannot leave two complete
            // copies of every capture in Caches for "Clear" to orphan.
            let export = try InboxArchive.writeExport(
                pending, layout: layout, under: parent, folderName: folderName,
                appVersion: appVersion, now: now)
            return Written(url: export.folder, exported: export.summary.exported)
        } catch let error as InboxArchive.WriteError {
            // Translated rather than re-thrown: the controller lives in a package that does
            // not link AtelierArchive, so the two failures worth a sentence of their own
            // cross as `CaptureExportFailure` and everything else becomes the third
            // sentence by falling through.
            switch error {
            case .nothingToExport: throw CaptureExportFailure.nothingToExport
            case .nothingCopied: throw CaptureExportFailure.nothingCopied
            }
        }
    }

    /// Where exports go: `Caches/Exports/`, owned entirely by this controller.
    ///
    /// A copy of bytes the inbox still holds, so the system is free to reclaim it, and
    /// excluded from backup by `MobileIngest.makeDrain` for the same reason the derived
    /// media directories are — it is regenerable from the inbox in one tap. Spelled here
    /// rather than there because this is what owns the directory; the drain's backup
    /// hygiene only borrows the path.
    nonisolated static let exportsDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Exports", isDirectory: true)
}
