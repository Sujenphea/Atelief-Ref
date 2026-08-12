//
//  AssetTagsStoreSuggestionsTests.swift
//  AtelierRefsTests
//
//  012 · I3 — the suggestion half of the shared per-asset tag store. The funnel
//  itself is covered by `ServicesSuggestionsTests`; what has no coverage
//  elsewhere is the STORE's routing, and specifically that one ✕ means two
//  different things: deleting a tag the user wrote, refusing one a machine
//  proposed. A store that sent both down `removeTag` would look correct in the UI
//  and lose the refusal — the failure only shows up an idle pass later.
//
//  The store's mutators are fire-and-forget (`Task {}`), so assertions poll the
//  `@Published` state through `waitUntil` rather than racing the write.
//

import AtelierCore
import Combine
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("AssetTagsStore: suggestions (012 · I3)")
struct AssetTagsStoreSuggestionsTests {

    private func makeServices() throws -> AppServices {
        let dbPath = NSTemporaryDirectory() + "tagstore-suggestions-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: dbPath)
    }

    /// Ingest one media-less color into `collectionID` and return its id.
    private func seedColor(into collectionID: UUID, _ services: AppServices) async throws -> UUID {
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        let hex = "#\(String(UUID().uuidString.prefix(6)))"
        return try await services.ingestContent(.color(hex: hex), from: source, into: collectionID).asset.id
    }

    private func waitUntil(
        _ label: String, _ cond: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitUntil timed out: \(label)")
    }

    /// A bound store over an asset already carrying one `.agent` "poster".
    private func boundStoreWithSuggestion() async throws -> (AppServices, UUID, AssetTagsStore) {
        let services = try makeServices()
        let collection = try await services.createCollection(name: "Refs")
        let assetID = try await seedColor(into: collection.id, services)
        _ = try await services.applyTag("poster", to: assetID, source: .agent)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("the suggestion loads") { store.tags.contains { $0.source == .agent } }
        return (services, assetID, store)
    }

    @Test("accept turns the suggestion into the user's own tag")
    func acceptPromotes() async throws {
        let (_, _, store) = try await boundStoreWithSuggestion()
        let suggestion = try #require(store.tags.first { $0.source == .agent })

        store.accept(suggestion)
        try await waitUntil("the chip becomes a user tag") {
            store.tags.map(\.source) == [.user]
        }
        #expect(store.tags.map(\.name) == ["poster"])
    }

    @Test("dismissing a suggestion records the refusal, not just a removal")
    func dismissSuppresses() async throws {
        let (services, assetID, store) = try await boundStoreWithSuggestion()
        let suggestion = try #require(store.tags.first { $0.source == .agent })

        store.remove(suggestion)
        try await waitUntil("the chip goes") { store.tags.isEmpty }

        // The half a plain removeTag would have missed.
        #expect(try await services.suppressedTagNames(for: assetID) == ["poster"])
    }

    @Test("removing a user tag is a deletion, and remembers nothing")
    func userRemoveDoesNotSuppress() async throws {
        let services = try makeServices()
        let collection = try await services.createCollection(name: "Refs")
        let assetID = try await seedColor(into: collection.id, services)
        _ = try await services.applyTag("brutalist", to: assetID, source: .user)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("the tag loads") { !store.tags.isEmpty }

        store.remove(try #require(store.tags.first))
        try await waitUntil("the tag goes") { store.tags.isEmpty }

        // Nothing is remembered: the user may apply their own label again
        // tomorrow, and no suggester is involved.
        #expect(try await services.suppressedTagNames(for: assetID).isEmpty)
    }

    @Test("accept is inert on a tag the user already owns")
    func acceptIgnoresUserTags() async throws {
        let services = try makeServices()
        let collection = try await services.createCollection(name: "Refs")
        let assetID = try await seedColor(into: collection.id, services)
        _ = try await services.applyTag("brutalist", to: assetID, source: .user)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("the tag loads") { !store.tags.isEmpty }

        store.accept(try #require(store.tags.first))
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.tags.map(\.name) == ["brutalist"])
        #expect(store.tags.map(\.source) == [.user])
        #expect(store.lastError == nil)
    }
}
