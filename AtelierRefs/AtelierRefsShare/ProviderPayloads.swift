// AtelierRefsShare — pulling bytes and URLs out of `NSItemProvider` (092 · S4b-ii, 406).
//
// **The one part of a share that genuinely needs a process.** An `NSItemProvider` is
// asynchronous, Cocoa, and hands its results back on whatever thread it likes; nothing
// about it can be a pure function, so this is the residue the package split
// (`AtelierCapture.ShareCapture`) deliberately left behind. It reads — it decides nothing.
// The one predicate that looks like a decision, "is this identifier an image", is asked by
// `UTType` conformance and is here only because `UTType` needs UIKit.
//
// **A file first, always** (406). `loadDataRepresentation` returns the WHOLE image as a
// `Data`, and that `Data` then travels through `ShareCaptureDraft` into `InboxWriter` —
// peak footprint one entire file, resident, in a process with an observed ~120 MB ceiling.
// `loadFileRepresentation` hands over a temporary file instead, which is copied
// disk-to-disk into the sidecar and never loaded here. This is the same argument
// `AtelierIngestion.ByteSource` makes at the far end of the pipe (092 · S3 prefers
// `.fileURL` over `.data` for exactly this reason).
//
// **The `Data` path is the fallback and not a leftover.** Not every provider vends a file
// representation, and a share that would otherwise be lost is worth the memory. It is
// capped too — by `InboxWriter`, since by the time a `Data` exists the bytes are already
// resident and nothing here can un-load them.
//
// Split out of `ShareViewController` in 098 · P5 (finding 7). ``adopt(_:)`` stays with the
// provider loading that needs it most and is borrowed by ``MediaFetcher``, whose downloaded
// file is this process's to own for exactly the same reason.

