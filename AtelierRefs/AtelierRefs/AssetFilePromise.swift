//
//  AssetFilePromise.swift
//  AtelierRefs
//
//  011 · Cluster A (out-flow) — the AppKit file-promise plumbing for dragging a
//  ref OUT of the collection grid into an external app (Finder / Figma / …). File
//  promises are the sandbox-safe export path: the drop destination is granted by
//  the drag machinery, so no new entitlement is needed and no bytes are copied
//  until (and unless) the drop actually lands.
//
//  Two pieces:
//   • `AssetFilePromiseProvider` (2A) — an `NSFilePromiseProvider` that ALSO vends
//     the app-private `.assetIDs` payload on the PRIMARY dragged item, so one
//     dragging session serves both an external file export AND a drop back inside
//     the app (reorder / move / drop-to-rail), which reads `.assetIDs` unchanged.
//   • `AssetFilePromiseDelegate` (8A) — a stateless shared singleton that copies
//     the blob to its drop destination on a background queue. Shared because
//     `NSFilePromiseProvider.delegate` is WEAK and a drag can outlive its source
//     view (e.g. a collection switch tears the grid coordinator down mid-drag).
//

import AppKit
import UniformTypeIdentifiers

/// An `NSFilePromiseProvider` carrying one asset's export, and — on the primary
/// dragged item only — the internal `.assetIDs` payload (2A).
///
/// `nonisolated` because every method here OVERRIDES a nonisolated
/// `NSPasteboardWriting` requirement, and AppKit calls them from wherever it is
/// servicing the pasteboard. Under this target's MainActor-by-default the class
/// would otherwise infer main-actor isolation and the overrides would not match
/// what they override.
///
/// That makes the two stored properties nonisolated mutable state, which is sound
/// here and not a `Sendable` claim: the class is not `Sendable`, and both are written
/// ONCE on the main actor while the drag is assembled, then only read.
nonisolated final class AssetFilePromiseProvider: NSFilePromiseProvider {
    /// The blob + filename this promise writes. Read by the delegate at drop time.
    var exportItem: AssetExportItem?
    /// The app-private `AssetDragPayload` JSON, set on the PRIMARY provider only.
    /// When present, this provider also advertises `AssetDragPayload.pasteboardType`
    /// so an intra-app drop still finds the payload it expects.
    var assetPayloadData: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if assetPayloadData != nil { types.append(AssetDragPayload.pasteboardType) }
        return types
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        // The payload is written eagerly (not `.promised`) so an intra-app drop can
        // read it immediately; the promised FILE keeps the provider's own options.
        type == AssetDragPayload.pasteboardType
            ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == AssetDragPayload.pasteboardType { return assetPayloadData }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Copies a promised blob to its drop destination. Stateless — everything is read
/// from the provider — so the single ``shared`` instance safely serves every drag
/// and satisfies the weak `delegate` reference for a drag that outlives its source.
final class AssetFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = AssetFilePromiseDelegate()

    /// The promise writes run here, off the main thread (13A). On APFS a
    /// same-volume `copyItem` is copy-on-write (an instant clone); a cross-volume
    /// drop is a real copy, but still off-main.
    private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        (provider as? AssetFilePromiseProvider)?.exportItem?.filename ?? "image"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Re-check existence at write time (5A): the blob may have been reaped
        // between drag-start and drop. Report the failure so the OS shows a failed
        // drop rather than writing a zero-byte file.
        guard let source = (provider as? AssetFilePromiseProvider)?.exportItem?.blobURL,
              FileManager.default.fileExists(atPath: source.path) else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { writeQueue }
}
