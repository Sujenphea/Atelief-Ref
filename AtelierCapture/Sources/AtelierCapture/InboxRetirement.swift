// AtelierCapture — taking a capture out of the pending set without losing it (096 · 3B).
//
// **The problem this closes.** iOS never drains its inbox (`InboxDrain` lives in
// AtelierIngestion, which imports AppKit and does not build there), so a capture made on the
// phone is a record plus a payload file, forever. `CaptureExport` reads ALL pending records
// on every run and `InboxArchive` deliberately deletes nothing afterwards — 091 · D4's
// reasoning, and it is right: the phone cannot know whether a share sheet was cancelled, an
// AirDrop failed, or an import ever ran, and import idempotency exists so re-sending is free.
//
// The consequence was never written down. Every export contained every capture ever made:
// export twelve re-sends the same two hundred payloads export eleven sent, `inbox/` grows for
// the life of the device, and the only way to reclaim the space is to delete the app. Correct
// and unbounded.
//
// **So retirement is the user's assertion, not the app's inference.** Nothing here runs
// automatically and nothing here deletes. A capture moves from `inbox/` into `inbox/sent/`,
// which takes it out of ``InboxLayout/pendingRecordURLs()`` — so the next export is the
// captures made since, and the count on the toolbar means "waiting" again rather than
// "ever". The bytes stay on disk, and the assertion is reversible by dragging a file back.
//
// *Why not a receipt from the Mac.* An acknowledgement round-trip — the importer writes the
// ids it ingested, the phone consumes it — is more rigorous and is the thin end of the
// two-way sync 091 · D4 spent a paragraph refusing. Conflict resolution over collections,
// ordering and geometry is a design problem the size of that document. One control that the
// user presses when they have seen the import land is a complete answer to storage growth
// and introduces no second transport direction.
//
// **Best-effort, per record, and reported.** A move that fails leaves that capture pending,
// which is the safe direction: it will be exported again, and re-import collapses on blob
// hash. Nothing here can produce a record the drain would misread, because nothing here
// writes a record — it only moves whole files that were already committed.

import Foundation

/// Moving retired captures out of the pending set (096 · 3B). A namespace — `static` only.
public enum InboxRetirement {

    /// What one retirement pass did.
    ///
    /// `Equatable` so a test asserts a pass as a value, the way ``DrainSummary`` is asserted
    /// rather than reconstructed from side effects.
    public struct Summary: Equatable, Sendable {
        /// Records whose files are now under `sent/`.
        public var retired: Int
        /// Records that could not be moved and are still pending. Not a failure of the
        /// pass — they will be exported again, and the re-import dedups.
        public var failed: Int

        public init(retired: Int = 0, failed: Int = 0) {
            self.retired = retired
            self.failed = failed
        }
    }

    /// Retire the captures named by `ids`.
    ///
    /// **Only ids the caller has confirmed reached the Mac.** This takes a list rather than
    /// retiring everything pending, because "what was exported" and "what is in the inbox"
    /// are different sets the moment a share is made while the share sheet is open — and
    /// because `InboxArchive` skips records its funnel refuses, which must stay pending
    /// rather than being retired on the strength of an export they were not in.
    ///
    /// The payload moves FIRST, mirroring both the writer's commit order and the drain's
    /// quarantine: whatever ends up in `sent/` should be a whole capture rather than a
    /// record whose bytes are still somewhere else. The record moving last also means an
    /// interrupted pass leaves the capture pending — its record is still where
    /// ``InboxLayout/pendingRecordURLs()`` looks — which is the recoverable direction.
    ///
    /// Never throws. A capture that will not move is counted and stepped over; this runs
    /// behind a button on a phone, and a half-finished tidy-up must not become an error the
    /// user has to understand.
    @discardableResult
    public static func retire(_ ids: [UUID], in layout: InboxLayout) -> Summary {
        var summary = Summary()
        guard !ids.isEmpty else { return summary }

        let fileManager = FileManager.default
        // Lazily, and once — a pass that retires nothing must not leave an empty `sent/`
        // behind, for the same reason the drain does not leave an empty `failed/`: the
        // directory existing is itself a signal to whoever goes looking.
        var preparedDirectory = false

        for id in ids {
            let record = layout.recordURL(for: id)
            guard fileManager.fileExists(atPath: record.path) else {
                // Already retired, already drained, or never there. Not a failure — the
                // capture is not pending, which is what was being asked for.
                continue
            }
            if !preparedDirectory {
                preparedDirectory = true
                try? fileManager.createDirectory(
                    at: layout.sent, withIntermediateDirectories: true)
            }

            // Resolved through the layout, not composed here — the guard that stops a name
            // escaping the inbox is the same one `failedURL(named:)` applies, asked in the
            // one place that owns it.
            let payloadName = InboxLayout.payloadFileName(for: id)
            let payload = layout.payloadURL(for: id)
            if fileManager.fileExists(atPath: payload.path),
               let destination = layout.sentURL(named: payloadName) {
                guard move(payload, to: destination) else {
                    summary.failed += 1
                    continue
                }
            }

            if move(record, to: layout.sentRecordURL(for: id)) {
                summary.retired += 1
            } else {
                summary.failed += 1
            }
        }
        return summary
    }

    /// Move a file, clearing the destination first. Mirrors `InboxDrain.move` — a retire of
    /// an id already in `sent/` (a second press, a re-export of the same capture) overwrites
    /// rather than failing, since the two files are the same capture by construction.
    private static func move(_ from: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: from, to: destination)
            return true
        } catch {
            return false
        }
    }
}
