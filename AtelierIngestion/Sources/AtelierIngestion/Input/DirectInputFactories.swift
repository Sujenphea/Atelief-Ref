// AtelierIngestion — the provenance factories, without AppKit (chunk 5, split by
// `.change-log/452`)
//
// One half of what used to be `DirectInputReader.swift`. That file reads
// `NSPasteboard`s and `NSItemProvider`s, so it imports AppKit and cannot exist in
// an iOS process; the factories it fed — the pure functions that turn bytes or a
// URL plus a caller `Date` into an ``IngestInput`` with the right provenance —
// have never needed AppKit for anything. They are here, and they build everywhere.
//
// **Why the file was split rather than excluded.** Guarding the old file whole was
// the obvious move and it does not work: ``InboxDrain`` maps every drained record
// through `DirectInputReader.remote*`, and ``RemoteImageFetcher`` calls
// `browserImageInput` and `isWebURL` — so a single `#if` around the AppKit import
// takes the phone's own inbox drain with it. CI's `ios-packages` job recorded that
// as the reason this package stayed host-only. The objection was correct about the
// file and wrong about the type: the AppKit dependency was never in the factories,
// only in the two readers that call them, and a file boundary drawn where the
// framework boundary already ran costs nothing to draw.
//
// Both halves extend the same ``DirectInputReader`` namespace, so no caller moved
// and no name changed — `DirectInputReader.fileInput(…)` resolves here on macOS
// exactly as it did when the two halves shared a file.
//
// Design for testability (unchanged, and the reason the boundary was easy to find):
// these factories take the bytes/URL and a caller `Date`, never touch global AppKit
// state, and never call `Date()` — so a test asserts on the resulting
// `IngestInput.provenance` deterministically.

import Foundation

import AtelierCore

/// Stateless adapters from captured content to ``IngestInput``s (chunk 5). A
/// namespace — every member is `static`.
///
/// The type is DECLARED here, in the half that builds on every platform, and
/// EXTENDED in `DirectInputReader.swift` with the pasteboard and drag readers that
/// only exist on macOS. That order is the load-bearing part: declaring it in the
/// AppKit half would take the namespace — and with it the whole remote/inbox
/// family — out of an iOS build along with the readers.
public enum DirectInputReader {

    // MARK: - Provenance factories (pure, unit-testable without AppKit state)

    /// A pasted image → `.localPaste`. When the clipboard also carried a URL
    /// (`sourceURL`), it is captured as the source's `originalURL` — otherwise
    /// the paste has no origin URL (dedup then matches on platform + blob hash).
    public static func pasteInput(
        imageData: Data, sourceURL: URL?, into collectionID: UUID, at: Date
    ) -> IngestInput {
        IngestInput(
            source: .data(imageData),
            provenance: SourceDraft(
                platform: .localPaste,
                originalURL: sourceURL?.absoluteString,
                capturedAt: at),
            collectionID: collectionID)
    }

    /// The app name recorded when the frontmost application cannot be resolved
    /// (013 · K3). Provenance for an ambient capture is never null: a row that
    /// says "Clipboard" is honest about knowing only that much, whereas an empty
    /// author field reads as a bug.
    public static let clipboardFallbackAppName = "Clipboard"

