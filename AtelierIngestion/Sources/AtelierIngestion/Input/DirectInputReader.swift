// AtelierIngestion — direct-input adapters (chunk 5)
//
// Turns pasteboard / drag content into `IngestInput`s with the correct
// provenance (003 §ingestion · Path 1, LOCAL paths only). Three local paths:
//   • paste an image        → `.localPaste`  (capture a clipboard URL if any)
//   • paste / drag a file    → `.localDrag`   (original path in `raw_metadata`)
//   • drag a browser image   → `.web`         (its source PAGE URL as originalURL)
//
// The NETWORK "paste a bare URL → resolve media" path is deferred (007 §scope).
//
// Design for testability:
//   • The provenance FACTORIES are pure — they take the bytes/URL + a caller
//     `Date`, never touch global AppKit state, and never call `Date()`, so a test
//     asserts on the resulting `IngestInput.provenance` deterministically.
//   • `inputs(from:)` takes a NAMED `NSPasteboard`, so a test creates its own
//     `NSPasteboard(name:)`, writes items, and reads them back — never the
//     shared general pasteboard, never any GUI.

import AppKit
import UniformTypeIdentifiers

import AtelierCore

/// Stateless adapters from pasteboard / drag content to ``IngestInput``s
/// (chunk 5). A namespace — every member is `static`.
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

    // MARK: - Pasteboard interpretation

    /// The image data types we recognize on a pasteboard, in preference order.
    /// `public.jpeg` has no `NSPasteboard.PasteboardType` constant, so it is
    /// spelled from its UTI.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),  // "public.jpeg"
    ]

    /// Inspect `pasteboard` and pick the single best interpretation of its
    /// contents, producing zero or more ``IngestInput``s for `collectionID`.
    ///
    /// The decision order (007 §scope · the three LOCAL paths):
    ///   1. **File URL(s) present** → each file → one `.localDrag` input, reading
    ///      the real bytes from disk at ingest. This is preferred over any inline
    ///      image on the SAME pasteboard: when you copy an image *file* (Finder,
    ///      most apps), the clipboard carries BOTH the file URL (the full-
    ///      resolution asset) AND a small inline image that is only an icon /
    ///      QuickLook *preview* — reading the file avoids ingesting the preview.
    ///   2. **Inline image data** (`.png` / `.tiff` / `public.jpeg`) and NO file
    ///      URL → a genuine bitmap copy (Preview, a browser's "Copy Image", …).
    ///      A WEB page URL alongside it marks a browser image → one `.web` input
    ///      carrying that page URL; otherwise a paste-image → one `.localPaste`
    ///      input, attaching any (non-web) URL the clipboard also carried.
    ///   3. Otherwise (empty / unsupported) → `[]`.
    public static func inputs(
        from pasteboard: NSPasteboard, into collectionID: UUID, now: Date
    ) -> [IngestInput] {
        let urls = self.urls(on: pasteboard)

        // 1. A FILE url is the real asset — prefer it. An inline image rep that
        //    accompanies a file URL is typically just an icon / QuickLook
        //    preview (e.g. copying an image file in Finder), NOT the full-
        //    resolution bytes, so reading the file is what actually captures it.
        let fileURLs = urls.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            return fileURLs.map {
                fileInput(fileURL: $0, into: collectionID, at: now)
            }
        }

        // 2. No file URL — an inline image is a genuine bitmap copy. A WEB page
        //    URL alongside it disambiguates a browser image from a plain paste.
        if let imageData = firstImageData(on: pasteboard) {
            if let pageURL = urls.first(where: isWebURL) {
                return [browserImageInput(
                    imageData: imageData, pageURL: pageURL,
                    into: collectionID, at: now)]
            }
            return [pasteInput(
                imageData: imageData, sourceURL: urls.first,
                into: collectionID, at: now)]
        }

        // 3. Nothing we can ingest.
        return []
    }

    // MARK: - Pasteboard readers

    /// The first recognized image representation on `pasteboard`, if any.
    private static func firstImageData(on pasteboard: NSPasteboard) -> Data? {
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// Every URL carried by `pasteboard` — file OR web. Reads the typed `NSURL`
    /// objects first, then falls back to a raw `public.url` string so a URL that
    /// wasn't surfaced as an object is still seen.
    private static func urls(on pasteboard: NSPasteboard) -> [URL] {
        var result: [URL] = []
        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] {
            result.append(contentsOf: objects)
        }
        if let string = pasteboard.string(forType: .URL),
           let url = URL(string: string),
           !result.contains(url) {
            result.append(url)
        }
        return result
    }

    /// Whether `url` looks like a web PAGE (an `http`/`https` scheme) — the
    /// marker that distinguishes a browser image (paste OR drag) from a plain
    /// paste/file. Public so the app's drop handler shares one definition of
    /// "web URL" with the pasteboard path (they must agree).
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Drag provider interpretation

    /// The decoded result of a drag drop's `NSItemProvider`s.
    public struct DroppedProviders {
        /// The ingestable inputs, in provider order.
        public let inputs: [IngestInput]
        /// A page/web URL to fall back on when no bytes decoded (a bare-link or
        /// downloadable-image drag) — the drop handler downloads/resolves it.
        public let webURL: URL?
        /// How many providers yielded nothing recognizable (not a file, image, or
        /// web URL) — drives the "N imported, M couldn't be read" partial-drop
        /// feedback. A pure web-URL carrier is NOT counted (it feeds `webURL`).
        public let undecodedCount: Int
    }

    /// Decode a drag drop's providers into ``IngestInput``s, mirroring the
    /// pasteboard decision order (``inputs(from:into:now:)``) for the drag path:
    /// a file URL → `.localDrag`; inline image bytes → `.web` when a page URL rode
    /// along, else `.localPaste`. A provider that is only a web URL contributes the
    /// fall-back ``DroppedProviders/webURL`` rather than an input. Anything else is
    /// counted in ``DroppedProviders/undecodedCount`` so a partial drop is reported
    /// instead of silently dropping items.
    ///
    /// The page URL is resolved ONCE up front (the first web URL across all
    /// providers) and threaded into every image provider, so a browser image drag —
    /// whose provider carries BOTH the bitmap and its page URL — lands as `.web`
    /// with that page as provenance.
    /// `sending` because `NSItemProvider` is not `Sendable` and this hop leaves the
    /// caller's isolation domain to decode off-main. The drop handler is handed the
    /// array by SwiftUI and never touches it again, so TRANSFERRING ownership states
    /// what already happens — the alternative is decoding on the main actor, which
    /// is the one thing this path exists to avoid.
    public static func inputs(
        from providers: sending [NSItemProvider], into collectionID: UUID, now: Date
    ) async -> DroppedProviders {
        let webURL = await firstWebURL(in: providers)
        var inputs: [IngestInput] = []
        var undecoded = 0
        for provider in providers {
            if let input = await input(
                from: provider, pageURL: webURL, into: collectionID, at: now) {
                inputs.append(input)
            } else if isWebURLCarrier(provider) {
                // The page-URL carrier for the drag — folded into `webURL`, not a
                // failure. (A browser image is decoded above before reaching here.)
                continue
            } else {
                undecoded += 1
            }
        }
        return DroppedProviders(inputs: inputs, webURL: webURL, undecodedCount: undecoded)
    }

    /// Decode a SINGLE provider: a file URL → `.localDrag`; inline image bytes →
    /// `.web` (when `pageURL` is present) else `.localPaste`. `nil` when the
    /// provider is neither a loadable file nor a loadable image (e.g. a bare web
    /// URL, handled by the caller as the `webURL` fallback).
    private static func input(
        from provider: NSItemProvider, pageURL: URL?, into collectionID: UUID, at now: Date
    ) async -> IngestInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.isFileURL {
            return fileInput(fileURL: url, into: collectionID, at: now)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: UTType.image.identifier), !data.isEmpty {
            if let pageURL {
                return browserImageInput(
                    imageData: data, pageURL: pageURL, into: collectionID, at: now)
            }
            return pasteInput(
                imageData: data, sourceURL: nil, into: collectionID, at: now)
        }
        return nil
    }

    /// The first http(s) URL carried by a NON-file provider — the page a browser
    /// image/link drag came from. Skips file-URL providers (a dragged file's path
    /// isn't a page).
    private static func firstWebURL(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers where isWebURLCarrier(provider) {
            if let url = await loadURL(provider), isWebURL(url) {
                return url
            }
        }
        return nil
    }

    /// Whether `provider` can carry a (non-file) URL — the shape a bare web-URL or
    /// browser-image drag has. Used both to find the page URL and to decide that a
    /// non-decoding provider was "just a URL", not an unreadable item.
    private static func isWebURLCarrier(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
