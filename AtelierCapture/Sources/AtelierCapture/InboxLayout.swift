// AtelierCapture — where the handoff lives on disk (092 · S2).
//
// The inbox is the directory the iOS share extension appends to and the host app
// drains (091 · D2). Both processes need to agree on its shape down to the file
// name, and they are compiled into different binaries with different link lines,
// so the shape is named exactly once — here.
//
// **Why this is in AtelierCapture and not AtelierIngestion**, where 092's prose put
// it: `AtelierIngestion` imported AppKit (`Input/DirectInputReader.swift`) and so could
// not build for iOS at all; the share extension could never link it. `.change-log/452`
// split that file and the package builds for iOS now — but the answer does not change,
// because the second half of it never depended on the first: this package is
// transport-free and platform-free by construction, the extension already links it, and
// what an extension needs from the handoff is its SHAPE, not the pipeline that drains
// it. `LibraryLayout.inbox` delegates to ``InboxLayout/directoryName`` rather
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
// Everything here is pure path arithmetic and creates nothing, with the marked
// exceptions at the bottom. Three are questions — "which records are pending", "which
// have been ingested already" and "is this one complete" cannot be answered without
// looking at the disk. The first and third are the two questions 092 · S3's drain
// opens with; the second is the one 096 · 4 added for the phone. They live beside the
// paths they interrogate rather than in a third type.
//
// The rest are the three filesystem primitives every mover of inbox files shares — a
// replacing move, a tolerant remove, and a directory created at most once and only when
// something is about to go in it (457). `InboxDrain`, `InboxRetirement` and the test
// fixtures each spelled them, and three spellings of "move a file, clearing the
// destination" is three chances for one of them to stop clearing it. They are here
// rather than in a fourth type for the reason the record mirrors are: composition of
// an inbox path lives in this file or it drifts, and the operation that consumes the
// path belongs beside the path.

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

    /// Where the phone puts a capture it has handed to the Mac (096 review 3B). A plain
    /// subdirectory beside ``failedDirectoryName``, and skipped by ``pendingRecordURLs()``
    /// for the same reason: the enumeration takes only top-level `*.json`, and a directory
    /// has no extension.
    ///
    /// **Moved, never deleted, and that is the whole design.** 091 · D4 bought import
    /// idempotency so an export could be re-sent, re-imported, AirDropped twice — the
    /// phone keeps its records precisely because it cannot know that a share sheet was not
    /// cancelled, that an AirDrop arrived, or that an import ever ran. Retiring a capture
    /// is the user asserting that it did; `sent/` is where the bytes go on that assertion,
    /// so the assertion is reversible by dragging a file back.
    ///
    /// It exists because "nothing is deleted" was true and unbounded: every export re-sent
    /// every capture ever made, and `inbox/` grew for the life of the device with no way to
    /// reclaim it short of deleting the app.
    public static let sentDirectoryName = "sent"

    /// Where a drain that is not the capture's final destination parks a record it has
    /// ingested (096 · 4). A plain subdirectory beside ``failedDirectoryName`` and
    /// ``sentDirectoryName``, skipped by ``pendingRecordURLs()`` for the same reason both
    /// of those are: the enumeration takes only top-level `*.json`, and a directory has no
    /// extension.
    ///
    /// **Why ingestion stopped being the end of a record's life.** On the Mac it still is:
    /// the library a capture drains into IS the destination, so `InboxDrain` deletes the
    /// record, and the record's absence is the commit marker saying the capture arrived.
    /// On the phone the same ingest is half of the trip. The capture appears in the phone's
    /// own grid, and it is still owed to the Mac — which `InboxArchive` sends by reading
    /// the inbox, because the phone's SQLite library holds only what has been synced back
    /// to it. A drain that deleted the record there would destroy the one copy export has.
    ///
    /// So a record that has been ingested but must not be destroyed moves HERE: out of
    /// ``pendingRecordURLs()``, so no later pass drains it a second time, and still on disk
    /// under a name the export knows to read.
    ///
    /// **Not `sent/`, which was the obvious place to reuse.** That directory means "the
    /// user asserted this reached the Mac"; these captures have asserted nothing and are
    /// exactly the ones still waiting to go. Folding them together would make the next
    /// export skip a capture the phone had never sent.
    public static let ingestedDirectoryName = "ingested"

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
    /// root but do not link `AtelierIngestion`.
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

    /// `<inbox>/sent/` — where 096 review 3B retires a capture the user has confirmed
    /// reached the Mac.
    public var sent: URL {
        directory.appendingPathComponent(
            InboxLayout.sentDirectoryName, isDirectory: true)
    }

    /// `<inbox>/ingested/` — where 096 · 4's retaining drain parks a capture that is in
    /// the local library and still owed to the Mac.
    public var ingested: URL {
        directory.appendingPathComponent(
            InboxLayout.ingestedDirectoryName, isDirectory: true)
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

    /// Where a quarantined record lands: `<inbox>/failed/<uuid>.json`.
    ///
    /// The `failed/` mirror of ``recordURL(for:)``, and it exists for the same reason
    /// that one does: the drain quarantines from two places and hand-built both
    /// destinations, so a reader of either could reasonably conclude that composing a
    /// path into `failed/` by hand is fine — next to a line that carefully asks
    /// ``failedURL(named:)`` for permission. Composition lives here or it drifts.
    public func failedRecordURL(for id: UUID) -> URL {
        failed.appendingPathComponent(
            InboxLayout.recordFileName(for: id), isDirectory: false)
    }

    /// Resolve a file name that has no record to check it against — the sidecar the
    /// drain GUESSES for a `.json` that would not parse — or `nil` when the name could
    /// not be appended to this directory at all.
    ///
    /// The name arrives from a file that crossed a process boundary, so it is treated
    /// as data rather than as a path: anything that is not a single, non-relative path
    /// component is refused instead of being resolved into a URL that escapes the
    /// inbox.
    ///
    /// **This is not the accessor for a record's `payloadFile`** — see
    /// `payloadURL(for record:)`, which holds that name to a much stricter standard.
    /// Being a plain component only proves a name cannot escape the inbox; it says
    /// nothing about the name belonging to the record that supplied it.
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

    /// Where a retired record lands: `<inbox>/sent/<uuid>.json`. The `sent/` mirror of
    /// ``failedRecordURL(for:)``, composed here for the reason that one is — a destination
    /// built by hand at a call site is a destination that drifts from this file.
    public func sentRecordURL(for id: UUID) -> URL {
        sent.appendingPathComponent(
            InboxLayout.recordFileName(for: id), isDirectory: false)
    }

    /// The retired location of a file currently sitting in the inbox, under the same guard
    /// as ``payloadURL(named:)`` and ``failedURL(named:)``.
    public func sentURL(named name: String) -> URL? {
        guard InboxLayout.isPlainComponent(name) else { return nil }
        return sent.appendingPathComponent(name, isDirectory: false)
    }

    /// Where an ingested record lands: `<inbox>/ingested/<uuid>.json`. The `ingested/`
    /// mirror of ``failedRecordURL(for:)`` and ``sentRecordURL(for:)``, composed here for
    /// the reason those are — a destination built by hand at a call site is a destination
    /// that drifts from this file.
    public func ingestedRecordURL(for id: UUID) -> URL {
        ingested.appendingPathComponent(
            InboxLayout.recordFileName(for: id), isDirectory: false)
    }

    /// The ingested location of a file currently sitting in the inbox, under the same guard
    /// as ``payloadURL(named:)``, ``failedURL(named:)`` and ``sentURL(named:)``.
    ///
    /// The guard is not ceremony here either. A drain retaining a record resolves that
    /// record's `payloadFile` for MOVING, exactly as quarantine does, and a name that could
    /// be talked into leaving the inbox on the way to `failed/` could be talked into it on
    /// the way to `ingested/` — same name, same crossing of a process boundary, same
    /// answer.
    public func ingestedURL(named name: String) -> URL? {
        guard InboxLayout.isPlainComponent(name) else { return nil }
        return ingested.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - The payload mirrors

    /// Where a quarantined payload lands: `<inbox>/failed/<uuid>.bin` — the `failed/`
    /// mirror of ``payloadURL(for:)-(UUID)``, and the sidecar half of
    /// ``failedRecordURL(for:)``.
    ///
    /// Non-optional where ``failedURL(named:)`` is not, and that is the difference
    /// between the two: the name here is derived from an id through
    /// ``payloadFileName(for:)``, so it is a plain component by construction and there is
    /// nothing for the guard to refuse. A caller holding a record's id asks this;
    /// ``failedURL(named:)`` is for a name that arrived from disk with no record to check
    /// it against. Until 457 the drain composed this by hand at its quarantine site —
    /// `failedURL(named: payloadFileName(for:))` — which was the record mirror's own
    /// argument ("composition lives here or it drifts") applied to half the files.
    public func failedPayloadURL(for id: UUID) -> URL {
        failed.appendingPathComponent(
            InboxLayout.payloadFileName(for: id), isDirectory: false)
    }

    /// Where a retired payload lands: `<inbox>/sent/<uuid>.bin` — the `sent/` mirror of
    /// ``payloadURL(for:)-(UUID)``, composed here for the reason
    /// ``failedPayloadURL(for:)`` is.
    public func sentPayloadURL(for id: UUID) -> URL {
        sent.appendingPathComponent(
            InboxLayout.payloadFileName(for: id), isDirectory: false)
    }

    /// Where a retained payload lands: `<inbox>/ingested/<uuid>.bin` — the `ingested/`
    /// mirror of ``payloadURL(for:)-(UUID)``, composed here for the reason
    /// ``failedPayloadURL(for:)`` is. It is the second site `InboxArchive` looks for a
    /// record's bytes at, and the one both the drain and the export must agree on.
    public func ingestedPayloadURL(for id: UUID) -> URL {
        ingested.appendingPathComponent(
            InboxLayout.payloadFileName(for: id), isDirectory: false)
    }

    // MARK: - The retention plan

    /// One file move in a plan, named by which of a capture's two files it moves.
    public struct FileMove: Equatable, Sendable {
        /// Which of a capture's files a move carries.
        public enum File: Equatable, Sendable {
            case record
            case payload
        }

        public let file: File
        public let from: URL
        public let to: URL

        public init(file: File, from: URL, to: URL) {
            self.file = file
            self.from = from
            self.to = to
        }
    }

    /// The moves that take an ingested capture out of the pending set and into
    /// `ingested/`, **in the order they must be made**: the record first, then its
    /// payload (096 · 4).
    ///
    /// The order is the whole content of this plan, which is why it is a list and not
    /// two properties a caller could consume either way round. The two facts the inbox
    /// encodes are "pending", which is the record sitting at the top level where
    /// ``pendingRecordURLs()`` looks, and "complete", which is the payload sitting beside
    /// it (``isComplete(_:)``). Move the payload first and an interruption leaves a record
    /// that is still pending and no longer complete — and `isComplete` returning false
    /// means one specific thing to the next pass: *the writer is mid-flight, come back
    /// later*. That answer never changes, because there is no writer. The capture is
    /// skipped as incomplete on every pass for the life of the device. A wedge.
    ///
    /// Move the record first and an interruption leaves an ingested record whose bytes
    /// are still in the inbox top level. Nothing is confused by that: the enumeration
    /// takes only `*.json`, so a stray `.bin` is invisible to every pass, and the export
    /// resolves a payload from either site precisely so this state reads as a whole
    /// capture. `InboxRetirement` reclaims the stray when the capture is cleared. A leak.
    /// Leak beats wedge.
    ///
    /// **Why the plan is here and not only in the drain that executes it.** Two test
    /// suites in packages that must not link `AtelierIngestion` — this one's, and
    /// `AtelierArchive`'s — need to leave an inbox in the state a retaining drain leaves
    /// it in, and until 457 each hand-rolled the two moves. A change to the drain's order
    /// would have left both green. Now the drain and the fixture execute this list, so
    /// there is one statement of the order and a fixture cannot drift from it.
    ///
    /// The payload move is present only when the record names its own sidecar, through
    /// ``payloadURL(for:)-(InboxRecord)``: a record that named a neighbour's file must not
    /// have that name honoured by the thing that moves files, and a media-less record has
    /// nothing to move. A payload named but absent from disk is still planned — the
    /// executor decides what a failed move means, since the drain and a fixture disagree
    /// about that (best-effort versus throw).
    public func retentionMoves(for record: InboxRecord) -> [FileMove] {
        var moves = [
            FileMove(
                file: .record,
                from: recordURL(for: record.id),
                to: ingestedRecordURL(for: record.id))
        ]
        if let payload = payloadURL(for: record) {
            moves.append(
                FileMove(file: .payload, from: payload, to: ingestedPayloadURL(for: record.id)))
        }
        return moves
    }

    /// Whether a file name written by another process may be appended to a
    /// directory URL at all: one plain component, nothing relative, no separator.
    /// The single authority every `named:` resolver asks, so they cannot drift.
    private static func isPlainComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    /// The payload a record refers to, or `nil` for a media-less record and for any
    /// record whose `payloadFile` is not the one name ``InboxWriter`` would have
    /// written for it.
    ///
    /// **A record may only name its own sidecar.** `payloadFile` crossed a process
    /// boundary, and a name that is merely a plain component can still be another
    /// capture's `<uuid>.json`, or `failed`, or `.staging`. Such a record used to pass
    /// ``isComplete(_:)`` and reach the pipeline as media — and then the drain, having
    /// resolved that name for reading, resolved it again for DELETING (on the success
    /// path) or for moving into `failed/` (on the failure path). One malformed record
    /// took a healthy neighbouring capture with it.
    ///
    /// So the test is not "could this name be appended to a directory" but "is this
    /// the exact name the writer produces for this id", asked through
    /// ``payloadFileName(for:)`` so the check and the writer cannot drift. Everything
    /// else is malformed, resolves to nothing here, and — since no amount of waiting
    /// makes a wrong name right — is a failure for S3 rather than a not-yet-complete
    /// write.
    public func payloadURL(for record: InboxRecord) -> URL? {
        guard let name = record.payloadFile else { return nil }
        guard name == InboxLayout.payloadFileName(for: record.id) else { return nil }
        return payloadURL(for: record.id)
    }

    // MARK: - The questions that need the disk

    /// Every committed record in the inbox, in file-name order, and nothing else.
    ///
    /// **That order carries no meaning.** A record's name is its UUIDv4, so sorting by
    /// it is a shuffle that happens to be stable — worth having so an enumeration is
    /// reproducible, worth nobody reading as chronological. The one ordering the inbox
    /// actually has is `InboxRecord.capturedAt`, which is inside the records and so
    /// cannot be applied here; 092 · S3's drain reads them and sorts by it.
    ///
    /// Touches the filesystem. The top level only, `*.json` only — which is what makes
    /// `.staging/` invisible and therefore what makes the two-phase write safe, and
    /// what keeps `failed/`, `sent/` and `ingested/` out too: all four are directories,
    /// and a directory has no `json` extension, so neither they nor anything under them
    /// can be returned. An absent inbox is an empty inbox, not an error: nothing has ever
    /// been shared.
    public func pendingRecordURLs() throws -> [URL] {
        try InboxLayout.recordURLs(in: directory)
    }

    /// Every record a retaining drain has already run, in file-name order.
    ///
    /// **A second name rather than a flag on the first.** ``pendingRecordURLs()`` is what
    /// the drain walks, and it must never see one of these: a record here has been through
    /// the coordinator, and handing it back would re-ingest the same capture on every pass
    /// for the life of the device. The one caller that wants both sets is the export, which
    /// needs them because "in the phone's library" and "delivered to the Mac" are different
    /// facts — so the union is composed there, deliberately, instead of being the default
    /// answer to a question the drain also asks.
    ///
    /// Touches the filesystem, with the same filter and the same tolerance for an absent
    /// directory: an inbox whose drain has never retained anything has no `ingested/`, and
    /// that is an empty answer rather than an error.
    public func ingestedRecordURLs() throws -> [URL] {
        try InboxLayout.recordURLs(in: ingested)
    }

    /// The one enumeration both public callers above are. Written once because they must
    /// agree on the filter down to `skipsHiddenFiles`: the properties that make `.staging/`
    /// invisible to a pending walk are the same properties that keep a half-moved file
    /// invisible to an ingested one, and two copies of them would eventually be two
    /// different filters.
    private static func recordURLs(in directory: URL) throws -> [URL] {
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
    ///
    /// A refused name is false, and the caller must not read that as "early": the drain
    /// checks the name itself before it gets here, precisely so the two answers do not
    /// look alike (see `payloadURL(for record:)`).
    public func isComplete(_ record: InboxRecord) -> Bool {
        guard record.payloadFile != nil else { return true }
        guard let url = payloadURL(for: record) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - The primitives every mover of inbox files shares (457)

    /// Move a file, clearing the destination first, and report whether it worked.
    ///
    /// Clearing rather than failing: every move in the inbox is of a capture into a
    /// directory that may already hold the same capture — a quarantine attempted twice,
    /// a second press of retire, a re-export of an id already in `sent/` — and the two
    /// files are the same capture by construction, so replacing is correct and refusing
    /// would wedge. Best-effort throughout: a move that fails leaves the source where it
    /// was, which for every caller is the recoverable direction (the capture is still
    /// pending, and the next pass or the next press tries again).
    ///
    /// The result is discardable because only some callers have a second move to decide
    /// about — `InboxDrain.retain` stops after a failed record move, since carrying on
    /// would manufacture the wedge ``retentionMoves(for:)`` describes — while quarantine's
    /// two moves are unconditional.
    @discardableResult
    public static func replacingMove(_ from: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: from, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// Delete a file, treating an absent one as done, and report whether it is gone.
    ///
    /// A media-less capture has no payload to reclaim and a second press has nothing
    /// left to delete; neither is a failure, and only a file that is there and will not
    /// go counts as one. Discardable for the callers whose deletion is a courtesy — a
    /// payload that survives is bytes nothing refers to, a leak and not a wedge.
    @discardableResult
    public static func removeIfPresent(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// A directory created at most once, and only when something is about to be put
    /// in it.
    ///
    /// Lazily, not up front, because the directory existing is itself a signal:
    /// `failed/` appearing tells a human something went wrong, `sent/` that something
    /// was retired, `ingested/` that this host retains — and a pass that did none of
    /// those must not leave an empty directory claiming it did. A Mac drains with
    /// `discardWhenIngested` forever and must never grow an `ingested/` describing a
    /// policy it does not have.
    ///
    /// Once, because a pass may put fifty files in the directory and `mkdir` fifty
    /// times is fifty syscalls for one fact. Best-effort, because every caller is
    /// already on a path where the moves that follow fail safely: if the create fails
    /// the moves fail, the capture stays where it was, and the next pass tries again.
    ///
    /// A value type with a `mutating` prepare rather than a reference, so the "once"
    /// is per pass — two passes over one inbox share nothing, which is what lets a
    /// caller drive cadence without asking anything to remember.
    public struct LazyDirectory: Sendable {
        /// The directory this creates.
        public let url: URL

        /// Whether `createDirectory` has already been attempted.
        public private(set) var isPrepared = false

        public init(_ url: URL) {
            self.url = url
        }

        /// Ensure ``url`` exists, once.
        public mutating func prepare() {
            guard !isPrepared else { return }
            isPrepared = true
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        }
    }
}
