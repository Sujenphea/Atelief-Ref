// AtelierCapture — the extension's half of the handoff (092 · S2).
//
// One method: put a capture in the inbox and return. No database, no decode, no
// pipeline — a share extension runs on a much tighter memory budget than its host
// (an observed ~120 MB, not a contractual number), and the way it fails is a share
// sheet that silently does nothing (091 · D2).
//
// **Why the write is two-phase, and what breaks if it isn't.** The writer and the
// drain are separate processes with no lock between them. If a record were written
// in place, the drain could `contentsOfDirectory` between the record's creation and
// its last byte, or between the record and the payload it names, and would read a
// truncated JSON or a record pointing at a file that does not exist yet — and it
// would read those as *corrupt*, not as *early*. Quarantining a capture that was
// merely half a second young is a share the user watched succeed and will never see.
//
// So the write commits in an order that makes every intermediate state legible:
//
//   1. stage the payload in `.staging/`, then MOVE it to `<inbox>/<uuid>.bin`
//   2. stage the record in `.staging/`, then MOVE it to `<inbox>/<uuid>.json`
//
// A rename within a volume is atomic, so each file appears whole or not at all;
// `.staging/` is inside the inbox precisely to guarantee the same volume, and is
// invisible to the drain's top-level `*.json` enumeration. **The record is the commit
// marker.** No record ⇒ nothing to drain, whatever loose bytes are lying around. A
// record ⇒ its payload is already there, because it was moved first.
//
// The one state that ordering cannot rule out is the reverse of the failure mode that
// matters: a payload with no record (the process died between phases). That is a leak
// of bytes, not a corruption — the drain never sees it — and it is bounded by
// best-effort cleanup here. The state that IS ruled out is a record without its
// payload, which is the one the drain cannot tell apart from data loss. When it does
// see one anyway (a torn write on a crash), ``InboxLayout/isComplete(_:)`` says so,
// and S3 skips the item this pass rather than failing it.
//
// **Bytes reach `.staging/` two ways, and the write is otherwise one path** (406). A
// ``PayloadSource`` is either a `Data` a caller is already holding or a file on disk;
// the file case copies rather than loading, so the extension can hand over a 40 MB
// share without the 40 MB ever being resident in a process with a ~120 MB ceiling. That
// difference is one method, `stage(_:at:)`. Everything above and below it — the cap,
// the ordering, the record encode, the commit, the cleanup — is shared, because a
// two-phase discipline that held on one path and not the other would be worse than not
// having one.
//
// **And there is a cap**, ``InboxWriter/maximumPayloadBytes``, checked before a byte is
// copied. Refusing an absurd share is not tidiness: an extension jetsammed mid-write is
// a share sheet that silently did nothing, which is the one failure mode 091 · D2 says
// must not happen, because the user cannot tell it from success.
//
// Foundation only. No AppKit, no UIKit, no GRDB use, and no knowledge of the Library
// beyond the inbox directory it was handed.

import Foundation

/// Where a capture's bytes are, when the writer is handed them (406).
///
/// The whole point of the enum is that the second case never becomes the first. An
/// item provider hands a share extension either a `Data` — the entire image resident
/// in a process with an observed ~120 MB ceiling — or a temporary file, and the file
/// is what this package's own thesis asks for: `AtelierIngestion.ByteSource` chose
/// `.fileURL` over `.data` for exactly this reason at the other end of the pipe, and
/// the extension was the one place still contradicting it.
///
/// The case names deliberately mirror `ByteSource`'s. They are two types because the
/// packages are two link lines — `AtelierIngestion` imports AppKit and cannot build for
/// iOS at all — and a shared name across both would need qualifying in the Mac app that
/// imports each. What travels between them is the sidecar on disk, which a
/// ``fileURL(_:)`` write produces and a `ByteSource.fileURL` read consumes, so the
/// bytes are never in anybody's memory on either side.
public enum PayloadSource: Equatable, Sendable {
    /// Bytes already in memory. Correct, and still the fallback, for a provider that
    /// offers no file representation — but it is the shape that has to be capped after
    /// the fact, because by the time it exists it is already resident.
    case data(Data)
    /// A file on disk. The bytes reach `.staging/` by `copyItem`, which streams through
    /// the kernel (and clones outright on APFS), so no part of this process ever holds
    /// the image.
    case fileURL(URL)
}

