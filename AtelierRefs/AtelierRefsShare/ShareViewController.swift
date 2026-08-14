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
// it belongs one file over.
//
// **What this process never does** (091 · D2, 092 · S2): it does not open SQLite, it
// does not decode an image, and it does not link `AtelierIngestion`. The bytes go
// from an item provider straight to a `.bin` sidecar as `Data`; nothing in here asks
// how wide the picture is. That is the whole reason a 4000px share survives an
// extension's memory budget, and the reason `loadDataRepresentation` is used below
// rather than the `UIImage` an item provider would happily hand over.
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

    private let logger = Logger(
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

        guard let shared = await harvest(items) else {
            // Not a case 093 enumerates, and the activation rule should make it
            // unreachable — a share with neither a web URL nor image bytes should not
            // have offered Atelier at all. It is folded into the same failure card on
            // 093's own grounds: it is a lost capture, and it leaves nothing partial.
            logger.error("share carried no web URL and no image bytes")
            model.card = .failed
            return
        }

        do {
            // `LibraryLocation` reads THIS bundle's `AtelierAppGroupIdentifier` —
            // `Bundle.main` in an extension is the extension (092 · S4b-i).
            let root = try LibraryLocation.defaultRoot()
            let draft = ShareCapture.draft(for: shared)
            let record = try InboxWriter(libraryRoot: root).write(
                draft.request, payload: draft.payload)
            logger.info(
                """
                captured \(record.id.uuidString, privacy: .public) \
                platform=\(record.request.provenance.platform, privacy: .public) \
                payload=\(record.payloadFile ?? "none", privacy: .public)
                """)
            await confirmAndDismiss()
        } catch {
            // One card for every typed failure: `InboxWriteError`'s four
            // (`InboxWriter.swift:46`–`:62`) and `LibraryLocationError`'s two, which
            // 093 § 7 flags as the one hole worth closing early — a provisioning bug
            // has to render somewhere, and this is the only surface that exists. The
            // payloads stay in the log, where the vocabulary belongs.
            logger.error("capture failed: \(String(describing: error), privacy: .public)")
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
    /// Image bytes win over a URL when both are present, and the URL then becomes the
    /// image's `sourceURL` — an image shared out of a browser carries the media URL
    /// beside the bytes, and that is where its provenance comes from.
    private func harvest(_ items: [NSExtensionItem]) async -> SharedItem? {
        var bytes: Data?
        var urlString: String?
        // Only the sharing app's own title. Deliberately NOT `attributedContentText`,
        // which is the compose field's text in some hosts and the raw URL in others —
        // a title that is sometimes the URL is worse than no title, and tier 1 has no
        // way to tell the difference.
        var title: String?

        for item in items {
            title = title ?? item.attributedTitle?.string
            for provider in item.attachments ?? [] {
                if bytes == nil, let identifier = Self.imageIdentifier(of: provider) {
                    bytes = await Self.loadData(from: provider, identifier: identifier)
                }
                if urlString == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    urlString = await Self.loadWebURL(from: provider)
                }
            }
        }

        if let bytes {
            return .image(bytes: bytes, sourceURL: urlString, title: title)
        }
        if let urlString {
            return .link(url: urlString, title: title)
        }
        return nil
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

    /// The provider's bytes for `identifier`, without decoding them.
    ///
    /// `loadDataRepresentation`, not `loadItem` — the latter cheerfully hands back a
    /// `UIImage`, which is a decoded bitmap this process must never hold (092 · S2).
    private static func loadData(
        from provider: NSItemProvider, identifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The provider's URL, if it is a web URL.
    ///
    /// The http(s) filter is here because `public.file-url` CONFORMS to `public.url`:
    /// an image shared out of Files arrives with a `file://` attachment, and storing
    /// that as `originalURL` would put a path from a container that no longer exists
    /// into a capture's provenance. A share with no web URL is not a broken share —
    /// it is a photo.
    private static func loadWebURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier, options: nil
            ) { item, _ in
                guard let url = item as? URL,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url.absoluteString)
            }
        }
    }
}
