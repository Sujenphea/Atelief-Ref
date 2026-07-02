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
    /// marker that distinguishes a browser-image drag from a plain paste.
    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