/// Why a capture could not be put in the inbox.
///
/// Modelled on `LibraryLocationError` (092 · S1): a nested-in-the-feature enum,
/// `Equatable` so tests assert the exact case, each payload carrying the offending
/// value so the message says which path failed rather than that a path did.
///
/// Every case is a failed capture, and every case leaves the inbox drainable — the
/// writer either commits a record or leaves nothing a drain will act on.
///
/// **Every case also carries `underlying`, and that is not decoration.** The typed
/// case says WHICH step failed; `underlying` is the only thing that says why. This
/// code runs in a share extension: no debugger, no test host, one error card that
/// deliberately collapses all six typed failures into "that one didn't save"
/// (093 § 1), and a single `logger.error` line. Without the caught error's own words,
/// a full disk, a data-protection denial on a locked device and a missing App Group
/// container are one indistinguishable `payloadWriteFailed(path:)` — the same string
/// for three problems with three different fixes.
///
/// It is a `String` rather than a boxed `any Error` so the enum stays `Equatable`, and
/// it is rendered once by ``InboxWriteError/describing(_:)`` so the four sites cannot
/// each invent a format. Being a system-supplied message, it is a thing to READ and
/// never a thing to branch on or to assert equal — the tests pin the case and its
/// path, and only that this field is populated.
public enum InboxWriteError: Error, Equatable {
    /// The inbox (or its staging directory) could not be created — no App Group
    /// container, a read-only volume, or something non-directory already sitting at
    /// the path. Payload: the inbox directory, and what `FileManager` said.
    case inboxUnavailable(path: String, underlying: String)
    /// The payload bytes could not be staged or moved into place. Payload: the
    /// destination the bytes were headed for, and what the write or move said.
    case payloadWriteFailed(path: String, underlying: String)
    /// The record could not be turned into JSON — a `rawMetadata` value that is not
    /// representable, in practice. Payload: the record's id, since it has no path yet,
    /// and what the encoder said.
    case recordEncodingFailed(id: UUID, underlying: String)
    /// The record could not be staged or moved into place. Payload: the destination,
    /// and what the write or move said. The capture is lost, but nothing partial
    /// survives: the payload is cleaned up.
    case recordWriteFailed(path: String, underlying: String)
    /// The payload is larger than ``InboxWriter/maximumPayloadBytes`` and was refused
    /// before a byte of it was copied (406). Payload: the size measured and the limit
    /// it exceeded.
    ///
    /// **The one case with no `underlying`, and that is the point.** The other four
    /// carry a caught error because the typed case alone cannot say whether a disk was
    /// full or a container was missing. Nothing was caught here — the writer decided
    /// this, and `bytes` and `limit` say everything there is to say about why. A field
    /// holding a sentence this enum invented would be the opposite of what R1 added it
    /// for.
    case payloadTooLarge(bytes: Int, limit: Int)

    /// Render a caught error into the `underlying` text, the same way at all four
    /// sites.
    ///
    /// `localizedDescription` is the sentence a human reads ("The file couldn't be
    /// saved because the volume is out of space."); the bridged domain and code are
    /// what a search engine and `errno` understand (`NSCocoaErrorDomain 640`,
    /// `NSPOSIXErrorDomain 28`). The log line is read by whoever is holding the phone
    /// that failed, and they may need either, so it carries both. Every Swift error
    /// bridges, so a non-Cocoa error still yields a usable pair rather than nothing.
    static func describing(_ error: any Error) -> String {
        let bridged = error as NSError
        return "\(error.localizedDescription) [\(bridged.domain) \(bridged.code)]"
    }
}

/// Puts captures in the inbox for the host app to drain (092 · S2).
///
/// `Sendable` — it stores paths and nothing else, so it crosses concurrency domains
/// as freely as the `URL` inside it.
public struct InboxWriter: Sendable {
    /// The largest payload the inbox will accept, in bytes — **64 MiB** (406).
    ///
    /// **A tunable, not a contract**, and the single place it is spelled: the share
    /// extension asks this before it copies a provider's temporary file, and
    /// ``write(_:payload:id:capturedAt:)-(_,PayloadSource?,_,_)`` asks it again before
    /// it copies anything into `.staging/`, so an over-cap share is refused twice and
    /// duplicated nowhere.
    ///
    /// Why a cap exists at all: without one, a very large share gets the extension
    /// jetsammed mid-write and the user sees a share sheet that silently did nothing —
    /// 091 · D2's named failure, and the worst possible outcome because it is
    /// indistinguishable from success. A refusal is a card that says so.
    ///
    /// Why this number. It has to sit above every share a person actually takes and
    /// below the point where the in-memory fallback path threatens the extension's
    /// observed ~120 MB ceiling. A phone photo is 2–5 MB of HEIC, a full-screen PNG
    /// screenshot around 10 MB, a 48 MP ProRAW DNG roughly 25 MB, and a stitched
    /// panorama the largest thing Photos will hand over at some tens of MB. 64 MiB
    /// clears all of those with room to spare and is still barely half the ceiling, so
    /// even a `.data` payload at the limit cannot be what kills the process. It is one
    /// `static let` precisely so raising it is one edit once somebody hits it with a
    /// real share.
    public static let maximumPayloadBytes = 64 * 1024 * 1024

