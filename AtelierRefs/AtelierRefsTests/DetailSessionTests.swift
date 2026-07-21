//
//  DetailSessionTests.swift
//  AtelierRefsTests
//
//  036 §3 B1 — the item-detail overlay's state, extracted off `IngestionModel`
//  into `DetailSession`. These guard the three properties the refactor is about:
//   1. `present()` is ONE publish — not the 3–4 god-object `@Published` writes it
//      replaces (each of which re-ran the whole screen).
//   2. `step()` (prev/next) mutates ONLY the session — the model's lead/selection
//      is untouched until close, so the grid never re-renders per step.
//   3. Close syncs the lead back to the model once, to wherever the user stepped.
//
//  Tests 2–3 build a REAL `IngestionModel` over a temp `AppServices` (the
//  `GridSelectionStoreTests` harness) so the model-side invariants are asserted
//  against the true selection store, not a mock.
//
//  `@Published` fires on `willSet`; the publish-count test sinks on `$state` and
//  counts the sink's invocations (not a re-read of the stored value) — the trap
//  A0 (`38dff33`) documented.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("DetailSession (036 §3 B1)")
struct DetailSessionTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "ingest-detail-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Seed `count` media-less color assets (no `blobHash`, so the session's
    /// preview URL is `nil` and `present()` fires no async second publish — a clean
    /// single-publish assertion). Mirrors `GridSelectionStoreTests.seedColors`.
    private func seedColors(_ count: Int, into collectionID: UUID, _ services: AppServices) async throws -> [UUID] {
        var ids: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for i in 0..<count {
            let hex = String(format: "#%02x%02x%02x", (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            let result = try await services.ingestContent(.color(hex: hex), from: source, into: collectionID)
            ids.append(result.asset.id)
        }
        return ids
    }

    private func items(in collectionID: UUID, _ services: AppServices) async throws -> [CollectionItemDetail] {
        try await services.collectionItems(in: collectionID)
    }

    // MARK: - present() is one publish

    /// The core win: today opening the detail page fires 3–4 separate `@Published`
    /// writes on `IngestionModel`; `present()` must be exactly ONE `state` publish
    /// (the preview arrives as a later, separate publish — none here, since a
    /// media-less asset has no thumbnail).
    @Test("present() publishes state exactly once")
    func presentIsOnePublish() async throws {
        let (_, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(2, into: folder.id, services)
        let feed = try await items(in: folder.id, services)

        let session = DetailSession(
            tags: AssetTagsStore(services: services), previewURL: { _ in nil })

        var publishes = 0
        // dropFirst() discards `@Published`'s emit-on-subscribe of the current nil.
        let cancellable = session.$state.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        session.present(feed[0])

        #expect(publishes == 1)
        #expect(session.currentID == feed[0].item.id)
    }

    // MARK: - step() touches only the session

    /// Prev/next mutates ONLY the session; the model's lead (its grid cursor) stays
    /// where the open left it. If stepping wrote the model lead — as the deleted
    /// `openItem` did on every step — the grid would re-render per step.
    @Test("step() moves the session lead but not the model's")
    func stepDoesNotTouchModel() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(3, into: folder.id, services)
        let feed = try await items(in: folder.id, services)
        model.setItemsForTesting(feed)

        let session = DetailSession(
            tags: AssetTagsStore(services: services), previewURL: { _ in nil })

        // Open item 0 (what `CollectionView.open` does: lead on the model + present).
        model.applySelection(.setLead(feed[0].item.id))
        session.present(feed[0])
        #expect(model.selection.lead == feed[0].item.id)
        #expect(session.currentID == feed[0].item.id)

        // Step to item 2 through the session only.
        session.step(to: feed[2])
        #expect(session.currentID == feed[2].item.id)
        // The model lead is UNTOUCHED — still item 0.
        #expect(model.selection.lead == feed[0].item.id)
        // And the selection set never grew from a step.
        #expect(model.selection.ids.isEmpty)
    }

    // MARK: - close syncs the lead once

    /// On close the model lead is synced ONCE to wherever the user stepped — via
    /// the new `.setLead` reducer action — so the grid cursor / next-open / ring
    /// land on the last-viewed item (parity with the old per-step `setLead`).
    @Test("close syncs the model lead to the final stepped item")
    func closeSyncsLead() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(3, into: folder.id, services)
        let feed = try await items(in: folder.id, services)
        model.setItemsForTesting(feed)

        model.applySelection(.setLead(feed[0].item.id))
        let session = DetailSession(
            tags: AssetTagsStore(services: services), previewURL: { _ in nil })
        session.present(feed[0])
        session.step(to: feed[2])

        // Close: sync the model lead to the session's current item.
        model.applySelection(.setLead(session.currentID!))
        #expect(model.selection.lead == feed[2].item.id)
        #expect(model.leadItem?.item.id == feed[2].item.id)

        session.dismiss()
        #expect(session.currentID == nil)  // dismissed → no state
    }

    // MARK: - the .setLead reducer action

    /// `.setLead` moves the cursor without disturbing the selection set, and asks
    /// the view to scroll it into view (like an arrow move) — the close-sync seam.
    @Test(".setLead sets the lead, keeps ids, returns scrollTo")
    func setLeadReducer() {
        let a = UUID(), b = UUID(), c = UUID()
        var selection = GridSelection(ids: [a], anchor: a, lead: a)
        let (next, effect) = selection.applying(.setLead(c), order: [a, b, c])
        #expect(next.lead == c)
        #expect(next.ids == [a])          // selection set untouched
        #expect(effect == .scrollTo(c))
        selection = next
        // An unchanged lead through the store guard must not publish (asserted via
        // equality here — the store's `apply` compares before assigning).
        let (again, _) = selection.applying(.setLead(c), order: [a, b, c])
        #expect(again == selection)
    }
}
