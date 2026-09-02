// AtelierRefsShare — reading the DOM snapshot Safari took (092 · S4b, tier 2).
//
// **Tier 2's transport half.** `PagePreprocessor.js` runs inside the shared page and
// hands its result to this process as a `com.apple.property-list` attachment; this file
// is the code that gets it out of the attachment and into a ``PageHarvest``. Everything
// it then MEANS — which meta wins, which image is the post's, what the media URL is — is
// `AtelierCapture.PageExtractor`'s, off in a package with tests.
//
// So the rule for this file is the extension's rule generally: it decides nothing, it
// only transports and diagnoses. What is here is here because it needs an
// `NSItemProvider` and cannot be a pure function.
//
// **The diagnosis is the bulk of it, and it is load-bearing.** A page item that fails to
// load is a LOST capture, not a degraded one: `SupportsWebPage` makes Safari send the page
// item INSTEAD OF a URL item (`Info.plist:49-53`), so there is nothing to fall back to.
// By the time anyone reads the log the item providers, the web content process and this
// process are all gone — so which route answered, how long it took, which keys arrived and
// which `guard` in `PageHarvest.harvest(fromResults:)` refused have to be recorded here or
// they are unrecoverable. That is 403's rule for `InboxWriteError` applied to a path with
// no error to carry: the vocabulary lands in the log or nowhere.
//
// Split out of `ShareViewController` in 098 · P5 (finding 7): the file was 848 lines doing
// five jobs. Everything here was already `nonisolated static` and moved unchanged.

import AtelierCapture
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Getting `PagePreprocessor.js`'s snapshot out of the share, or saying why it could not be.
nonisolated enum PageSnapshotLoader {

    /// The DOM snapshot `PagePreprocessor.js` returned, or nil when this share did not
    /// come from a web page.
    ///
    /// Safari puts it in a `public.propertylist` attachment, under the results key, and
    /// only when the activation rule asked for a web page — so its absence is the
    /// ordinary case (a photo, a link out of Messages) and not a failure.
    static func preprocessedPage(in items: [NSExtensionItem]) async -> PageHarvest? {
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
                    ShareLog.share.error("\(line, privacy: .public)")
                } else {
                    ShareLog.share.info("\(line, privacy: .public)")
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

    private static func loadPage(
        from provider: NSItemProvider, asData: Bool
    ) async -> PageLoad {
        await withCheckedContinuation { continuation in
            let identifier = UTType.propertyList.identifier
            if asData {
                provider.loadDataRepresentation(
                    forTypeIdentifier: identifier
                ) { data, error in
                    continuation.resume(
                        returning: pageLoad(
                            dictionary: data.flatMap(resultsDictionary(from:)),
                            error: error))
                }
            } else {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    continuation.resume(
                        returning: pageLoad(
                            dictionary: item as? [String: Any], error: error))
                }
            }
        }
    }

    private static func pageLoad(
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

    /// Why a loaded results dictionary produced no harvest.
    ///
    /// `PageHarvest.harvest(fromResults:)` is four `guard`s and one optional return, and it
    /// reports which one refused by returning nil — a shape that is right for a pure
    /// function tested over a hundred inputs, and useless in the one process where the
    /// input cannot be reproduced. This walks the same steps and names the one that failed.
    private static func diagnose(_ results: Any?) -> String {
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

    /// The plist an attachment's bytes hold, plain or keyed-archived.
    private static func resultsDictionary(from data: Data) -> [String: Any]? {
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
}
