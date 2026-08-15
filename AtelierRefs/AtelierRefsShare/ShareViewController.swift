// AtelierRefsShare — the share extension's process (092 · S4b-ii, 093 § 1).
//
// **What is in this file, and why only this.** The extension has no test host, and
// this slice deliberately does not invent one — that is a bigger decision than a
// share sheet. So the split is: everything decidable from values lives in
// `AtelierCapture.ShareCapture` and is tested under `swift test` on macOS (the host
// → `Platform` table, the `capturedVia` stamp, the `SharedItem` → `CaptureRequest`
// construction, and the payload pairing). What is left here is the residue that
// genuinely needs a process and cannot be a pure function:
//
//   • pulling values out of `NSItemProvider`, which is asynchronous and Cocoa;
//   • resolving the App Group root, which needs this bundle's own Info.plist;
//   • hosting a view and completing the `NSExtensionContext`.
//
// Nothing here branches on a host, a scheme or a kind. If a future change wants to,
// it belongs one file over — and in 406 four things that did went, so `harvest` folds
// what the providers gave it and asks `ShareCapture.sharedItem` what that amounts to.
//
// **What this process never does** (091 · D2, 092 · S2): it does not open SQLite, it
// does not decode an image, and it does not link `AtelierIngestion`. Nothing in here
// asks how wide the picture is, which is the whole reason a 4000px share survives an
// extension's memory budget, and the reason `loadItem` — which would cheerfully hand
// over a `UIImage` — is never used for bytes.
//
// **And since 406 it does not hold the image either.** `loadDataRepresentation`
// returns the ENTIRE file as a `Data`, resident, in a process with an observed ~120 MB
// ceiling and no size cap anywhere on the path to the sidecar; the failure that
// produces is the extension getting jetsammed and the user seeing a share sheet that
// silently did nothing, which is the one outcome 091 · D2 says must not happen. So the
// bytes now come out as a FILE (`loadFileRepresentation`) and travel disk-to-disk into
// `.staging/`, `.data` is the fallback for providers that offer no file, and both are
// capped by `InboxWriter.maximumPayloadBytes` so an absurd share fails on the error
// card instead of by disappearing.
//
// **Tier 1 only.** A URL or image bytes, per 092 · S4b. No
// `NSExtensionJavaScriptPreprocessingFile`, no ported extractors, no DOM. The Mac
// resolves og-tags at drain time through the existing `PageResolver`. Tier 2 is a
// later slice, and the shape it will need — richer provenance from a preprocessed
// dictionary — is a second `SharedItem` case, not a rewrite of this file.

