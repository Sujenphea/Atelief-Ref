// AtelierRefsShare — the share extension's process (092 · S4b-ii, 093 § 1).
//
// **What is in this file, and why only this.** The extension has no test host, and
// this slice deliberately does not invent one — that is a bigger decision than a
// share sheet. So the split is: everything decidable from values lives in
// `AtelierCapture.ShareCapture` and is tested under `swift test` on macOS (the host
// → `Platform` table, the `capturedVia` stamp, the `SharedItem` → `CaptureRequest`
// construction, the payload pairing, and — since 098 · P5 — the media fetch's wall).
// What is left in this TARGET is the residue that genuinely needs a process and cannot
// be a pure function:
//
//   • pulling values out of `NSItemProvider`, which is asynchronous and Cocoa
//     (``ProviderPayloads``);
//   • reading Safari's page snapshot out of a plist attachment (``PageSnapshotLoader``);
//   • the network call for a page's media (``MediaFetcher``);
//   • resolving the App Group root, which needs this bundle's own Info.plist;
//   • hosting a view and completing the `NSExtensionContext` — this file.
//
// **This file used to be all four** (098 · finding 7: 848 lines, five jobs). The three
// namespaces above were carved out of it in P5; what is left here is the lifecycle and
// the orchestration — `viewDidLoad`, `capture`, `harvest`, the receipt — which are the
// only parts that touch the controller, the extension context or the card.
//
// Nothing here branches on a host, a scheme or a kind. If a future change wants to,
// it belongs one file over — and in 406 four things that did went, so `harvest` folds
// what the providers gave it and asks `ShareCapture.resolution` what that amounts to.
//
// **What this process never does** (091 · D2, 092 · S2): it does not open SQLite, it
// does not decode an image, and it does not link `AtelierIngestion`. Nothing in here
// asks how wide the picture is, which is the whole reason a 4000px share survives an
// extension's memory budget, and the reason `loadItem` — which would cheerfully hand
// over a `UIImage` — is never used for bytes.
//
// **And since 406 it does not hold the image either.** The bytes come out as a FILE
// (`loadFileRepresentation`) and travel disk-to-disk into `.staging/`, `.data` is the
// fallback for providers that offer no file, and both are capped by
// `InboxWriter.maximumPayloadBytes` so an absurd share fails on the error card instead
// of by disappearing.
//
// **Tier 2 is here, and it is the second `SharedItem` case this header predicted.** A
// share from Safari carries `NSExtensionJavaScriptPreprocessingResultsKey` — the
// snapshot `PagePreprocessor.js` took of the page's DOM — and that snapshot becomes
// provenance in `AtelierCapture.PageExtractor`, off in a package with tests.