    /// An image the AMBIENT CLIPBOARD WATCHER noticed → `.clipboard` (013 · K3).
    ///
    /// Same bytes-in shape as ``pasteInput(imageData:sourceURL:into:at:)``, and
    /// deliberately the same family of pure factories, so ambient capture is the
    /// existing paste path with a different provenance stamp rather than a second
    /// ingest pipeline. No `originalURL`: an image copied out of a Preview window
    /// has no canonical URL, and `Validation.originalURL` exempts `.clipboard` for
    /// exactly that reason.
    ///
    /// `appName` / `appBundleID` are the frontmost application at the moment the
    /// watcher NOTICED the copy, which is up to one poll interval after the copy
    /// itself — so this is **best-effort provenance that races a fast app switch**:
    /// copy in Safari, ⌘-tab to Mail within the same tick, and the capture is
    /// attributed to Mail. It is recorded as the app the copy most likely came
    /// from, not as a fact about it. Both are normalized HERE (one place, so a
    /// blank or whitespace-only name can't reach the database): the localized name
    /// becomes `authorName`, falling back to ``clipboardFallbackAppName``, and the
    /// bundle id becomes `authorHandle` — the app world's stable machine
    /// identifier beside its display name, which is what the handle field is for
    /// and what the detail sidebar already renders as "Preview (com.apple.Preview)".
    ///
    /// The WATCHER that supplies those two strings is macOS-only (it polls
    /// `NSPasteboard.general`), but the factory is not: it is a pure stamp over two
    /// optional strings, and keeping it beside its siblings is what stops the
    /// provenance family from being split across a framework line it doesn't have.
    public static func clipboardInput(
        imageData: Data, appName: String?, appBundleID: String?,
        into collectionID: UUID, at: Date
    ) -> IngestInput {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return IngestInput(
            source: .data(imageData),
            provenance: SourceDraft(
                platform: .clipboard,
                originalURL: nil,
                authorHandle: bundleID.isEmpty ? nil : bundleID,
                authorName: name.isEmpty ? clipboardFallbackAppName : name,
                capturedAt: at),
            collectionID: collectionID)
    }

    /// A pasted / dragged FILE → `.localDrag`. The file's on-disk path is
    /// preserved verbatim in `raw_metadata.original_path` (provenance), while the
    /// bytes are read from the URL at ingest time (``ByteSource/fileURL(_:)``).
    public static func fileInput(
        fileURL: URL, into collectionID: UUID, at: Date
    ) -> IngestInput {
        IngestInput(
            source: .fileURL(fileURL),
            provenance: SourceDraft(
                platform: .localDrag,
                originalURL: nil,
                capturedAt: at,
                rawMetadata: .object(["original_path": .string(fileURL.path)])),
            collectionID: collectionID)
    }

    /// A dragged BROWSER image (it carries the page it came from) → `.web`, with
    /// that page URL as the source's `originalURL` — the canonical link back to
    /// the post (003 §data-model · Source.originalURL).
    ///
    /// Also the landing point for a downloaded bare image URL
    /// (``RemoteImageFetcher``), which is why this one has to build off the Mac:
    /// the drag that names it is macOS-only, the provenance shape is not.
    public static func browserImageInput(
        imageData: Data, pageURL: URL, into collectionID: UUID, at: Date
    ) -> IngestInput {
        IngestInput(
            source: .data(imageData),
            provenance: SourceDraft(
                platform: .web,
                originalURL: pageURL.absoluteString,
                capturedAt: at),
            collectionID: collectionID)
    }

    /// A REMOTE capture (the Chrome extension) → an ``IngestInput`` from bytes the
    /// caller already fetched plus a fully-populated ``SourceDraft``.
    ///
    /// Unlike the three local factories above, the provenance is built by the
    /// caller (the localhost endpoint, from the extension's JSON) rather than
    /// derived here — the extension's whole value is rich per-site provenance
    /// (platform, author, title, `raw_metadata`), so this factory stays a thin,
    /// DRY wrapper over the same ``IngestInput`` shape the pipeline already
    /// ingests. The app never downloads: the bytes ride in with the request
    /// (007 §scope — the app stays off the network).
    public static func remoteInput(
        imageData: Data, provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        IngestInput(
            source: .data(imageData),
            provenance: provenance,
            collectionID: collectionID)
    }