import AtelierCapture
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    /// How long "Saved to Unsorted" stays before the extension dismisses itself.
    ///
    /// **This value is [093](../../.docs/093-ios-visual-design.md)'s open question 2
    /// and is the user's to settle on a device.** The doc rules out the Mac toast's
    /// 6 s TTL (`ToastQueue.swift:60`) as far too long for a process whose job is to
    /// get out of the way, and says something under a second is the right order; 0.8 s
    /// is a defensible point in that range and nothing more. It is a single named
    /// constant so changing it is one edit, and the removal animation below is a
    /// separate 0.15 s, so the card is on screen for roughly 0.95 s in total.
    private static let successDismissDelay: Duration = .milliseconds(800)

    private let model = ShareCardModel()

    /// `static` because the item-provider loading below is static too — it holds no
    /// controller state — and a log line from inside a completion handler is exactly
    /// where a share that went wrong is diagnosed.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sujenphea.AtelierRefsMobile.Share",
        category: "share")

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // 093 § 6: the extension is its own bundle and inherits nothing from the host
        // app's appearance, so it commits to dark here as well as in its Info.plist.
        // A light system chrome around a dark card is the worst of both.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear

        let host = UIHostingController(
            rootView: ShareCardView(model: model, onDismiss: { [weak self] in
                self?.complete()
            }))
        // Both clears matter: the hosting controller paints its own background
        // otherwise, and the card is supposed to float over the app the user was in.
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await capture() }
    }

    // MARK: - The capture

    /// Harvest the share, write it to the inbox, and show the receipt.
    ///
    /// The order is the one 093 argues for: the durable thing happens first and the
    /// card reports it. `completeRequest` in `viewDidLoad` would be indistinguishable
    /// from the silent-share failure this whole design exists to avoid.
    private func capture() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []

        do {
            guard let shared = try await harvest(items) else {
                // Not a case 093 enumerates, and the activation rule should make it
                // unreachable — a share with neither a web URL nor image bytes should
                // not have offered Atelier at all. It is folded into the same failure
                // card on 093's own grounds: it is a lost capture, and it leaves
                // nothing partial.
                Self.logger.error("share carried no web URL and no image bytes")
                model.card = .failed
                return
            }
            // The adopted copy is this process's to clean up, on every path out of
            // here. The container is torn down shortly after `completeRequest` anyway;
            // this is so a share sheet the user leaves open does not sit on a copy of
            // a photo it has already committed.
            defer { Self.discardAdoptedFile(of: shared) }

            // `LibraryLocation` reads THIS bundle's `AtelierAppGroupIdentifier` —
            // `Bundle.main` in an extension is the extension (092 · S4b-i).
            let root = try LibraryLocation.defaultRoot()
            let draft = ShareCapture.draft(for: shared)
            let record = try InboxWriter(libraryRoot: root).write(
                draft.request, payload: draft.payload)
            Self.logger.info(
                """
                captured \(record.id.uuidString, privacy: .public) \
                platform=\(record.request.provenance.platform, privacy: .public) \
                payload=\(record.payloadFile ?? "none", privacy: .public)
                """)
            await confirmAndDismiss()
        } catch {
            // One card for every typed failure: `InboxWriteError`'s five and
            // `LibraryLocationError`'s two, the latter of which
            // 093 § 7 flags as the one hole worth closing early — a provisioning bug
            // has to render somewhere, and this is the only surface that exists. The
            // payloads stay in the log, where the vocabulary belongs — and this is the
            // ONLY place they land, which is why each `InboxWriteError` case carries an
            // `underlying` describing the error it caught (403). The card says a share
            // was lost; this line is the only thing that can say a disk was full.
            //
            // The fifth case is `payloadTooLarge`, thrown by `harvest` before a byte is
            // copied and by the writer before a byte is staged. It renders here like
            // the rest, and that IS the fix: an over-cap share now fails on a card that
            // does not auto-dismiss, instead of getting this process jetsammed and
            // leaving a share sheet that appeared to work and did nothing (091 · D2).
            Self.logger.error("capture failed: \(String(describing: error), privacy: .public)")
            model.card = .failed
        }
    }

    /// Show "Saved to Unsorted", wait, and get out of the way.
    private func confirmAndDismiss() async {
        model.card = .saved
        try? await Task.sleep(for: Self.successDismissDelay)
        model.card = nil
        // Let the removal transition finish before the sheet vanishes, so the card
        // fades rather than being cut off with the window.
        try? await Task.sleep(for: ShareTheme.Motion.gentleDuration)
        complete()
    }

    /// End the extension request.
    ///
    /// `completeRequest`, never `cancelRequest(withError:)` — even on failure. 093
    /// rejected the system-presented alternative because the wording would not be
    /// ours and a system extension failure reads as a crash rather than as "that one
    /// didn't save".
    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Reading the share

    /// The one ``SharedItem`` in a share, or nil if there is nothing capturable.
    ///
    /// **This function no longer decides anything** (406, issue 11). It walks the
    /// providers, first-non-nil-wins, and hands three optionals to
    /// `ShareCapture.sharedItem`, which is where image-beats-URL, URL-becomes-sourceURL,
    /// the `file://` filter and the empty-title rule now live and are tested. What is
    /// left here is asynchronous `NSItemProvider` loading, which is the only part that
    /// needs a process.
    ///
    /// The web filter is applied at the assignment rather than only at the end, and
    /// that is not redundancy: a `file://` attachment arriving from one provider must
    /// not occupy the slot a later provider's web URL would fill. `webURLString` is
    /// idempotent, so asking twice costs nothing and asking once in the wrong place
    /// would cost a URL.
    ///
    /// Throws only ``InboxWriteError/payloadTooLarge(bytes:limit:)``, from a file too
    /// big to accept — refused before it is copied, and rendered by `capture()`'s
    /// existing failure card.
    private func harvest(_ items: [NSExtensionItem]) async throws -> SharedItem? {
        var image: PayloadSource?
        var urlString: String?
        // Only the sharing app's own title. Deliberately NOT `attributedContentText`,
        // which is the compose field's text in some hosts and the raw URL in others —
        // a title that is sometimes the URL is worse than no title, and tier 1 has no
        // way to tell the difference.
        var title: String?

        for item in items {
            title = title ?? item.attributedTitle?.string
            for provider in item.attachments ?? [] {
                if image == nil, let identifier = Self.imageIdentifier(of: provider) {
                    image = try await Self.loadImage(from: provider, identifier: identifier)
                }
                if urlString == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    urlString = ShareCapture.webURLString(
                        await Self.loadURL(from: provider))
                }
            }
        }

        return ShareCapture.sharedItem(image: image, urlString: urlString, title: title)
    }

    /// The provider's registered identifier that is an image, or nil.
    ///
    /// Asked by conformance rather than by name: a share registers `public.jpeg` or
    /// `public.heic`, not `public.image`, and loading by the concrete identifier is
    /// what gets the ORIGINAL bytes back instead of a re-encode.
    private static func imageIdentifier(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    /// Where the provider's image bytes are, preferring a file over memory (406).
    ///
    /// **A file first, always.** `loadDataRepresentation` returns the WHOLE image as a
    /// `Data`, and that `Data` then travels through `ShareCaptureDraft` into
    /// `InboxWriter` — peak footprint one entire file, resident, in a process with an
    /// observed ~120 MB ceiling. `loadFileRepresentation` hands over a temporary file
    /// instead, which is copied disk-to-disk into the sidecar and never loaded here.
    /// This is the same argument `AtelierIngestion.ByteSource` makes at the far end of
    /// the pipe (092 · S3 prefers `.fileURL` over `.data` for exactly this reason), and
    /// until 406 this file was the one place contradicting it.
    ///
    /// **The `Data` path is the fallback and not a leftover.** Not every provider
    /// vends a file representation, and a share that would otherwise be lost is worth
    /// the memory. It is capped too — by `InboxWriter`, since by the time a `Data`
    /// exists the bytes are already resident and nothing here can un-load them.
    private static func loadImage(
        from provider: NSItemProvider, identifier: String
    ) async throws -> PayloadSource? {
        if let file = try await loadFile(from: provider, identifier: identifier) {
            return .fileURL(file)
        }
        Self.logger.info("no file representation for \(identifier, privacy: .public)")
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
    /// small file and races on a large one — the exact bug this slice is fixing, hidden
    /// behind a passing test. So ``adopt(_:)`` runs INSIDE the handler, synchronously,
    /// and the continuation is resumed with a URL this process owns and nothing else
    /// can delete.
    private static func loadFile(
        from provider: NSItemProvider, identifier: String
    ) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(
                forTypeIdentifier: identifier
            ) { url, error in
                guard let url else {
                    if let error {
                        Self.logger.info(
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

    /// Take a copy of a provider's temporary file into this process's own container —
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
    private static func adopt(_ url: URL) throws -> URL? {
        if let size = InboxWriter.payloadSize(of: .fileURL(url)),
           size > InboxWriter.maximumPayloadBytes {
            Self.logger.error(
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
            Self.logger.error(
                "could not adopt the shared file: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Delete the copy ``adopt(_:)`` took, once the capture is committed or lost.
    private static func discardAdoptedFile(of item: SharedItem) {
        guard case .image(.fileURL(let url), _, _) = item else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The provider's bytes for `identifier`, without decoding them.
    ///
    /// `loadDataRepresentation`, not `loadItem` — the latter cheerfully hands back a
    /// `UIImage`, which is a decoded bitmap this process must never hold (092 · S2).
    /// The fallback only: see ``loadImage(from:identifier:)``.
    private static func loadData(
        from provider: NSItemProvider, identifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The provider's URL as a string, whatever kind of URL it is.
    ///
    /// **The http(s) filter used to be here and is now `ShareCapture.webURLString`**
    /// (406, issue 11) — it is a predicate over a string, so it belongs where it can be
    /// tested. The reason for it is unchanged: `public.file-url` CONFORMS to
    /// `public.url`, so an image shared out of Files arrives with a `file://`
    /// attachment, and storing that as `originalURL` would put a path from a container
    /// that no longer exists into a capture's provenance.
    private static func loadURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier, options: nil
            ) { item, _ in
                continuation.resume(returning: (item as? URL)?.absoluteString)
            }
        }
    }
}