import AtelierCapture
import AtelierLibraryPaths
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

    /// The page snapshot, being loaded from the moment this process wakes up.
    ///
    /// **Started before anything else, on purpose.** The page item is vended across XPC
    /// by Safari's web content process, and `NSItemProviderErrorDomain -1000` over
    /// `NSCocoaErrorDomain 4101` is that connection going away underneath us. Everything
    /// in `viewDidLoad` below — the appearance, the hosting controller, the SwiftUI tree
    /// — is work this process does while that connection ages, so the load is kicked off
    /// first and awaited later, in `harvest`, where its result is actually needed.
    private var pageSnapshot: Task<PageHarvest?, Never>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // First, before the UI — see `pageSnapshot`.
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        pageSnapshot = Task { await PageSnapshotLoader.preprocessedPage(in: inputItems) }

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
        // **What arrived, on every share, not only on the ones that fail.** This string
        // was already built for the "nothing capturable" path, and keeping it there meant
        // that the shares which SUCCEED — but succeed differently than expected, a link
        // where a page was wanted, bytes with no URL beside them — said nothing at all.
        // Three separate investigations today ended at "which items did Safari send?",
        // and the answer existed each time and was thrown away. It is one line.
        ShareLog.share.info(
            """
            share arrived — items=\(items.count, privacy: .public) \
            [\(Self.describe(items), privacy: .public)]
            """)

        do {
            guard let shared = try await harvest(items) else {
                // Not a case 093 enumerates, and the activation rule should make it
                // unreachable — a share with neither a web URL nor image bytes should
                // not have offered Atelier at all. It is folded into the same failure
                // card on 093's own grounds: it is a lost capture, and it leaves
                // nothing partial.
                // **Name what actually arrived.** "Nothing capturable" is a conclusion,
                // and a conclusion is the one thing a log line cannot be asked to explain
                // later — the item providers are gone by the time anyone reads it. This
                // is 403's rule for `InboxWriteError` applied to the path that has no
                // error to carry: the vocabulary lands in the log or nowhere.
                ShareLog.share.error(
                    """
                    share carried no web URL and no image bytes — \
                    items=\(items.count, privacy: .public) \
                    types=[\(Self.describe(items), privacy: .public)]
                    """)
                model.card = .failed
                return
            }
            // The adopted copy is this process's to clean up, on every path out of
            // here. The container is torn down shortly after `completeRequest` anyway;
            // this is so a share sheet the user leaves open does not sit on a copy of
            // a photo it has already committed.
            defer { ProviderPayloads.discardAdoptedFile(of: shared) }

            // `LibraryLocation` reads THIS bundle's `AtelierAppGroupIdentifier` —
            // `Bundle.main` in an extension is the extension (092 · S4b-i).
            let root = try LibraryLocation.defaultRoot()
            let draft = ShareCapture.draft(for: shared)
            let record = try InboxWriter(libraryRoot: root).write(
                draft.request, payload: draft.payload)
            // The footprint is read HERE because this is the high-water mark: the bytes
            // have been fetched or adopted and the writer has just staged and committed
            // them. Anything measured earlier is measuring the wrong moment.
            ShareLog.share.info(
                """
                captured \(record.id.uuidString, privacy: .public) \
                platform=\(record.request.provenance.platform, privacy: .public) \
                payload=\(record.payloadFile ?? "none", privacy: .public) \
                bytes=\(draft.payload.flatMap(InboxWriter.payloadSize(of:)) ?? 0, privacy: .public) \
                \(Self.footprint(), privacy: .public)
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
            ShareLog.share.error("capture failed: \(String(describing: error), privacy: .public)")
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
    /// **This function decides nothing, and this time the sentence is enforced.** It walks
    /// the providers, first-non-nil-wins, reads the page snapshot, and hands four optionals
    /// to `ShareCapture.resolution`, which is where image-beats-URL, URL-becomes-sourceURL,
    /// the `file://` filter, the empty-title rule and — since tier 2 — the three tier-2
    /// precedence rules live and are tested. What is left here is asynchronous
    /// `NSItemProvider` loading and the media fetch, which are the only parts that need a
    /// process.
    ///
    /// The claim used to be true and then quietly stopped being: 406 · issue 11 moved four
    /// decisions out, and tier 2 put three back (a page beats tier 1, arrived bytes beat
    /// fetched bytes, no page means tier 1) in the one file with no test host. They are
    /// pure over four optionals, so they went the same way the first four did.
    ///
    /// The web filter is applied at the assignment rather than only at the end, and
    /// that is not redundancy: a `file://` attachment arriving from one provider must
    /// not occupy the slot a later provider's web URL would fill. `webURLString` is
    /// idempotent, so asking twice costs nothing and asking once in the wrong place
    /// would cost a URL.
    ///
    /// Throws only ``InboxWriteError/payloadTooLarge(bytes:limit:)``, and only when nothing
    /// else could be made of the share — see ``oversized`` below.
    private func harvest(_ items: [NSExtensionItem]) async throws -> SharedItem? {
        var image: PayloadSource?
        var urlString: String?
        // Only the sharing app's own title. Deliberately NOT `attributedContentText`,
        // which is the compose field's text in some hosts and the raw URL in others —
        // a title that is sometimes the URL is worse than no title, and tier 1 has no
        // way to tell the difference.
        var title: String?
        // **An over-cap image is held, not thrown** — the whole reason this is a variable.
        //
        // `loadImage` refuses a file above `InboxWriter.maximumPayloadBytes` before copying
        // it, and that refusal used to propagate straight out of this function. Which meant
        // a share whose IMAGE was too big lost its PAGE as well: the snapshot had already
        // loaded, the DOM had the author and the permalink and a rendered-size media URL
        // that is under the cap by construction, and all of it was discarded for a card
        // reading "that one didn't save".
        //
        // That inverts this file's own thesis. Tier 2 failing is tier 1 succeeding — stated
        // three times in this header — but tier 1 failing was taking tier 2 down with it,
        // and tier 2 was the path that would have worked.
        //
        // So the error is carried to the end and rethrown only if the share amounted to
        // nothing else. The refusal is still explicit where it was written to be explicit:
        // a plain oversized photo, with no page and no URL, fails on the card exactly as
        // before, because that is a share with nothing to degrade to.
        var oversized: (any Error)?

        for item in items {
            title = title ?? item.attributedTitle?.string
            for provider in item.attachments ?? [] {
                if image == nil, let identifier = ProviderPayloads.imageIdentifier(of: provider) {
                    do {
                        image = try await ProviderPayloads.loadImage(
                            from: provider, identifier: identifier)
                    } catch {
                        // Recorded and stepped over, so the page snapshot below still gets
                        // its chance. Only the FIRST is kept: they are all the same typed
                        // refusal, and the first is the one that names the file the user
                        // actually chose.
                        oversized = oversized ?? error
                    }
                }
                if urlString == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    urlString = ShareCapture.webURLString(
                        await ProviderPayloads.loadURL(from: provider))
                }
            }
        }

        let page = await pageCapture()

        switch ShareCapture.resolution(
            image: image, urlString: urlString, title: title, page: page
        ) {
        case .resolved(let item):
            // A page resolved WITHOUT its own bytes cannot happen here — `resolution`
            // returns `.needsMedia` for that — so a `.page` case reaching this line
            // carries the picture the user pressed, oversized or not.
            return item
        case .needsMedia(let capture):
            // The fetch, which is the one thing `resolution` cannot do. Its failure is a
            // media-less `.page`, still carrying everything the DOM said, which is why an
            // over-cap image is safe to have stepped over.
            return await MediaFetcher.pageItem(for: capture)
        case .nothing:
            // Nothing was made of the share. If the reason is the image we refused, that
            // refusal is the honest answer and it is thrown now — the card it renders is
            // the one `payloadTooLarge` was added for (091 · D2: a refusal beats a share
            // sheet that silently did nothing).
            if let oversized { throw oversized }
            return nil
        }
    }

    /// The tier-2 page snapshot as a ``PageCapture``, or nil when this share did not come
    /// from a web page — plus the one log line that is the only record of what the DOM held.
    ///
    /// Split out of `harvest` so that function is a walk over providers and a single switch.
    /// The logging is why this is not simply inlined into the call: it needs the raw
    /// `PageHarvest` (media counts, kinds, article indices) which the `PageCapture` no longer
    /// carries, so the two have to be in scope together somewhere.
    private func pageCapture() async -> PageCapture? {
        guard let harvest = await pageSnapshot?.value else { return nil }
        let capture = PageExtractor.capture(from: harvest)
        // **`payload=none` has three causes that look identical from outside.** The
        // page had no picture; the page had one and the extractor did not choose it;
        // the extractor chose one and the fetch failed. Only the third logs anything
        // today, and by the time anyone asks the DOM, the item providers and this
        // process are all gone — 403's rule again: the vocabulary lands here or
        // nowhere. `articles=` earns its place because the twitter branch scopes to
        // the focal `<article>`, and a scoping that picks wrong is indistinguishable
        // from a page with no media at every later point.
        let kinds = Set(harvest.media.map(\.kind.rawValue)).sorted()
        let articles = Set(harvest.media.compactMap(\.articleIndex)).sorted()
        ShareLog.share.info(
            """
            page harvest — media=\(harvest.media.count, privacy: .public) \
            kinds=[\(kinds.joined(separator: " "), privacy: .public)] \
            articles=[\(articles.map(String.init).joined(separator: " "), privacy: .public)] \
            metas=\(harvest.metas.count, privacy: .public) \
            chose=\(capture.mediaURL ?? "none", privacy: .public) \
            fallback=\(capture.mediaURLFallback ?? "none", privacy: .public)
            """)
        return capture
    }

    /// Every type identifier the share offered, and the two text fields that sometimes
    /// carry a URL when no attachment does — the log line above is the only place any of
    /// it survives.
    private static func describe(_ items: [NSExtensionItem]) -> String {
        let types = items
            .flatMap { $0.attachments ?? [] }
            .flatMap(\.registeredTypeIdentifiers)
            .joined(separator: " ")
        let text = items.compactMap { $0.attributedContentText?.string }.joined(separator: "|")
        let titles = items.compactMap { $0.attributedTitle?.string }.joined(separator: "|")
        return "\(types) text=\(text.isEmpty ? "none" : text) title=\(titles.isEmpty ? "none" : titles)"
    }

    // MARK: - Gate 2: the footprint

    /// This process's `phys_footprint` and its remaining headroom, in MB.
    ///
    /// **This is the gate-2 measurement, taken in process rather than in Instruments**
    /// (092 · "Gates and risks" 2). The ~120 MB extension ceiling is observed, not
    /// documented, and `phys_footprint` — dirty plus compressed — is the number jetsam
    /// actually kills on; `os_proc_available_memory` is what is left before it does.
    /// Reading both here beats attaching a profiler to a process that lives two seconds
    /// and is launched by another app: it needs no Mac, no timing luck, and it keeps
    /// working as a regression check if anyone ever pulls decoding back into this process
    /// — which is the specific thing gate 2 exists to prevent.
    ///
    /// Cheap enough to leave in: two syscalls on a path that has already done file I/O.
    private nonisolated static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let outcome = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        let used = outcome == KERN_SUCCESS ? mb(info.phys_footprint) : "?"
        return "footprint=\(used)MB headroom=\(mb(UInt64(os_proc_available_memory())))MB"
    }
}
