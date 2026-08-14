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
// **And it runs at the coordinator's width, not one at a time.** Handing the
// coordinator a one-element array pins a four-way runner to concurrency 1: the
// batch machinery is entered, primed with a single task, and drained — all of the
// ceremony and none of the parallelism. A backlog of fifty shares (a phone that
// captured all afternoon, opened on the Mac once) would decode strictly serially.
// So a pass fills a chunk of ``IngestCoordinator/maxConcurrent`` records, runs it,
// resolves every record in it, and only then starts the next. The width is READ
// FROM the coordinator rather than declared here, because a second constant would
// be two numbers meaning one thing and they would drift the first time either
// moved.
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
// **Capture order, not file order.** The enumeration comes back sorted by file
// name, and the file name is a UUIDv4 — so "sorted" there means shuffled. A pass
// reads and decodes every pending record ONCE, up front, and orders them by
// `InboxRecord.capturedAt`, which is the field S2 added for exactly this reason:
// the drain may run hours after the share, and the only moment that means anything
// is the one the user acted at. Reading up front is also what makes the ordering
// affordable — the previous shape read each record inside the loop, so ordering by
// anything inside a record would have meant reading every record twice.
//
// This is user-visible, and not through `capturedAt`. The asset's `source.captured_at`
// does carry the record's timestamp, but NOTHING in the library orders by that column:
// a collection sorts by `collection_item.manual_order` (`MAX + 1`, handed out per
// insert) or by `asset.created_at DESC` (`Date()`, stamped in the insert transaction),
// and search orders by `created_at DESC` too. So the position a drained share takes in
// the grid is decided by the order this loop reaches it — which, until now, was the
// order a random UUID happened to sort in. An afternoon of shares arrived shuffled.
//
// It is preserved only to CHUNK granularity, and that is the honest limit of it. The
// records in one chunk run concurrently and take their `manual_order` / `created_at`
// from whichever insert transaction commits first, so four shares that went out
// together can still land among themselves in any order. Across chunks the ordering
// holds. A fifty-share backlog that used to arrive fully shuffled now arrives in
// capture order give or take four positions, which is the price of the other half of
// this file's design — and the durable fix is not here anyway: it is ordering the
// library by `source.captured_at`, which is a change to every producer's ordering and
// belongs to whoever makes it.
//
// **What survives a crash, and why deletion is ordered.** The record and its
// payload are removed only after the coordinator has reported `.ingested` or the
// capture has been quarantined. Dying anywhere before that re-runs the item on the
// next pass, and 18A blob-hash dedup makes the re-run resolve to the asset that is
// already there rather than to a second copy — so the failure mode of crashing
// mid-drain is a duplicate *attempt*, never a duplicate asset. Chunking widens that
// window from one record to one chunk, and it is the same property that pays for
// it: a chunk interrupted after two of its four ingests leaves two records whose
// assets are already in the library, and the next pass dedups them onto those
// assets rather than duplicating them. Within the deletion the record goes FIRST,
// the inverse of the writer's order and for the mirror-image reason: a payload with
// no record is a few leaked bytes nobody enumerates, while a record whose payload
// has been deleted is permanently incomplete and would be skipped on every pass
// forever.
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

    /// The inbox itself could not be enumerated, so the four counts above say
    /// nothing about what is waiting in it.
    ///
    /// Not a fifth fate — no record was reached, and the flag is deliberately
    /// outside the counting. It exists because the drain never throws (see
    /// ``InboxDrain/drainOnce()``) and without it a vanished App Group container, a
    /// permissions failure and "nothing has ever been shared" are the same value:
    /// `DrainSummary()`. The first two are worth a diagnostic in the app; the third
    /// is the normal case on every launch. Only the caller can tell them apart, and
    /// only if it is told.
    public var inboxUnreadable: Bool

    public init(
        ingested: Int = 0, skippedIncomplete: Int = 0,
        quarantined: Int = 0, retrying: Int = 0,
        inboxUnreadable: Bool = false
    ) {
        self.ingested = ingested
        self.skippedIncomplete = skippedIncomplete
        self.quarantined = quarantined
        self.retrying = retrying
        self.inboxUnreadable = inboxUnreadable
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

    // MARK: - The state one pass carries

    /// What a pass accumulates as it goes: the summary being built, and whether
    /// `inbox/failed/` has been created yet.
    ///
    /// Threaded `inout` rather than stored, because ``InboxDrain`` is a value with
    /// no mutable state — two passes over the same inbox share nothing, which is
    /// what lets a caller drive cadence without asking this type anything.
    ///
    /// The directory flag is here so `mkdir` happens at most ONCE per pass instead
    /// of once per quarantined record at two separate call sites. Lazily, not up
    /// front: a pass that quarantines nothing must not leave an empty `failed/`
    /// behind, since `failed/` existing is the signal to a human that something
    /// went wrong.
    struct Pass {
        /// The counts, and the unreadable-inbox flag.
        var summary = DrainSummary()

        /// Whether `createDirectory` has already been attempted this pass.
        private var preparedFailedDirectory = false

        /// Spelled out because the synthesized memberwise initializer would inherit
        /// the private flag's access and a test could not start a pass.
        init() {}

        /// Ensure `inbox/failed/` exists, once. Best-effort like everything on the
        /// quarantine path: if the create fails, the moves that follow fail too and
        /// the capture stays in the inbox to be quarantined again next pass.
        mutating func prepareFailedDirectory(_ failed: URL) {
            guard !preparedFailedDirectory else { return }
            preparedFailedDirectory = true
            try? FileManager.default.createDirectory(
                at: failed, withIntermediateDirectories: true)
        }
    }

    /// One record that passed every pre-ingest check, paired with the input the
    /// coordinator will run for it. The pairing is the point: outcomes come back
    /// index-aligned with the inputs, so the record each outcome resolves must be
    /// carried alongside rather than looked up again.
    private struct Ready {
        let record: InboxRecord
        let input: IngestInput
    }

    /// A pending `.json`, in the two states reading the inbox can produce.
    private enum PendingEntry {
        /// A record that decoded, and can therefore be ordered by its capture time.
        case record(InboxRecord)
        /// A `.json` that would not read or would not decode. It has no capture time
        /// — that is what "would not decode" means — so it cannot take part in the
        /// ordering, and it is carried through the sort rather than dropped because
        /// it still has to be quarantined.
        case unreadable(URL)
    }

    // MARK: - One pass

    /// Run every capture currently waiting in the inbox, and report what happened.
    ///
    /// **Ordered by capture time.** Every pending record is read and decoded once,
    /// up front, and the pass then walks them oldest-capture-first
    /// (`InboxRecord.capturedAt`, ties broken by id so the order is total). Records
    /// that would not decode go FIRST, in file-name order among themselves: they
    /// have no capture time to be sorted by, so they need a defined position rather
    /// than an accidental one, and the front is the cheap end — quarantining is
    /// bookkeeping that touches no pipeline, so doing it before any ingest means an
    /// interrupted pass has already cleared out the records that could never drain.
    ///
    /// **Run in chunks, resolved chunk by chunk.** Records are gathered into chunks
    /// of ``IngestCoordinator/maxConcurrent`` and each chunk is fully resolved —
    /// deleted, stamped, or quarantined, by index — before the next one starts. So
    /// a crash leaves the inbox one chunk wide rather than one record wide, which is
    /// affordable for the same reason the one-record window was: 18A blob-hash dedup
    /// makes the re-run of an already-ingested capture resolve onto the asset that
    /// is there.
    ///
    /// Records inside a chunk run concurrently and therefore commit in an arbitrary
    /// order relative to each other, so the capture-time ordering is exact only
    /// BETWEEN chunks. It is not exact within one, and it cannot be made so without
    /// giving up the concurrency: the grid's order comes from `manual_order` /
    /// `created_at`, both stamped by the insert transaction that gets there first
    /// (the asset's own `capturedAt` is faithful either way — it is read from the
    /// record, see ``makeInput(for:payload:)`` — but nothing in the library orders by
    /// it). A chunk of four is therefore four positions of slack against a backlog
    /// that had no order at all before, which is a trade this takes deliberately
    /// rather than dodging it with a chunk size of one.
    ///
    /// Never throws. An inbox that cannot be enumerated at all — a container that
    /// has gone away, a permissions failure — reports ``DrainSummary/inboxUnreadable``
    /// rather than a crash, because a drain is something the app does on the way to
    /// somewhere else and must never be what stops it. The captures are still on
    /// disk; the next pass will find them.
    ///
    /// Cancelling the surrounding task stops the loop between chunks and leaves
    /// everything not yet resolved untouched — including records already gathered
    /// into a chunk that had not been run yet, since nothing has happened to them.
    /// An unfinished pass under-reports rather than mis-reports, and the inbox itself
    /// is the accounting that survives.
    public func drainOnce() async -> DrainSummary {
        var pass = Pass()

        guard let pending = try? layout.pendingRecordURLs() else {
            pass.summary.inboxUnreadable = true
            return pass.summary
        }

        // The width is the coordinator's own, asked for rather than restated.
        let width = max(1, coordinator.maxConcurrent)
        var chunk: [Ready] = []
        chunk.reserveCapacity(width)

        for entry in orderedEntries(of: pending) {
            if Task.isCancelled { return pass.summary }

            switch entry {
            case .unreadable(let url):
                // A record is committed by an atomic move, so what is here is whole
                // or is not here at all — undecodable means malformed, not early.
                // And there is nowhere to put an attempt count on a record that will
                // not parse, so quarantine is the only terminal state available.
                quarantineUnparsedRecord(at: url, into: &pass)

            case .record(let record):
                guard let input = prepare(record, into: &pass) else { continue }
                chunk.append(Ready(record: record, input: input))
                if chunk.count >= width {
                    await run(chunk, into: &pass)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        }

        // The tail chunk, unless the pass was cancelled while filling it — starting
        // work after cancellation would only earn a batch of `.cancelled` outcomes.
        if !chunk.isEmpty, !Task.isCancelled {
            await run(chunk, into: &pass)
        }

        return pass.summary
    }

    /// Read every pending `.json` ONCE and put them in the order the pass runs them.
    ///
    /// The read happens here and nowhere else: the loop is handed decoded records,
    /// so nothing is parsed twice. `urls` arrives in file-name order from
    /// ``InboxLayout/pendingRecordURLs()``, which is where the undecodable entries
    /// get their (stable, meaningless, but defined) relative order.
    private func orderedEntries(of urls: [URL]) -> [PendingEntry] {
        var records: [InboxRecord] = []
        records.reserveCapacity(urls.count)
        var unreadable: [PendingEntry] = []

        for url in urls {
            if let record = readRecord(at: url) {
                records.append(record)
            } else {
                unreadable.append(.unreadable(url))
            }
        }

        // Oldest share first. The id breaks ties so two captures stamped in the same
        // instant still have ONE order rather than whatever the sort felt like.
        records.sort {
            $0.capturedAt == $1.capturedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.capturedAt < $1.capturedAt
        }

        return unreadable + records.map(PendingEntry.record)
    }

    /// Everything that has to be decided about a record before the coordinator sees
    /// it: the input to run, or `nil` if the record was resolved here instead.
    private func prepare(_ record: InboxRecord, into pass: inout Pass) -> IngestInput? {
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
            quarantine(record, into: &pass)
            return nil
        }

        // The payload has not landed yet: the writer commits bytes before the
        // record, so this is a torn write and not data loss. Leave it exactly as
        // it is — no attempt is spent on a capture that was merely young.
        guard layout.isComplete(record) else {
            pass.summary.skippedIncomplete += 1
            return nil
        }

        do {
            return try makeInput(for: record, payload: layout.payloadURL(for: record))
        } catch {
            // A `CaptureDecodeError` — an unknown platform, a media-less capture with
            // no payload. Treated as retryable rather than quarantined on sight: the
            // funnel is shared with the HTTP producer and may gain kinds and
            // platforms between the version that wrote this record and the version
            // reading it, so "this host does not understand it yet" is a state that
            // can resolve. Three passes, then out of the way.
            transientFailure(record, into: &pass)
            return nil
        }
    }

    /// Run one chunk through the coordinator and resolve every record in it.
    ///
    /// The outcomes come back index-aligned with the inputs (`IngestCoordinator`
    /// guarantees it, filling unstarted slots with `.cancelled`), so the pairing is
    /// positional — which is why ``Ready`` carries the record alongside its input
    /// rather than the chunk being two parallel arrays that could slip.
    private func run(_ chunk: [Ready], into pass: inout Pass) async {
        let outcomes = await coordinator.ingest(chunk.map(\.input))
        for (index, item) in chunk.enumerated() {
            resolve(
                item.record,
                outcome: index < outcomes.count ? outcomes[index] : nil,
                into: &pass)
        }
    }

    /// Apply one coordinator outcome to the record it belongs to.
    ///
    /// Internal rather than private so a test can drive an outcome the coordinator
    /// only produces under cancellation. `IngestCoordinator` is a concrete actor over
    /// a concrete pipeline with no seam to stub, and `.cancelled` arrives from
    /// `runBounded` only in the window where the surrounding task is cancelled
    /// between this pass's own check and the batch being primed — a window a test
    /// cannot open deterministically from the outside. The cheapest honest way to
    /// hold the rule ("a cancelled record spends nothing and is counted nowhere") is
    /// to call this with the outcome, rather than to make production code mockable
    /// for its own sake.
    ///
    /// `nil` is the impossible case — the coordinator returned fewer outcomes than
    /// inputs — and is treated exactly like `.cancelled`, since "we were told
    /// nothing about this record" and "this record was not attempted" have the same
    /// correct response.
    func resolve(_ record: InboxRecord, outcome: IngestOutcome?, into pass: inout Pass) {
        switch outcome {
        case .ingested?:
            discard(record)
            pass.summary.ingested += 1
        case .failed?:
            transientFailure(record, into: &pass)
        case .cancelled?, .none:
            // The capture was not attempted, so it does not spend an attempt and is
            // not counted — it is simply still in the inbox, which is the honest
            // record of it.
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
    /// the moment the user meant is the moment they hit share. It is also why the
    /// order a pass runs records in cannot change the timestamp any of them gets.
    ///
    /// The target collection is ``targetCollection(_:)`` — the same default the
    /// capture endpoint applies (`IngestionModel.swift:893`). A share with no context
    /// lands where a browser capture with no target lands; there is no separate inbox
    /// collection, and nothing in the extension has to know the collection tree.
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
                    into: Self.targetCollection(decoded.collectionID))
            case .content(let decoded):
                return DirectInputReader.remoteContent(
                    draft: decoded.draft,
                    provenance: decoded.provenance,
                    into: Self.targetCollection(decoded.collectionID))
            case .contentWithImage(let decoded):
                return DirectInputReader.remoteContentWithImage(
                    draft: decoded.draft,
                    imageData: decoded.imageData,
                    provenance: decoded.provenance,
                    into: Self.targetCollection(decoded.collectionID))
            }
        }

        // A sidecar: same funnel, same validation, but the bytes never leave disk.
        switch try CaptureDecoder.decodeFileInput(request, now: capturedAt) {
        case .bytes(let decoded):
            return DirectInputReader.remoteFile(
                fileURL: payload,
                provenance: decoded.provenance,
                into: Self.targetCollection(decoded.collectionID))
        case .contentWithFile(let decoded):
            return DirectInputReader.remoteContentWithFile(
                draft: decoded.draft,
                fileURL: payload,
                provenance: decoded.provenance,
                into: Self.targetCollection(decoded.collectionID))
        }
    }

    /// Where a decoded capture lands: the collection it named, or Unsorted.
    ///
    /// One function because it is one policy, and the two switches above reach it
    /// from five places. Spelled out five times it was five chances for a future
    /// kind to acquire a different default by nobody's decision — which is the shape
    /// of bug that surfaces as "some shares go to the wrong place", months later.
    private static func targetCollection(_ collectionID: UUID?) -> UUID {
        collectionID ?? Collection.unsortedID
    }

    // MARK: - Resolving a record

    /// Spend one attempt: stamp the count and re-commit, or quarantine on the third.
    private func transientFailure(_ record: InboxRecord, into pass: inout Pass) {
        var stamped = record
        stamped.attempts += 1

        guard stamped.attempts < Self.maxAttempts else {
            quarantine(stamped, into: &pass)
            return
        }

        do {
            try writer.rewrite(stamped)
            pass.summary.retrying += 1
        } catch {
            // The stamp itself would not commit. Retrying anyway would retry forever,
            // since the count can never rise — so this is terminal, and quarantine is
            // where terminal goes.
            quarantine(stamped, into: &pass)
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
    ///
    /// Counts the record as it moves it. The count used to live at each of the three
    /// call sites, which is three chances for a future fourth one to move a capture
    /// out of the inbox without saying so in the summary.
    private func quarantine(_ record: InboxRecord, into pass: inout Pass) {
        pass.summary.quarantined += 1
        pass.prepareFailedDirectory(layout.failed)

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
            try? FileManager.default.removeItem(at: origin)
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
    private func quarantineUnparsedRecord(at url: URL, into pass: inout Pass) {
        pass.prepareFailedDirectory(layout.failed)

        let stem = url.deletingPathExtension().lastPathComponent
        let payloadName = "\(stem).\(InboxLayout.payloadExtension)"
        if let from = layout.payloadURL(named: payloadName),
            FileManager.default.fileExists(atPath: from.path),
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

        pass.summary.quarantined += 1
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
