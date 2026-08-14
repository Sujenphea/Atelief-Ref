// AtelierIngestion — the host's half of the handoff (092 · S3).
//
// `InboxWriter` puts captures in a directory and returns; this takes them out and
// runs them. Between the two there is no lock, no socket, and no shared process —
// only the ordering S2 established, and the fact that a record on disk means its
// bytes are already beside it.
//
// **Why this feeds the existing coordinator instead of owning a queue.** The
// obvious shape for "drain a directory of pending work" is a queue with its own
// concurrency, its own retry policy, and its own idea of progress. This is not
// that, for the same reason `startCaptureEndpoint` (`IngestionModel.swift:885`)
// is not: there is already exactly one bounded `IngestCoordinator` in the app,
// every ingest path funnels through it, and a second runner would mean two things
// deciding independently how much of the machine to spend on decoding images.
// The Chrome extension is a producer that hands the coordinator inputs; the inbox
// is the second producer doing the same thing, and it maps its records through the
// same `CaptureDecoder` funnel and the same `DirectInputReader.remote*` factories
// so provenance cannot drift between them — which matters because 18A dedup keys
// on provenance, and drift there forks assets quietly instead of crashing.
//
// **Why one pass, with no timer.** ``drainOnce()`` runs the inbox as it stands and
// returns what happened. It starts nothing, schedules nothing, and holds no state
// between calls — every fact it needs is on disk, which it has to be anyway,
// since the producer is another process that may have run hours ago. The caller
// owns cadence: at launch, on foreground, from a directory watcher, or from a test
// that wants a second pass to observe what the first one left behind. A drain that
// owned a timer would be untestable without waiting, and would have an opinion
// about foreground/background that belongs to the app, not to this package.
//
// **What survives a crash, and why deletion is ordered.** The record and its
// payload are removed only after the coordinator has reported `.ingested` or the
// capture has been quarantined. Dying anywhere before that re-runs the item on the
// next pass, and 18A blob-hash dedup makes the re-run resolve to the asset that is
// already there rather than to a second copy — so the failure mode of crashing
// mid-drain is a duplicate *attempt*, never a duplicate asset. Within the deletion
// the record goes FIRST, the inverse of the writer's order and for the mirror-image
// reason: a payload with no record is a few leaked bytes nobody enumerates, while a
// record whose payload has been deleted is permanently incomplete and would be
// skipped on every pass forever.
//
// **Three attempts, then out of the way.** Retry-forever is the failure mode a
// durable inbox invites: one capture that can never ingest is re-decoded on every
// launch for the life of the library. A transient failure stamps
// `InboxRecord.attempts` and re-commits the record through `InboxWriter`, and the
// third one moves the capture to `inbox/failed/`, where nothing enumerates it and
// a human can still find it.

import Foundation
import AtelierCapture
import AtelierCore

/// What one pass of the inbox did (092 · S3).
///
/// `Equatable` so a test asserts a pass as a value rather than reconstructing it
/// from side effects — "this pass ingested one and skipped one" is a single
/// comparison, and a pass that quietly did a fourth thing fails it.
///
/// The four counts are the four terminal fates of a record: it ingested, it was
/// not ready and was left alone, it was moved out of the way for good, or it
/// failed and will be tried again. A record whose ingest was cancelled mid-pass is
/// deliberately in none of them — see ``InboxDrain/drainOnce()``.
public struct DrainSummary: Equatable, Sendable {
    /// Records the coordinator ingested (including 18A dedups — a dedup IS a
    /// successful ingest, and the capture is just as done with).
    public var ingested: Int
    /// Records whose payload had not landed yet: a writer mid-flight, skipped this
    /// pass with `attempts` untouched.
    public var skippedIncomplete: Int
    /// Records moved to `inbox/failed/` — out of attempts, or malformed in a way no
    /// attempt could fix.
    public var quarantined: Int
    /// Records that failed and were re-committed with a higher `attempts`, to be
    /// picked up again next pass.
    public var retrying: Int

    public init(
        ingested: Int = 0, skippedIncomplete: Int = 0,
        quarantined: Int = 0, retrying: Int = 0
    ) {
        self.ingested = ingested
        self.skippedIncomplete = skippedIncomplete
        self.quarantined = quarantined
        self.retrying = retrying
    }
}