import AtelierCapture
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Reading an `NSItemProvider`, and owning the files that come out of one.
nonisolated enum ProviderPayloads {

    // MARK: - Images

    /// The provider's registered identifier that is an image, or nil.
    ///
    /// Asked by conformance rather than by name: a share registers `public.jpeg` or
    /// `public.heic`, not `public.image`, and loading by the concrete identifier is
    /// what gets the ORIGINAL bytes back instead of a re-encode.
    static func imageIdentifier(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    /// Where the provider's image bytes are, preferring a file over memory (406).
    ///
    /// Throws only ``InboxWriteError/payloadTooLarge(bytes:limit:)``, from ``adopt(_:)``.
    static func loadImage(
        from provider: NSItemProvider, identifier: String
    ) async throws -> PayloadSource? {
        if let file = try await loadFile(from: provider, identifier: identifier) {
            return .fileURL(file)
        }
        ShareLog.share.info("no file representation for \(identifier, privacy: .public)")
        if let data = await loadData(from: provider, identifier: identifier) {
            return .data(data)
        }
        return nil
    }

    /// The provider's file for `identifier`, copied somewhere it will still exist.
    ///
    /// **The URL is dead the moment this completion handler returns**, which is the one
    /// thing about `loadFileRepresentation` that has to be got right: the system
    /// deletes the temporary file as soon as the callback finishes, so a handler that
    /// resumes a continuation with the URL and copies it later works perfectly on a
    /// small file and races on a large one — the exact bug 406 fixed, hidden behind a
    /// passing test. So ``adopt(_:)`` runs INSIDE the handler, synchronously, and the
    /// continuation is resumed with a URL this process owns and nothing else can delete.
    private static func loadFile(
        from provider: NSItemProvider, identifier: String
    ) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(
                forTypeIdentifier: identifier
            ) { url, error in
                guard let url else {
                    if let error {
                        ShareLog.share.info(
                            "no file representation: \(String(describing: error), privacy: .public)")
                    }
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    continuation.resume(returning: try adopt(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The provider's bytes for `identifier`, without decoding them.
    ///
    /// `loadDataRepresentation`, not `loadItem` — the latter cheerfully hands back a
    /// `UIImage`, which is a decoded bitmap this process must never hold (092 · S2).
    /// The fallback only: see ``loadImage(from:identifier:)``.
    ///
    /// **Its error is logged, and that is 098 · finding 7's one silent path.** This handler
    /// was `{ data, _ in }` — the LAST route to an image's bytes, discarding the only
    /// account of why it produced none. What the user then sees is `harvest` resolving to a
    /// link (or to nothing) with no line anywhere saying the photo's bytes were asked for
    /// and refused. That is the exact shape `ShareViewController` states as its own rule
    /// for the path with no error to carry: the vocabulary lands in the log or nowhere.
    private static func loadData(
        from provider: NSItemProvider, identifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if data == nil {
                    ShareLog.share.error(
                        """
                        no data representation for \(identifier, privacy: .public): \
                        \(error.map { String(describing: $0) } ?? "no error given", privacy: .public)
                        """)
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - URLs

    /// The provider's URL as a string, whatever kind of URL it is.
    ///
    /// **The http(s) filter used to be here and is now `ShareCapture.webURLString`**
    /// (406, issue 11) — it is a predicate over a string, so it belongs where it can be
    /// tested. The reason for it is unchanged: `public.file-url` CONFORMS to
    /// `public.url`, so an image shared out of Files arrives with a `file://`
    /// attachment, and storing that as `originalURL` would put a path from a container
    /// that no longer exists into a capture's provenance.
    static func loadURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier, options: nil
            ) { item, _ in
                continuation.resume(returning: (item as? URL)?.absoluteString)
            }
        }
    }

    // MARK: - The copies this process owns

    /// Take a copy of a temporary file into this process's own container —
    /// synchronously, before the file goes away — or nil if the copy failed.
    ///
    /// A copy and never a move: the URL may point at storage another process owns (a
    /// Photos asset, not a scratch file), and it may be read-only. `copyItem` streams
    /// through the kernel and clones outright within an APFS volume, so this costs no
    /// memory at any size, which is the entire point.
    ///
    /// **Size is checked here, before the copy**, so an absurd share is refused rather
    /// than duplicated first and rejected after — and refused with the same typed error
    /// `InboxWriter` would have thrown, against the same constant, so the cap has one
    /// value and one meaning. A copy that fails for any other reason returns nil, which
    /// falls back to `loadDataRepresentation` rather than failing the share outright.
    ///
    /// It has to run synchronously inside `NSItemProvider`'s handler, on whatever thread
    /// the handler was given, because the temporary file is gone the moment it returns.
    /// A `@MainActor` copy would have to be awaited — which is exactly the deferral 406
    /// removed. Nothing it touches is isolated: a size check, `FileManager`, and the log.
    static func adopt(_ url: URL) throws -> URL? {
        if let size = InboxWriter.payloadSize(of: .fileURL(url)),
           size > InboxWriter.maximumPayloadBytes {
            ShareLog.share.error(
                "share of \(size, privacy: .public) bytes exceeds the \(InboxWriter.maximumPayloadBytes, privacy: .public) byte cap")
            throw InboxWriteError.payloadTooLarge(
                bytes: size, limit: InboxWriter.maximumPayloadBytes)
        }

        var destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        if !url.pathExtension.isEmpty {
            destination = destination.appendingPathExtension(url.pathExtension)
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            ShareLog.share.error(
                "could not adopt the shared file: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Delete the copy ``adopt(_:)`` took, once the capture is committed or lost.
    ///
    /// Both byte-carrying cases, because tier 2's downloaded file is adopted by the same
    /// function and is just as much this process's to clean up.
    static func discardAdoptedFile(of item: SharedItem) {
        switch item {
        case .image(.fileURL(let url), _, _), .page(_, .fileURL(let url)):
            try? FileManager.default.removeItem(at: url)
        default:
            break
        }
    }
}
