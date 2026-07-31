//
//  AssetDragPayload.swift
//  AtelierRefs
//
//  009 · N3 — the ONE drag payload shared by in-grid reorder, the sidebar
//  space/collection rows, and (future) the gallery. Carries the dragged asset ids
//  PLUS their source collection, so a drop can tell a same-collection reorder
//  from a cross-collection move without guessing. Replaces the old bare-UUID
//  `String` payload everywhere.
//
//  The custom `UTType` is BOTH declared in `Info.plist`
//  (`UTExportedTypeDeclarations`, conforming to `public.data`) AND mirrored here
//  via `UTType(exportedAs:)`. The Info.plist declaration is load-bearing: without
//  it the OS doesn't recognize the identifier at a drop destination, so every
//  drag (reorder / stack-move / rail-move) shows an invalid cursor and snaps back.
//

import AppKit
import AtelierCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The app-private drag identifier for a set of asset ids + their source.
    /// `nonisolated` so the AppKit drag seams can read it off the main actor —
    /// under MainActor-by-default a bare `static let` in this target infers
    /// main-actor isolation, which a pasteboard type constant has no use for.
    nonisolated static let assetIDs = UTType(exportedAs: "com.ref-atelier.asset-ids")
}

/// A dragged set of assets and where they came from (009 · N3). `Codable` for the
/// transfer representation; `Equatable` for tests.
struct AssetDragPayload: Codable, Equatable, Transferable {
    /// The dragged assets, in the source's feed order.
    var assetIDs: [UUID]
    /// The collection the drag started from — lets a drop distinguish a
    /// same-collection reorder from a cross-collection move, and enforce the
    /// `from == to` no-op.
    var sourceCollectionID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .assetIDs)
    }
}

// MARK: - NSPasteboard bridge (036 §4 A3 — byte-compatible with the SwiftUI drag)

extension AssetDragPayload {
    /// The pasteboard type the AppKit drag writes under — the SAME identifier the
    /// `.assetIDs` `UTType` (and therefore the SwiftUI `CodableRepresentation`)
    /// uses, so a drag started on the AppKit grid lands on the still-SwiftUI
    /// sidebar rows / Spaces exactly as the SwiftUI `.draggable` did.
    nonisolated static let pasteboardType =
        NSPasteboard.PasteboardType(UTType.assetIDs.identifier)

    /// The wire bytes for this payload — plain `JSONEncoder`, which is precisely
    /// what SwiftUI's `CodableRepresentation(contentType:)` serializes (036 §4 A3).
    /// This IS the interop contract: `AssetDragPayloadTests` pins that these bytes
    /// decode back through the same `Codable` form the SwiftUI drop targets use, so
    /// a drift here silently breaks drag-to-rail and the test catches it.
    func pasteboardData() throws -> Data { try JSONEncoder().encode(self) }

    /// An `NSPasteboardItem` carrying this payload's JSON under `.pasteboardType`,
    /// for `NSDraggingItem(pasteboardWriter:)`. `nil` only if encoding fails (it
    /// cannot for this value type).
    func makePasteboardItem() -> NSPasteboardItem? {
        guard let data = try? pasteboardData() else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }

    /// Decode a payload from a drop's pasteboard bytes — the inverse of
    /// ``pasteboardData()``, used by the AppKit cell-drop delegate.
    static func decode(from data: Data) -> AssetDragPayload? {
        try? JSONDecoder().decode(AssetDragPayload.self, from: data)
    }

    /// Decode a payload directly off a pasteboard (059 · SP2) — the canvas
    /// ``NSDraggingDestination`` reads the drag pasteboard this way. Returns `nil`
    /// when the board carries no `.assetIDs` bytes (an external / foreign drop).
    static func decode(from pasteboard: NSPasteboard) -> AssetDragPayload? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return decode(from: data)
    }

    /// The sentinel "no source collection" id — a fixed, impossible collection id
    /// (all-zero; never produced by `UUID()`). Marks a MEMBERSHIP-LESS drag (library
    /// search results, a Space board): the drag has no collection to move OUT of, so
    /// a drop onto a collection can only COPY (add), never move (see ``routeDrop``).
    static let nilSourceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// A payload that marks a drag as INTERNAL without granting it any drop
    /// semantics: `routeDrop` rejects an empty asset list at every target, while
    /// the collection pane's import guard still sees the `.assetIDs` type and
    /// refuses to re-ingest the app's own file. Used by the detail hosts that
    /// have no collection context (library search, a Space board).
    static let internalMarker = AssetDragPayload(assetIDs: [], sourceCollectionID: nilSourceID)

    /// Read the payload straight off the system DRAG pasteboard, if the drag in
    /// flight carries one.
    ///
    /// This is the ONE reliable read for an AppKit-originated drag: when the
    /// dragging item is an `NSFilePromiseProvider` (every media drag since 011
    /// drag-out), SwiftUI's bridged `NSItemProvider` exposes NO type identifiers
    /// at all (proven by the 193 diagnostics — `registeredTypeIdentifiers == []`),
    /// so a provider-based read finds nothing even though the `.assetIDs` bytes
    /// sit right on the drag pasteboard. Outside a drag this returns `nil` (the
    /// drag pasteboard holds the LAST drag's leftovers only until the next one
    /// starts; a stale payload here is unreachable because `.onDrop` closures
    /// only run mid-drag).
    static func fromDragPasteboard() -> AssetDragPayload? {
        guard let data = NSPasteboard(name: .drag).data(forType: Self.pasteboardType) else {
            return nil
        }
        return decode(from: data)
    }

    /// The drop-target entry point shared by the sidebar space/collection rows:
    /// the drag pasteboard first (AppKit grid drags — promise-shaped or
    /// plain), then the provider bridge (a SwiftUI-native drag whose provider DOES
    /// carry `.assetIDs`). Returns whether a payload was found — the `.onDrop`
    /// accept result. `completion` runs on the main queue: synchronously for the
    /// pasteboard path, later for the async provider path.
    ///
    /// `@MainActor`, with a `@MainActor` completion: both callers are SwiftUI drop
    /// handlers, and the pasteboard branch below calls `completion` SYNCHRONOUSLY.
    /// Stating that isolation lets the async branch's hop be checked rather than
    /// assumed.
    @discardableResult
    @MainActor
    static func fromDrop(
        _ providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (AssetDragPayload) -> Void
    ) -> Bool {
        if let payload = fromDragPasteboard() {
            completion(payload)
            return true
        }
        return loadFirst(from: providers, completion: completion)
    }

    /// Load the first `AssetDragPayload` from a SwiftUI `.onDrop` provider list —
    /// the FALLBACK half of ``fromDrop(_:completion:)``, only useful for drags
    /// whose `NSItemProvider` actually registers `.assetIDs` (a SwiftUI-native
    /// drag source; an AppKit promise drag's bridged provider registers nothing).
    /// Item providers load asynchronously, so `completion` runs later on the main
    /// queue; the return value is whether a matching provider was present.
    @discardableResult
    /// `completion` is typed `@MainActor @Sendable` because that is where it already
    /// ran: the provider's load callback fires on an arbitrary queue and this hops to
    /// main before calling it. Writing the isolation into the TYPE lets the compiler
    /// check the hop instead of trusting the `DispatchQueue.main.async` below it.
    @MainActor
    static func loadFirst(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (AssetDragPayload) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.assetIDs.identifier)
        }) else { return false }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.assetIDs.identifier
        ) { data, _ in
            guard let data, let payload = decode(from: data) else { return }
            Task { @MainActor in completion(payload) }
        }
        return true
    }
}
