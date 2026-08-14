// AtelierCapture — what the share extension leaves behind (092 · S2).
//
// The share extension does the smallest durable thing and returns (091 · D2): it
// writes one of these plus, when there are bytes, a sidecar file — and never opens
// SQLite, never decodes an image, never runs the pipeline. `InboxRecord` is that
// durable thing.
//
// It WRAPS the capture contract rather than restating it. `request` is the same
// `CaptureRequest` the Chrome extension POSTs to the loopback endpoint, so the drain
// maps it through the same `CaptureDecoder` funnel and provenance cannot diverge
// between the two producers — which matters because 18A dedup keys on provenance,
// and the way a drift there presents is a second asset quietly forking off the same
// bytes, not a crash.
//
// The three fields that are NOT in `CaptureRequest` are the three things a file in a
// directory needs and a request over a socket does not: an identity that names its
// sidecar, the moment of capture (stamped in the extension — the drain may run hours
// later, on next foreground, and the user's sense of "when" is when they hit share),
// and an attempt counter.
//
// **`attempts` is here from the start, not added by S3.** This is an on-disk format
// written by a possibly-older shipped extension and read by a newer host; a field
// added later means tolerating records that predate it forever. Cheaper to define it
// now, default it to 0, and let the drain be the only thing that increments it. The
// decode tolerates its absence anyway — one line, and the format is already on disk.
//
// **`request.image` — the base64 field — is nil on this path.** Bytes go to the
// `.bin` sidecar and are handed to the pipeline as a file URL, so neither process
// ever holds a base64 string of an image in memory; that is the whole reason the
// extension survives a 4000px share. The field stays on `CaptureRequest` for the HTTP
// producer, which is bounded by the server's body cap and has no file to write to.

import Foundation

/// One capture waiting in the inbox (092 · S2).
///
/// `Codable` because it IS the file; `Sendable` because it crosses from the writing
/// process to the draining one; `Equatable` so a round-trip is assertable.
public struct InboxRecord: Codable, Equatable, Sendable {
    /// This capture's identity, and the stem of both its file names.
    public var id: UUID

    /// When the user shared — stamped in the extension, not at drain time. The drain
    /// may run much later, and this is the timestamp the asset should carry.
    public var capturedAt: Date

    /// The capture itself, in the one wire shape both producers speak. `image` is nil
    /// on this path; the bytes are in ``payloadFile``.
    public var request: CaptureRequest

    /// `"<uuid>.bin"` when bytes were written, nil for a media-less capture
    /// (`kind` = `tweet` / `link` / `color`). A name rather than a path: the inbox may
    /// be reached through different container URLs in different processes, so the
    /// record must not contain an absolute one.
    public var payloadFile: String?

    /// How many times the drain has picked this up. 0 at write; 092 · S3 increments it
    /// and quarantines after 3, because retry-forever is the failure mode a durable
    /// inbox invites.
    public var attempts: Int

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        request: CaptureRequest,
        payloadFile: String? = nil,
        attempts: Int = 0
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.request = request
        self.payloadFile = payloadFile
        self.attempts = attempts
    }

    // MARK: - Codable

    /// Declared rather than synthesized, because the custom decode below needs them.
    /// The names are the on-disk keys — renaming one breaks every record already
    /// sitting in an inbox.
    enum CodingKeys: String, CodingKey {
        case id, capturedAt, request, payloadFile, attempts
    }

    /// Decode, tolerating a missing `attempts`.
    ///
    /// Belt and braces: `attempts` ships in S2 precisely so no record can predate it,
    /// but this is a format on disk read across app versions, and the cost of being
    /// forgiving about a counter whose absence unambiguously means zero is one line.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        request = try container.decode(CaptureRequest.self, forKey: .request)
        payloadFile = try container.decodeIfPresent(String.self, forKey: .payloadFile)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }

    /// The encoder the inbox format is defined by — pinned, not defaulted.
    ///
    /// The date strategy is explicit because `.deferredToDate` means "seconds since
    /// the *reference* date", a Foundation implementation detail that would be a
    /// terrible thing to have baked into a file two separately-shipped binaries read.
    /// Sorted keys make a record's bytes a function of its values, which is what lets
    /// tests compare files rather than parses.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The matching decoder. Any reader of the inbox must use this one.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