    /// How big a payload is, without reading it — `count` for bytes already in memory,
    /// a stat for a file. `nil` when the size cannot be determined.
    ///
    /// **`nil` is deliberately not a refusal.** A file whose size cannot be read is
    /// almost certainly a file that cannot be copied either, and the copy's own failure
    /// is the better-typed answer (``InboxWriteError/payloadWriteFailed(path:underlying:)``
    /// carries what the filesystem said). Refusing here would report a size problem for
    /// a file that has none.
    ///
    /// Public because the extension asks it of a provider's temporary file *before*
    /// copying, which is the only place the check can prevent work rather than merely
    /// undo it.
    public static func payloadSize(of payload: PayloadSource) -> Int? {
        switch payload {
        case .data(let data):
            return data.count
        case .fileURL(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
    }

    /// The inbox being written to.
    public let layout: InboxLayout

    public init(layout: InboxLayout) {
        self.layout = layout
    }

    /// The inbox under a Library root — the initializer the share extension uses,
    /// since it has a root from `LibraryLocation` and cannot link `LibraryLayout`.
    public init(libraryRoot: URL) {
        self.init(layout: InboxLayout(libraryRoot: libraryRoot))
    }

    /// Write one capture into the inbox and return the record that landed.
    ///
    /// `payload` is the media bytes, when there are any: a `Data` a caller already
    /// holds, written straight through to a file and never base64-encoded. Media-less
    /// captures (`kind` = `tweet` / `link` / `color`) pass nil and get a record with no
    /// ``InboxRecord/payloadFile``.
    ///
    /// A caller that has a FILE rather than a `Data` — the share extension, since 406 —
    /// should take the ``PayloadSource`` overload instead and never load the file to get
    /// here. This one exists unchanged because a provider offering no file
    /// representation still hands over bytes, and those bytes are still a valid capture.
    ///
    /// `id` and `capturedAt` are parameters with real defaults rather than being
    /// generated inside, so the failure matrix is exercisable and the caller can log
    /// the identity it is about to write.
    ///
    /// On success both files exist and `.staging/` is empty. On any throw nothing is
    /// left that the drain will pick up.
    @discardableResult
    public func write(
        _ request: CaptureRequest,
        payload: Data? = nil,
        id: UUID = UUID(),
        capturedAt: Date = Date()
    ) throws -> InboxRecord {
        try write(
            request, payload: payload.map(PayloadSource.data), id: id, capturedAt: capturedAt)
    }

    /// The same write, for a capture whose bytes are a FILE rather than a `Data` (406).
    ///
    /// This is the path the share extension takes: `NSItemProvider.loadFileRepresentation`
    /// yields a temporary file, and the bytes travel disk-to-disk into the sidecar
    /// without any process holding the image. `.data` remains correct — and remains the
    /// extension's fallback — for a provider that offers no file representation.
    ///
    /// **The two entry points differ in one line**, ``stage(_:at:)``, and nothing else.
    /// Everything that makes the write safe — the cap, the two phases, the ordering,
    /// the record encode, the commit, the cleanup on failure — is the same code for
    /// both, because an ordering that held on one path and not the other is precisely
    /// the bug the ordering exists to prevent.
    ///
    /// No default for `payload` here, unlike the `Data` overload: omitting the argument
    /// has to keep meaning exactly one thing, and "no payload" is already spelled by
    /// calling `write(request)`.
    @discardableResult
    public func write(
        _ request: CaptureRequest,
        payload: PayloadSource?,
        id: UUID = UUID(),
        capturedAt: Date = Date()
    ) throws -> InboxRecord {
        let fileManager = FileManager.default

        // Before anything is created. An over-cap share is a fact about what was
        // handed over, not about the container it was headed for, and refusing it
        // first means a doomed write never brings an inbox into existence.
        if let payload, let size = InboxWriter.payloadSize(of: payload),
           size > InboxWriter.maximumPayloadBytes {
            throw InboxWriteError.payloadTooLarge(
                bytes: size, limit: InboxWriter.maximumPayloadBytes)
        }

        do {
            try fileManager.createDirectory(
                at: layout.directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: layout.staging, withIntermediateDirectories: true)
        } catch {
            throw InboxWriteError.inboxUnavailable(
                path: layout.directory.path,
                underlying: InboxWriteError.describing(error))
        }

        // Phase 1 — the payload, committed BEFORE the record that names it.
        var payloadFile: String?
        if let payload {
            let staged = layout.stagedPayloadURL(for: id)
            let destination = layout.payloadURL(for: id)
            do {
                try stage(payload, at: staged)
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw InboxWriteError.payloadWriteFailed(
                    path: destination.path,
                    underlying: InboxWriteError.describing(error))
            }
            payloadFile = InboxLayout.payloadFileName(for: id)
        }

        let record = InboxRecord(
            id: id,
            capturedAt: capturedAt,
            request: strippingInlineImage(from: request, wroteBytes: payload != nil),
            payloadFile: payloadFile,
            attempts: 0)

        // Phase 2 — the record, which is the commit marker. Anything that fails from
        // here on takes the payload back down with it, so the inbox is never left
        // holding bytes that will never be claimed.
        do {
            try commitRecord(record, replacingExisting: false)
        } catch {
            discardPayload(for: record)
            throw error
        }

        return record
    }

    /// Re-commit a record that is ALREADY in the inbox, replacing it in place —
    /// the drain stamping ``InboxRecord/attempts`` after a transient failure
    /// (092 · S3).
    ///
    /// It exists so the drain does not grow a second, subtly different writer. A
    /// record rewritten in place is exactly the torn-write hazard the two phases
    /// above were built for: a drain that crashed between `open` and the last byte
    /// of a re-encoded record would leave truncated JSON where a valid capture had
    /// been, turning a retryable failure into a lost share. So this stages and moves
    /// like everything else here, and the payload is not touched — the capture is
    /// still perfectly good, it is only the counter beside it that changed.
    public func rewrite(_ record: InboxRecord) throws {
        try commitRecord(record, replacingExisting: true)
    }

    /// Get a payload's bytes into `.staging/` — **the only thing the two write entry
    /// points do differently** (406).
    ///
    /// `.data` writes what it is holding. `.fileURL` copies, and copying is the whole
    /// reason the case exists: `copyItem` moves bytes through the kernel a buffer at a
    /// time (and on APFS within a volume, clones the extent map instead of moving
    /// anything at all), so a 40 MB share costs this process no more memory than a 40 KB
    /// one. Loading the file into a `Data` here would have made the file case an
    /// elaborate way to arrive at the problem it was added to avoid.
    ///
    /// Deliberately a copy and never a move: the URL a provider hands over may be the
    /// user's own asset rather than a scratch file, and a mover would be reaching into
    /// another process's storage. The extra copy is on disk and is nobody's memory.
    private func stage(_ payload: PayloadSource, at staged: URL) throws {
        switch payload {
        case .data(let data):
            try data.write(to: staged, options: .atomic)
        case .fileURL(let url):
            try FileManager.default.copyItem(at: url, to: staged)
        }
    }

    /// Encode a record, stage it, and move it into place — phase 2, shared by the
    /// first write and by a rewrite so the two cannot diverge.
    ///
    /// `replacingExisting` picks the commit call rather than the discipline: a fresh
    /// write moves onto empty space, while a rewrite has a file sitting at the
    /// destination by definition and `moveItem` refuses that, so it goes through
    /// `replaceItemAt`. Both are a rename within one volume; neither can leave a
    /// half-written record where a whole one was.
    private func commitRecord(_ record: InboxRecord, replacingExisting: Bool) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: layout.staging, withIntermediateDirectories: true)
        } catch {
            throw InboxWriteError.inboxUnavailable(
                path: layout.directory.path,
                underlying: InboxWriteError.describing(error))
        }

