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
// Foundation only. No AppKit, no UIKit, no GRDB use, and no knowledge of the Library
// beyond the inbox directory it was handed.

import Foundation

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
    /// `payload` is the media bytes, when there are any: a `Data` the extension
    /// already holds from the item provider, written straight through to a file and
    /// never base64-encoded. Media-less captures (`kind` = `tweet` / `link` / `color`)
    /// pass nil and get a record with no ``InboxRecord/payloadFile``.
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
        let fileManager = FileManager.default

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
                try payload.write(to: staged, options: .atomic)
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