/// Runs the captures waiting in the inbox through the app's ingest coordinator
/// (092 · S3).
///
/// `Sendable` — it holds a layout (paths), an actor reference, and a writer that is
/// itself only paths.
public struct InboxDrain: Sendable {
    /// How many times a capture is attempted before it is quarantined. Three: enough
    /// that a transient disk or pressure blip does not cost a share, few enough that
    /// a capture which will never work stops costing a decode on every launch.
    public static let maxAttempts = 3

    /// The inbox being drained.
    public let layout: InboxLayout

    /// The app's single bounded coordinator — shared, never owned (see the note at
    /// the top of this file).
    private let coordinator: IngestCoordinator

    /// The producer's writer, reused for the one thing the drain writes: a record
    /// with a bumped attempt count. Rewriting it here with `Data.write` would be a
    /// second commit mechanism, and a subtly less careful one.
    private let writer: InboxWriter

    public init(layout: InboxLayout, coordinator: IngestCoordinator) {
        self.layout = layout
        self.coordinator = coordinator
        self.writer = InboxWriter(layout: layout)
    }

    /// The inbox under a Library root — the initializer the app uses, since it has a
    /// root from `LibraryLocation` before it has a `LibraryLayout`.
    public init(libraryRoot: URL, coordinator: IngestCoordinator) {
        self.init(
            layout: InboxLayout(libraryRoot: libraryRoot), coordinator: coordinator)
    }

    // MARK: - One pass

    /// Run every capture currently waiting in the inbox, and report what happened.
    ///
    /// Serial by design: each record is ingested and then resolved (deleted, stamped,
    /// or quarantined) before the next is read, so a crash leaves the inbox in a
    /// state one item wide rather than several. The concurrency that matters is
    /// already inside the coordinator, and a share sheet does not produce batches
    /// large enough for the outer loop to be the bottleneck.
    ///
    /// Never throws. An inbox that cannot be enumerated at all — a container that
    /// has gone away, a permissions failure — reports an empty pass rather than a
    /// crash, because a drain is something the app does on the way to somewhere
    /// else and must never be what stops it. The captures are still on disk; the
    /// next pass will find them.
    ///
    /// Cancelling the surrounding task stops the loop between records and leaves
    /// the current one untouched — an unfinished pass under-reports rather than
    /// mis-reports, and the inbox itself is the accounting that survives.
    public func drainOnce() async -> DrainSummary {
        var summary = DrainSummary()
        guard let pending = try? layout.pendingRecordURLs() else { return summary }

        for url in pending {
            if Task.isCancelled { break }

            guard let record = readRecord(at: url) else {
                // A record is committed by an atomic move, so what is here is whole
                // or is not here at all — undecodable means malformed, not early.
                // And there is nowhere to put an attempt count on a record that will
                // not parse, so quarantine is the only terminal state available.
                quarantineUnparsedRecord(at: url)
                summary.quarantined += 1
                continue
            }

            // A `payloadFile` the layout refuses — anything that is not the exact
            // name the writer produces for this record's id — is quarantined on
            // sight, with `attempts` untouched. A rejected name is malformed, not
            // transient: it will never become valid, so spending three passes on it
            // is waste. The attempts budget is for failures that might not happen
            // again — disk, decode, coordinator pressure. Note what this guard is
            // protecting: everything downstream (ingest, discard, quarantine) resolves
            // that name into a file it will read, DELETE or move, so a record naming a
            // sibling capture is a record that destroys one.
            if record.payloadFile != nil, layout.payloadURL(for: record) == nil {
                quarantine(record)
                summary.quarantined += 1
                continue
            }

            // The payload has not landed yet: the writer commits bytes before the
            // record, so this is a torn write and not data loss. Leave it exactly as
            // it is — no attempt is spent on a capture that was merely young.
            guard layout.isComplete(record) else {
                summary.skippedIncomplete += 1
                continue
            }

            await ingest(record, into: &summary)
        }

        return summary
    }

