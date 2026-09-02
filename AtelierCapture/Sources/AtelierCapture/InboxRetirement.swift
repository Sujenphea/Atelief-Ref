// AtelierCapture — taking a capture out of the pending set without losing it (096 · 3B).
//
// **The problem this closes.** When this was written iOS never drained its inbox
// (`InboxDrain` lives in AtelierIngestion, which imported AppKit and did not build there;
// `.change-log/452` fixed the build and 454 wired the drain), so a capture made on the phone
// was a record plus a payload file, forever. It still is, from the export's point of view:
// `CaptureExport` reads ALL pending records on every run and `InboxArchive` deliberately
// deletes nothing afterwards — 091 · D4's reasoning, and it is right: the phone cannot know
// whether a share sheet was cancelled, an AirDrop failed, or an import ever ran, and import
// idempotency exists so re-sending is free.
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
//
// **Nothing is deleted — except when the library already holds the bytes** (096 · 4). Once
// the phone drains its own inbox, a retired capture comes in two shapes. A record still in
// `inbox/` has never been ingested anywhere: `sent/` is the only thing standing between it
// and oblivion, so it moves, exactly as before. A record in `inbox/ingested/` has been
// through the phone's pipeline and IS an asset with its blob on disk — the guarantee that
// nothing is lost is the library copy, and moving the record to `sent/` would keep a second
// one for no reason but symmetry. That second copy is the unbounded growth this file was
// written to end, deferred by one directory. So an ingested record and its payload are
// deleted outright.
//
// The `sent/` path is not a fallback and is not dead: a phone whose drain has not run yet
// — the share landed while the app was closed and the user cleared before the next launch
// — retires records that were never ingested, and those still move.

import Foundation

/// Moving retired captures out of the pending set (096 · 3B). A namespace — `static` only.
public enum InboxRetirement {

    /// What one retirement pass did.
    ///
    /// `Equatable` so a test asserts a pass as a value, the way ``DrainSummary`` is asserted
    /// rather than reconstructed from side effects.
    public struct Summary: Equatable, Sendable {
        /// Records that are no longer exportable — moved under `sent/`, or deleted because
        /// they were already ingested into the local library (096 · 4).
        ///
        /// One count for both fates on purpose. What a caller does with this number is
        /// tell the user how many captures left the waiting set, and "moved" versus
        /// "deleted" is a fact about which directory the phone had them in, not about
        /// anything the user asked for or can act on.
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
    /// **Two fates, decided by where the record is** (096 · 4). A record still in `inbox/`
    /// has never been ingested and moves to `sent/`; a record in `inbox/ingested/` is
    /// already an asset in the local library and is deleted, bytes and all. Which one
    /// applies is read off the disk rather than passed in, because the caller — a button —
    /// knows what the user asserted and has no business knowing which directory the drain
    /// left a capture in.
    ///
    /// An id in BOTH places is not a state the drain can produce: retention MOVES a record,
    /// so it is in one directory or the other. Both are handled anyway, and neither is
    /// skipped on account of the other, because the failure mode of guessing wrong is a
    /// pending record that every future export re-sends forever — which is the exact bug
    /// this file exists to end.
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
        // behind, for the reason `InboxLayout.LazyDirectory` gives. A pass that only
        // deletes ingested records creates nothing at all.
        var sentDirectory = InboxLayout.LazyDirectory(layout.sent)

        for id in ids {
            let hasPending = fileManager.fileExists(
                atPath: layout.recordURL(for: id).path)
            let hasIngested = fileManager.fileExists(
                atPath: layout.ingestedRecordURL(for: id).path)
            guard hasPending || hasIngested else {
                // Already retired, already drained by a host that discards, or never there.
                // Not a failure — the capture is not waiting to be sent, which is what was
                // being asked for.
                continue
            }

            var succeeded = true
            if hasIngested {
                succeeded = delete(id, in: layout, reclaimingInboxPayload: !hasPending)
            }
            if hasPending {
                sentDirectory.prepare()
                // Evaluated first so the move actually happens: `&&` short-circuits on the
                // left, and a capture must not be skipped because the other half of an
                // impossible pair failed.
                succeeded = moveToSent(id, in: layout) && succeeded
            }

            if succeeded {
                summary.retired += 1
            } else {
                summary.failed += 1
            }
        }
        return summary
    }

    /// Retire a capture that has never been ingested: move both its files to `sent/`.
    ///
    /// The payload moves FIRST, mirroring both the writer's commit order and the drain's
    /// quarantine: whatever ends up in `sent/` should be a whole capture rather than a
    /// record whose bytes are still somewhere else. The record moving last also means an
    /// interrupted pass leaves the capture pending — its record is still where
    /// ``InboxLayout/pendingRecordURLs()`` looks — which is the recoverable direction.
    ///
    /// A payload that will not move stops the retirement where it stands, rather than
    /// retiring a record away from bytes still sitting in the inbox.
    private static func moveToSent(_ id: UUID, in layout: InboxLayout) -> Bool {
        // Both destinations resolved through the layout's mirrors, not composed here — a
        // destination built by hand at a call site is a destination that drifts.
        let payload = layout.payloadURL(for: id)
        if FileManager.default.fileExists(atPath: payload.path) {
            guard InboxLayout.replacingMove(payload, to: layout.sentPayloadURL(for: id))
            else { return false }
        }
        return InboxLayout.replacingMove(
            layout.recordURL(for: id), to: layout.sentRecordURL(for: id))
    }

    /// Retire a capture the local library already holds: delete it.
    ///
    /// **The record goes first**, which is the drain's argument reached a third time. Bytes
    /// with no record are a leak nothing enumerates. A record with no bytes is worse than a
    /// leak: every future export reads it, refuses it (the funnel needs image bytes it does
    /// not have), and reports it as skipped — a capture that can never be sent and never
    /// stops being offered. Leak beats wedge, exactly as in `InboxDrain.discard(_:)`.
    ///
    /// `reclaimingInboxPayload` cleans up after an interrupted retention. `InboxDrain`
    /// moves the record before the payload, so a crash between the two leaves this id's
    /// bytes in `inbox/` under a record that has already moved — invisible to every
    /// enumeration, and reclaimable only here, at the moment the capture is finished with.
    /// It is passed as false when a pending record still exists, because then the name
    /// belongs to that record and ``moveToSent(_:in:)`` is the one entitled to it.
    private static func delete(
        _ id: UUID, in layout: InboxLayout, reclaimingInboxPayload: Bool
    ) -> Bool {
        guard InboxLayout.removeIfPresent(layout.ingestedRecordURL(for: id)) else {
            return false
        }

        // The record is the fate; a payload that survives either remove is bytes nothing
        // refers to, which the paragraph above already accepted — so the results are
        // dropped on purpose.
        InboxLayout.removeIfPresent(layout.ingestedPayloadURL(for: id))
        if reclaimingInboxPayload {
            InboxLayout.removeIfPresent(layout.payloadURL(for: id))
        }
        return true
    }
}
