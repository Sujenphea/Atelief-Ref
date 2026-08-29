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
// **Tier 2 is here, and it is the second `SharedItem` case this header predicted.** A
// share from Safari now carries `NSExtensionJavaScriptPreprocessingResultsKey` — the
// snapshot `PagePreprocessor.js` took of the page's DOM — and that snapshot becomes
// provenance in `AtelierCapture.PageExtractor`, off in a package with tests. This file
// gained exactly two things a process has to do: read that one attachment, and fetch the
// media URL the extractor picked.
//
// The fetch is the only NETWORK this extension does, and it is bounded on every axis that
// can hurt: http(s) only (decided in `ShareCapture.mediaCandidates`), a short timeout so a
// share sheet is never left waiting on a slow CDN, the same byte cap `InboxWriter`
// enforces, and streamed to a FILE so nothing is held in memory (091 · D2). Every failure
// degrades to the tier-1 link, carrying the richer provenance — so tier 2 failing is tier
// 1 succeeding, which is what makes attempting it here safe.

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

    /// `static` because the item-provider loading below is static too — it holds no
    /// controller state — and a log line from inside a completion handler is exactly
    /// where a share that went wrong is diagnosed.
    ///
    /// `nonisolated` for that last reason: `UIViewController` is `@MainActor`, so a
    /// static on this class inherits that isolation, and the handler this is logged from
    /// runs on whatever thread `NSItemProvider` calls back on. `Logger` is `Sendable` and
    /// os_log is thread-safe, so the isolation was never buying anything here — it was
    /// only making the diagnostic unreachable from the place that needs it.
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sujenphea.AtelierRefsMobile.Share",
        category: "share")

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // First, before the UI — see `pageSnapshot`.
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        pageSnapshot = Task { await Self.preprocessedPage(in: inputItems) }

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
        Self.logger.info(
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
                Self.logger.error(
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
            defer { Self.discardAdoptedFile(of: shared) }

            // `LibraryLocation` reads THIS bundle's `AtelierAppGroupIdentifier` —
            // `Bundle.main` in an extension is the extension (092 · S4b-i).
            let root = try LibraryLocation.defaultRoot()
            let draft = ShareCapture.draft(for: shared)
            let record = try InboxWriter(libraryRoot: root).write(
                draft.request, payload: draft.payload)
            // The footprint is read HERE because this is the high-water mark: the bytes
            // have been fetched or adopted and the writer has just staged and committed
            // them. Anything measured earlier is measuring the wrong moment.
            Self.logger.info(
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
    /// **This function decides nothing, and this time the sentence is enforced.** It walks
    /// the providers, first-non-nil-wins, reads the page snapshot, and hands four optionals
    /// to `ShareCapture.resolution`, which is where image-beats-URL, URL-becomes-sourceURL,
    /// the `file://` filter, the empty-title rule and — since this change — the three tier-2
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
                if image == nil, let identifier = Self.imageIdentifier(of: provider) {
                    do {
                        image = try await Self.loadImage(from: provider, identifier: identifier)
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
                        await Self.loadURL(from: provider))
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
            return await Self.pageItem(for: capture)
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
        Self.logger.info(
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

    // MARK: - Tier 2: the page Safari preprocessed

    /// The DOM snapshot `PagePreprocessor.js` returned, or nil when this share did not
    /// come from a web page.
    ///
    /// Safari puts it in a `public.propertylist` attachment, under the results key, and
    /// only when the activation rule asked for a web page — so its absence is the
    /// ordinary case (a photo, a link out of Messages) and not a failure.
    private nonisolated static func preprocessedPage(
        in items: [NSExtensionItem]
    ) async -> PageHarvest? {
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(
                    UTType.propertyList.identifier) else { continue }

                let started = Date()
                // **Two routes, because they fail differently.** `loadDataRepresentation`
                // asks for bytes and needs no class negotiation across XPC. `loadItem` is
                // the documented call and hands back the dictionary already unarchived,
                // but it negotiates a class with Safari's web content process — and that
                // negotiation is what -1000 reports failing. Neither is reliably the
                // better one, so the cheap route is tried first, the documented one
                // second, and the log says which answered.
                var route = "data"
                var load = await loadPage(from: provider, asData: true)
                if load.harvest == nil {
                    let viaItem = await loadPage(from: provider, asData: false)
                    if viaItem.harvest != nil {
                        load = viaItem
                        route = "item"
                    } else {
                        route = "data+item"
                        load = PageLoad(
                            harvest: nil,
                            keys: "\(load.keys) | \(viaItem.keys)",
                            error: "\(load.error) | \(viaItem.error)")
                    }
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)

                // **The elapsed time is the diagnostic, not decoration.** A load that
                // fails in single-digit milliseconds failed because the connection was
                // already gone before this process asked; one that fails after seconds
                // failed because Safari was still waiting on the script. Those have
                // opposite fixes and are otherwise indistinguishable — the error reads
                // -1000 either way.
                let line = "page item — route=\(route) ms=\(ms) "
                    + "keys=[\(load.keys)] error=\(load.error)"
                if load.harvest == nil {
                    logger.error("\(line, privacy: .public)")
                } else {
                    logger.info("\(line, privacy: .public)")
                }

                if let harvest = load.harvest { return harvest }
            }
        }
        return nil
    }

    /// What one attempt at the page item produced.
    ///
    /// `Sendable` so it can cross the continuation below — an `NSItemProvider`'s own
    /// result cannot, which is why every attempt classifies inside its handler.
    private struct PageLoad: Sendable {
        var harvest: PageHarvest?
        var keys: String
        var error: String
    }

    private nonisolated static func loadPage(
        from provider: NSItemProvider, asData: Bool
    ) async -> PageLoad {
        await withCheckedContinuation { continuation in
            let identifier = UTType.propertyList.identifier
            if asData {
                provider.loadDataRepresentation(
                    forTypeIdentifier: identifier
                ) { data, error in
                    continuation.resume(
                        returning: Self.pageLoad(
                            dictionary: data.flatMap(Self.resultsDictionary(from:)),
                            error: error))
                }
            } else {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    continuation.resume(
                        returning: Self.pageLoad(
                            dictionary: item as? [String: Any], error: error))
                }
            }
        }
    }

    private nonisolated static func pageLoad(
        dictionary: [String: Any]?, error: Error?
    ) -> PageLoad {
        let results = dictionary?[PageHarvest.resultsKey]
        let harvest = PageHarvest.harvest(fromResults: results)
        return PageLoad(
            harvest: harvest,
            keys: (dictionary?.keys.sorted().joined(separator: " ") ?? "nil")
                + (harvest == nil ? " → \(diagnose(results))" : ""),
            error: error.map { String(describing: $0) } ?? "none")
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

    /// Why a loaded results dictionary produced no harvest.
    ///
    /// `PageHarvest.harvest(fromResults:)` is four `guard`s and one optional return, and it
    /// reports which one refused by returning nil — a shape that is right for a pure
    /// function tested over a hundred inputs, and useless in the one process where the
    /// input cannot be reproduced. This walks the same steps and names the one that failed.
    private nonisolated static func diagnose(_ results: Any?) -> String {
        guard let results else { return "results absent" }
        guard let dictionary = results as? [String: Any] else {
            return "results is \(type(of: results)), not a dictionary"
        }
        let keys = dictionary.keys.sorted().joined(separator: " ")
        guard JSONSerialization.isValidJSONObject(dictionary) else {
            return "results not JSON-valid keys=[\(keys)]"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return "results not JSON-encodable keys=[\(keys)]"
        }
        do {
            let raw = try JSONDecoder().decode(RawPageSignals.self, from: data)
            return "decoded keys=[\(keys)] url=\(raw.url ?? "nil") "
                + "images=\(raw.images?.count ?? -1) metas=\(raw.metas?.count ?? -1)"
        } catch {
            return "decode failed keys=[\(keys)] \(error)"
        }
    }

    /// `nonisolated` for the same reason ``logger`` is: this runs on whatever thread
    /// `NSItemProvider` calls back on, and it touches nothing but its argument.
    private nonisolated static func resultsDictionary(from data: Data) -> [String: Any]? {
        if let plain = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any], plain["$archiver"] == nil {
            return plain
        }
        // The archive holds a dictionary of strings, numbers and nested collections —
        // what a JSON-ish value from JavaScript becomes. Naming the classes is required:
        // `unarchivedObject` keeps secure coding on, and an unbounded unarchive of data
        // from another process is not something to do for convenience.
        let classes = [
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSNull.self,
        ]
        let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)
        return object as? [String: Any]
    }

    /// A page capture with its media fetched, or without it.
    ///
    /// Never throws and never fails the share: everything here is best-effort by
    /// construction, because the alternative to a picture is a link that still carries
    /// the DOM's provenance. That is the whole reason fetching in an extension is
    /// defensible.
    /// **The budget is for the SHARE, not for each attempt** — which is what
    /// ``mediaFetchBudget``'s own wording always claimed and the code did not do.
    ///
    /// `mediaCandidates` returns up to two URLs, and the second exists precisely because
    /// the first is a rewrite that is KNOWN to fail sometimes (`/originals/` 404s on
    /// Pinterest, `name=orig` gets refused). So two attempts is the expected path when the
    /// rewrite is wrong, not an exotic one — and with the timeout applied per attempt, two
    /// slow-or-dead CDN requests left the user watching the card for sixteen seconds. At
    /// that length a share sheet does not read as "fetching", it reads as a hang.
    ///
    /// One deadline for the whole loop, and each attempt gets what is left of it. A
    /// candidate reached with no budget remaining is not attempted at all, because starting
    /// a request that is already out of time only delays the fallback that was going to
    /// happen anyway.
    ///
    /// One session for the loop as well. Its `timeoutIntervalForResource` is the whole
    /// budget — a genuine ceiling on the share rather than on a request — while each
    /// request carries the remainder as its own `timeoutInterval`. The two together are
    /// what make the bound hold whether one candidate hangs or both are merely slow.
    private static func pageItem(for capture: PageCapture) async -> SharedItem {
        let candidates = ShareCapture.mediaCandidates(for: capture)
        guard !candidates.isEmpty else { return .page(capture) }

        let session = makeMediaSession()
        defer { session.finishTasksAndInvalidate() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(mediaFetchBudget))
        for candidate in candidates {
            let remaining = remainingSeconds(until: deadline)
            guard remaining > 0 else {
                logger.info("media budget spent before \(candidate, privacy: .public)")
                break
            }
            if let file = await fetchMedia(candidate, in: session, timeout: remaining) {
                return .page(capture, bytes: .fileURL(file))
            }
        }
        return .page(capture)
    }

    /// Seconds left before `deadline`, floored at zero.
    ///
    /// `ContinuousClock` rather than `Date`: it does not move when the wall clock does, and
    /// a share sheet that got longer because the user crossed a timezone would be an
    /// absurd bug to own.
    private static func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return 0 }
        let (seconds, attoseconds) = left.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// How long the whole media fetch may take before the share gives up on it.
    ///
    /// A receipt the user is watching is on the other side of this. 093 § 1 wants the
    /// card in under a second; a picture is worth waiting a little longer for, and a CDN
    /// that has not answered in eight seconds is not about to make anyone happy.
    ///
    /// Renamed from `mediaFetchTimeout` when it became one: a "timeout" is a property of a
    /// request and this is a property of the share, and the old name is most of why it was
    /// applied per candidate for as long as it was.
    private static let mediaFetchBudget: TimeInterval = 8

    /// The one session a share's fetches share.
    ///
    /// A cookie-less ephemeral session, matching `PageResolver`'s posture on the Mac: the
    /// URL came out of a page, this is a fetch of a public CDN asset, and there is no
    /// reason to hand it anybody's cookies.
    private static func makeMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = mediaFetchBudget
        // The share-wide ceiling. Per-request time is bounded again, more tightly, by the
        // `timeout` each call passes.
        configuration.timeoutIntervalForResource = mediaFetchBudget
        return URLSession(configuration: configuration)
    }

    /// Download `urlString` to a file this process owns, or nil.
    ///
    /// **Streamed to disk, never held.** `URLSession.download` writes the body to a
    /// temporary file, so a 12 MB photo costs this process no memory — the same reason
    /// `loadFileRepresentation` is preferred over `loadDataRepresentation` above, and the
    /// reason a fetch is affordable at all inside a ~120 MB ceiling (091 · D2).
    ///
    /// The size is checked TWICE and both are necessary: `expectedContentLength` refuses
    /// an absurd file before a byte is transferred, and the file's real size catches a
    /// server that lied or sent no length at all.
    ///
    /// `session` is the share's, not this call's — see ``pageItem(for:)``. `timeout` is
    /// what remains of the share's budget, carried on the request so a second candidate
    /// cannot spend a second full allowance.
    private static func fetchMedia(
        _ urlString: String, in session: URLSession, timeout: TimeInterval
    ) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (file, response) = try await session.download(for: request)
            if let expected = (response as? HTTPURLResponse)?.expectedContentLength,
               expected > Int64(InboxWriter.maximumPayloadBytes) {
                logger.info("media of \(expected, privacy: .public) bytes is over the cap")
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                logger.info("media fetch returned \(status, privacy: .public)")
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            // The downloaded file lives in a temporary location the system reclaims, so
            // it is adopted immediately — the same discipline `loadFileRepresentation`
            // needs, for the same reason. `adopt` also applies the byte cap.
            return try adopt(file)
        } catch {
            logger.info("media fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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
    ///
    /// `nonisolated`, and that is the same requirement stated a second way: this has to
    /// run synchronously inside `NSItemProvider`'s handler, on whatever thread the
    /// handler was given, because the temporary file is gone the moment it returns. A
    /// `@MainActor` copy would have to be awaited — which is exactly the deferral 406
    /// removed. Nothing it touches is isolated: a size check, `FileManager`, and the
    /// logger above.
    private nonisolated static func adopt(_ url: URL) throws -> URL? {
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
    ///
    /// Both byte-carrying cases, because tier 2's downloaded file is adopted by the same
    /// function and is just as much this process's to clean up.
    private static func discardAdoptedFile(of item: SharedItem) {
        switch item {
        case .image(.fileURL(let url), _, _), .page(_, .fileURL(let url)):
            try? FileManager.default.removeItem(at: url)
        default:
            break
        }
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
