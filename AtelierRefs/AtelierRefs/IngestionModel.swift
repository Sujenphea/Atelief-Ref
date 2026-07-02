//
//  IngestionModel.swift
//  AtelierRefs
//
//  Chunk 5 — the app-side model that wires the DirectInputReader + coordinator to
//  the real on-disk Library. It opens (or creates) the Library under Application
//  Support, ensures a default "Inbox" collection exists, holds an
//  `IngestCoordinator`, and runs batches off-main, publishing the ingested
//  results (asset id + a loaded thumbnail) and progress for the demo view.
//

import AppKit
import AtelierCore
import AtelierIngestion
import Combine
import SwiftUI

/// The `@MainActor` view model behind ``ImportView``: it owns the Library
/// (`MediaStore` + `AppServices` + `IngestCoordinator`), ensures a default
/// collection, and drives ingestion batches, publishing thumbnails + progress.
@MainActor
final class IngestionModel: ObservableObject {

    /// One successfully ingested item, ready to show in the demo grid.
    struct IngestedItem: Identifiable {
        /// The resolved asset's id (stable identity).
        let id: UUID
        /// The smallest available thumbnail, loaded from the `MediaStore`.
        let thumbnail: NSImage
        /// `true` when the 18A dedup rule reused an existing asset.
        let deduplicated: Bool
    }

    /// Ingested items, newest first (published to the grid).
    @Published private(set) var items: [IngestedItem] = []
    /// The in-flight batch's `(completed, total)`, or `nil` when idle.
    @Published private(set) var progress: Progress?
    /// A human-readable error / status line for the demo, or `nil`.
    @Published private(set) var status: String?
    /// `false` until the Library has opened — the drop target / paste button are
    /// disabled meanwhile.
    @Published private(set) var isReady = false

    /// A batch's progress counters.
    struct Progress: Equatable {
        var completed: Int
        var total: Int
    }

    // The Library, populated once `bootstrap()` completes.
    private var store: MediaStore?
    private var coordinator: IngestCoordinator?
    /// The collection ingested items are added to (the default "Inbox").
    private(set) var collectionID: UUID?

    init() {
        Task { await bootstrap() }
    }

    /// Open (or create) the Library under Application Support, ensure a default
    /// collection, and wire the pipeline + coordinator. Sets ``isReady`` on
    /// success; records a status line on failure.
    private func bootstrap() async {
        do {
            let root = try LibraryLocation.defaultRoot()
            let layout = LibraryLayout(root: root)
            let store = MediaStore(layout: layout)
            let dbPath = layout.root.appendingPathComponent("library.sqlite").path
            let services = try AppServices(databasePath: dbPath)

            // Ensure a default collection exists (create "Inbox" if the library
            // is brand new).
            let existing = try await services.listCollections()
            let collection: Collection
            if let first = existing.first {
                collection = first
            } else {
                collection = try await services.createCollection(name: "Inbox")
            }

            let pipeline = IngestPipeline(store: store, services: services)
            self.store = store
            self.coordinator = IngestCoordinator(pipeline: pipeline)
            self.collectionID = collection.id
            self.isReady = true
            self.status = "Library ready — paste an image or drop a file."
        } catch {
            self.status = "Failed to open library: \(error)"
        }
    }

    /// Run a batch of inputs through the coordinator OFF-MAIN, then publish the
    /// ingested thumbnails + progress. A no-op if the Library isn't ready or the
    /// batch is empty.
    func run(inputs: [IngestInput]) {
        guard isReady, let coordinator, let store, !inputs.isEmpty else { return }
        let total = inputs.count
        progress = Progress(completed: 0, total: total)
        status = "Importing \(total)…"

        Task {
            // The coordinator is an actor, so `ingest` runs off the main actor.
            let outcomes = await coordinator.ingest(inputs) { completed, total in
                Task { @MainActor [weak self] in
                    self?.progress = Progress(completed: completed, total: total)
                }
            }

            // Fold outcomes into grid items (loading each thumbnail from the
            // store) + a failure count.
            var appended: [IngestedItem] = []
            var failures = 0
            for outcome in outcomes {
                switch outcome {
                case .ingested(let asset, let deduplicated):
                    appended.append(IngestedItem(
                        id: asset.id,
                        thumbnail: Self.thumbnail(for: asset, store: store),
                        deduplicated: deduplicated))
                case .failed:
                    failures += 1
                }
            }

            items.insert(contentsOf: appended, at: 0)
            progress = nil
            status = failures == 0
                ? "Imported \(appended.count)."
                : "Imported \(appended.count), \(failures) failed."
        }
    }

    /// Load the smallest available thumbnail tier for `asset` from the store,
    /// falling back to larger tiers, then to a 1×1 placeholder if none decode.
    private static func thumbnail(for asset: Asset, store: MediaStore) -> NSImage {
        for tier in ThumbnailTier.allCases {
            if let data = try? store.readThumbnail(
                hash: asset.blobHash, size: tier.rawValue, fileExtension: "jpg"),
               let image = NSImage(data: data) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 1, height: 1))
    }
}