    /// A REMOTE VIDEO capture (the Chrome extension). Same rich caller-supplied
    /// provenance as ``remoteInput(imageData:provenance:into:)``, but the bytes
    /// are a whole video file — far too large to carry in memory as base64/JSON —
    /// so the localhost endpoint STREAMS them to a temp file and hands us its URL,
    /// read at ingest time via ``ByteSource/fileURL(_:)`` (the same disk-backed
    /// path a dragged file uses). The pipeline already classifies `.movie` bytes
    /// as a `.video` asset, so no other change is needed downstream.
    public static func remoteVideo(
        fileURL: URL, provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        remoteFile(fileURL: fileURL, provenance: provenance, into: collectionID)
    }

    /// A REMOTE capture whose bytes are ALREADY A FILE — the inbox drain
    /// (092 · S3), and, under its older name, the streamed video upload above.
    ///
    /// The distinction the two names draw is media type, and media type is not what
    /// this factory decides: the pipeline sniffs the bytes and classifies the asset
    /// itself. What it decides is that the bytes stay on disk. The share extension
    /// wrote them to a `.bin` sidecar precisely so no process would hold them in
    /// memory; reading them into a `Data` here to build a `.data` source would undo
    /// that at the last step, for a pipeline that is only going to write them back
    /// out to a blob.
    public static func remoteFile(
        fileURL: URL, provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        IngestInput(
            source: .fileURL(fileURL),
            provenance: provenance,
            collectionID: collectionID)
    }

    /// A REMOTE MEDIA-LESS capture (003 · C3): a `tweet` / `link` / `color`
    /// content draft the extension extracted, with the same rich caller-supplied
    /// provenance as ``remoteInput(imageData:provenance:into:)``. No bytes ride
    /// in — the substance is the draft's ``AssetContentDraft/payload`` — so the
    /// pipeline routes it to `ingestContent` instead of the blob path, while it
    /// still flows through the same coordinator (ledger / live-refresh unchanged).
    public static func remoteContent(
        draft: AssetContentDraft, provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        IngestInput(
            content: draft,
            provenance: provenance,
            collectionID: collectionID)
    }

    /// A REMOTE MEDIA-LESS capture that ALSO carries a card image (003 · C3,
    /// Option 3): a `tweet` whose picture the extension fetched. The draft keeps
    /// the content identity while the bytes become the asset's card-image blob —
    /// the pipeline runs the blob-first stages for the image and persists via
    /// `ingestContent(_:blob:)`. Same coordinator, ledger, and live-refresh.
    public static func remoteContentWithImage(
        draft: AssetContentDraft, imageData: Data,
        provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        IngestInput(
            content: draft,
            image: .data(imageData),
            provenance: provenance,
            collectionID: collectionID)
    }

    /// The same hybrid content-plus-card-image shape as
    /// ``remoteContentWithImage(draft:imageData:provenance:into:)``, but with the
    /// card image ALREADY A FILE — a tweet shared from the phone, whose picture the
    /// share extension wrote to the inbox sidecar (092 · S3).
    ///
    /// Separate from its sibling rather than sharing it, because the difference is
    /// the whole point: the two factories differ only in which ``ByteSource`` they
    /// hand over, and that choice is the one thing the inbox path must not get
    /// wrong.
    public static func remoteContentWithFile(
        draft: AssetContentDraft, fileURL: URL,
        provenance: SourceDraft, into collectionID: UUID
    ) -> IngestInput {
        IngestInput(
            content: draft,
            image: .fileURL(fileURL),
            provenance: provenance,
            collectionID: collectionID)
    }

    // MARK: - URL shape

    /// Whether `url` looks like a web PAGE (an `http`/`https` scheme) — the
    /// marker that distinguishes a browser image (paste OR drag) from a plain
    /// paste/file. Public so the app's drop handler shares one definition of
    /// "web URL" with the pasteboard path (they must agree).
    ///
    /// It reads a `URL`'s scheme and nothing else, so it sits with the factories
    /// rather than with the pasteboard readers that were its first caller —
    /// ``RemoteImageFetcher`` gates on it before making any request, and that
    /// gate has to hold in a process with no pasteboard.
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