        let encoded: Data
        do {
            encoded = try InboxRecord.makeEncoder().encode(record)
        } catch {
            throw InboxWriteError.recordEncodingFailed(
                id: record.id, underlying: InboxWriteError.describing(error))
        }

        let staged = layout.stagedRecordURL(for: record.id)
        let destination = layout.recordURL(for: record.id)
        do {
            try encoded.write(to: staged, options: .atomic)
            if replacingExisting {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw InboxWriteError.recordWriteFailed(
                path: destination.path, underlying: InboxWriteError.describing(error))
        }
    }

    /// Drop the base64 `image` when the same bytes just went to a file.
    ///
    /// Carrying both would defeat the point of the sidecar — a record twice the size
    /// of the capture, and a base64 string of an image held in memory by whichever
    /// process parses it (092 · S2 · the note on `CaptureRequest.image`). A request
    /// that carries `image` and NO bytes is left alone: it is still a valid capture the
    /// existing decode funnel understands, and silently dropping it would lose the
    /// share rather than shrink it.
    private func strippingInlineImage(
        from request: CaptureRequest, wroteBytes: Bool
    ) -> CaptureRequest {
        guard wroteBytes, request.image != nil else { return request }
        var stripped = request
        stripped.image = nil
        return stripped
    }

    /// Best-effort removal of a committed payload whose record never landed. Failing
    /// to clean up leaks bytes; it cannot produce a record the drain will misread, so
    /// it is deliberately not an error of its own.
    private func discardPayload(for record: InboxRecord) {
        guard let url = layout.payloadURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