    /// Ingest one complete record and resolve it.
    private func ingest(_ record: InboxRecord, into summary: inout DrainSummary) async {
        let input: IngestInput
        do {
            input = try makeInput(for: record, payload: layout.payloadURL(for: record))
        } catch {
            // A `CaptureDecodeError` — an unknown platform, a media-less capture with
            // no payload. Treated as retryable rather than quarantined on sight: the
            // funnel is shared with the HTTP producer and may gain kinds and
            // platforms between the version that wrote this record and the version
            // reading it, so "this host does not understand it yet" is a state that
            // can resolve. Three passes, then out of the way.
            transientFailure(record, into: &summary)
            return
        }

        let outcomes = await coordinator.ingest([input])
        switch outcomes.first {
        case .ingested?:
            discard(record)
            summary.ingested += 1
        case .failed?:
            transientFailure(record, into: &summary)
        case .cancelled?, .none:
            // The batch was cancelled out from under us (or, impossibly, returned no
            // outcome for one input). The capture was not attempted, so it does not
            // spend an attempt and is not counted — it is simply still in the inbox,
            // which is the honest record of it.
            break
        }
    }

    /// Turn one record into the input the coordinator runs.
    ///
    /// Internal rather than private so a test can assert the ``ByteSource`` this
    /// produces without inferring it from the library that comes out the far end.
    /// That assertion is the point of the whole slice: bytes that are already on
    /// disk must arrive as ``ByteSource/fileURL(_:)``.
    ///
    /// The capture time is the record's `capturedAt`, NOT `Date()`. The HTTP funnel
    /// takes a server-owned `now` because a request is happening as it is decoded;
    /// a record may have been sitting in the inbox since before the last reboot, and
    /// the moment the user meant is the moment they hit share.
    ///
    /// The target collection is `collectionId ?? Collection.unsortedID` — the same
    /// default the capture endpoint applies (`IngestionModel.swift:893`). A share
    /// with no context lands where a browser capture with no target lands; there is
    /// no separate inbox collection, and nothing in the extension has to know the
    /// collection tree.
    func makeInput(for record: InboxRecord, payload: URL?) throws -> IngestInput {
        let request = record.request
        let capturedAt = record.capturedAt

        guard let payload else {
            // No sidecar: the record carries exactly what the Chrome extension POSTs
            // (including, for a base64-only capture the writer had no bytes to strip,
            // an inline `image`), so it goes through the identical funnel and the
            // identical factories.
            switch try CaptureDecoder.decodeInput(request, now: capturedAt) {
            case .image(let decoded):
                return DirectInputReader.remoteInput(
                    imageData: decoded.imageData,
                    provenance: decoded.provenance,
                    into: decoded.collectionID ?? Collection.unsortedID)
            case .content(let decoded):
                return DirectInputReader.remoteContent(
                    draft: decoded.draft,
                    provenance: decoded.provenance,
                    into: decoded.collectionID ?? Collection.unsortedID)
            case .contentWithImage(let decoded):
                return DirectInputReader.remoteContentWithImage(
                    draft: decoded.draft,
                    imageData: decoded.imageData,
                    provenance: decoded.provenance,
                    into: decoded.collectionID ?? Collection.unsortedID)
            }
        }

        // A sidecar: same funnel, same validation, but the bytes never leave disk.
        switch try CaptureDecoder.decodeFileInput(request, now: capturedAt) {
        case .bytes(let decoded):
            return DirectInputReader.remoteFile(
                fileURL: payload,
                provenance: decoded.provenance,
                into: decoded.collectionID ?? Collection.unsortedID)
        case .contentWithFile(let decoded):
            return DirectInputReader.remoteContentWithFile(
                draft: decoded.draft,
                fileURL: payload,
                provenance: decoded.provenance,
                into: decoded.collectionID ?? Collection.unsortedID)
        }
    }

    // MARK: - Resolving a record

    /// Spend one attempt: stamp the count and re-commit, or quarantine on the third.
    private func transientFailure(_ record: InboxRecord, into summary: inout DrainSummary) {
        var stamped = record
        stamped.attempts += 1

        guard stamped.attempts < Self.maxAttempts else {
            quarantine(stamped)
            summary.quarantined += 1
            return
        }

        do {
            try writer.rewrite(stamped)
            summary.retrying += 1
        } catch {
            // The stamp itself would not commit. Retrying anyway would retry forever,
            // since the count can never rise — so this is terminal, and quarantine is
            // where terminal goes.
            quarantine(stamped)
            summary.quarantined += 1
        }
    }

    /// The capture succeeded: take it out of the inbox.
    ///
    /// The record goes first. Deleting the payload first and then dying would leave a
    /// record naming bytes that are gone — permanently incomplete, and therefore
    /// skipped on every future pass rather than resolved. Losing the record first
    /// leaves orphaned bytes that nothing enumerates, which is a leak and not a
    /// wedge. Best-effort throughout: an already-ingested capture must not be
    /// re-ingested because its file could not be unlinked, and it will not be — the
    /// blob hash it would dedup against is now in the library.
    private func discard(_ record: InboxRecord) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: layout.recordURL(for: record.id))
        if let payload = layout.payloadURL(for: record) {
            try? fileManager.removeItem(at: payload)
        }
    }

    /// Move a capture to `inbox/failed/`, where nothing enumerates it.
    ///
    /// The record is re-encoded at its destination rather than moved, so the
    /// quarantined file carries the attempt count that actually exhausted — a
    /// `failed/` record reading `attempts: 2` would be a small lie told to whoever
    /// goes looking. The two-phase staging discipline is deliberately NOT applied
    /// here: it exists to keep the drain from reading a half-written record, and the
    /// drain does not read this directory. If the re-encode cannot be written, the
    /// original file is moved instead — a stale count beats a lost capture.
    private func quarantine(_ record: InboxRecord) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: layout.failed, withIntermediateDirectories: true)

        // The payload moves first, mirroring the writer: whatever is in `failed/`
        // should be a whole capture, not a record whose bytes are still elsewhere.
        // Resolved through the record, not through the bare name: a record quarantined
        // BECAUSE its `payloadFile` was refused must not have that name honoured on the
        // way out, or quarantine becomes the thing that carries off a sibling capture.
        if let from = layout.payloadURL(for: record),
            let to = layout.failedURL(named: InboxLayout.payloadFileName(for: record.id)) {
            move(from, to: to)
        }

        let origin = layout.recordURL(for: record.id)
        let destination = layout.failedRecordURL(for: record.id)
        if let encoded = try? InboxRecord.makeEncoder().encode(record),
            (try? encoded.write(to: destination, options: .atomic)) != nil {
            try? fileManager.removeItem(at: origin)
        } else {
            move(origin, to: destination)
        }
    }

    /// Quarantine a `.json` that would not parse, which means without a record to
    /// consult about the payload.
    ///
    /// The sidecar is guessed from the writer's naming convention — same stem, `.bin`
    /// extension — because that is the only thing left to go on, and leaving the
    /// bytes behind would leak them silently. The name comes from the enumeration, so
    /// it is a plain component by construction.
    private func quarantineUnparsedRecord(at url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: layout.failed, withIntermediateDirectories: true)

        let stem = url.deletingPathExtension().lastPathComponent
        let payloadName = "\(stem).\(InboxLayout.payloadExtension)"
        if let from = layout.payloadURL(named: payloadName),
            fileManager.fileExists(atPath: from.path),
            let to = layout.failedURL(named: payloadName) {
            move(from, to: to)
        }

        // `failedURL(named:)` and not ``InboxLayout/failedRecordURL(for:)``: there is
        // no record here to take an id from, and the file keeps the name it was
        // enumerated under rather than being renamed into a shape it may never have
        // had. The guard cannot refuse an enumerated name — asking it anyway is what
        // keeps `failed/` composed in one place instead of two.
        if let destination = layout.failedURL(named: url.lastPathComponent) {
            move(url, to: destination)
        }
    }

    // MARK: - Filesystem odds and ends

    /// Read and decode one record, or `nil` if either step fails. The two failures
    /// are not distinguished on purpose: the caller's only move for both is to
    /// quarantine, since neither leaves a record to count an attempt on.
    private func readRecord(at url: URL) -> InboxRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? InboxRecord.makeDecoder().decode(InboxRecord.self, from: data)
    }

    /// Move a file, clearing the destination first. Best-effort: quarantine is
    /// already the failure path, and failing to move a failed capture leaves it in
    /// the inbox to be attempted (and quarantined) again rather than losing it.
    private func move(_ from: URL, to destination: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try? fileManager.moveItem(at: from, to: destination)
    }
}
