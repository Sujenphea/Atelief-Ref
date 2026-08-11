//
//  AssetTagsStoreColorsTests.swift
//  AtelierRefsTests
//
//  085 · C2 — the detail page's color row, at the seam where the stored swatch
//  JSON becomes chips.
//
//  The palette arithmetic is `ColorPaletteTests`' job and the search predicate is
//  `ServicesColorTests`'. What is only testable HERE is the load: that binding an
//  asset surfaces its colors, that re-binding does not leave the previous asset's
//  colors on screen, and that the three ways an asset can have no colors all read
//  as "no section" rather than as an error.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("AssetTagsStore: colors (085 · C2)")
struct AssetTagsStoreColorsTests {

    private func makeServices() throws -> AppServices {
        let dbPath = NSTemporaryDirectory() + "tagstore-colors-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: dbPath)
    }

    private func seedColor(into collectionID: UUID, _ services: AppServices) async throws -> UUID {
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        let hex = "#\(String(UUID().uuidString.prefix(6)))"
        return try await services.ingestContent(
            .color(hex: hex), from: source, into: collectionID).asset.id
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

    // MARK: - Loading

    @Test("bind surfaces the asset's merged palette, most dominant first")
    func bindLoadsColors() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)
        // Two reds and a green: the reds merge to 0.5 and tie with the green, and
        // red(3) < green(7) breaks the tie — the same rule the chips are drawn by.
        try await services.upsertAnalysis(assetID: asset, colors: ##"""
            [{"hex":"#ff0000","coverage":0.3},
             {"hex":"#e02020","coverage":0.2},
             {"hex":"#00ff00","coverage":0.5}]
            """##, analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        try await waitUntil("colors load") { !store.colors.isEmpty }

        #expect(store.colors.map(\.bucket) == [.red, .green])
        #expect(abs(store.colors[0].coverage - 0.5) < 1e-9)
    }

    /// The chip is painted with the IMAGE's color, not the palette's — the whole
    /// reason the row reads `asset_analysis.colors` rather than the `asset_color`
    /// rows, which only carry the bucket integer.
    @Test("the chip's hex is the image's swatch, not the palette anchor")
    func representativeHexIsTheImages() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)
        try await services.upsertAnalysis(
            assetID: asset, colors: ##"[{"hex":"#b76e79","coverage":0.8}]"##,
            analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        try await waitUntil("colors load") { !store.colors.isEmpty }

        #expect(store.colors.first?.bucket == .pink)
        #expect(store.colors.first?.representativeHex == "#b76e79")
        #expect(store.colors.first?.representativeHex != ColorBucket.pink.referenceHex)
    }

    // MARK: - The three ways to have no colors

    @Test("an un-analyzed asset has no colors")
    func unanalyzedIsEmpty() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        // Nothing to wait FOR, so wait for a sibling load to prove the refresh ran.
        try await waitUntil("refresh ran") { !store.allCollections.isEmpty }
        #expect(store.colors.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test("analysis with no palette has no colors")
    func nilPaletteIsEmpty() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)
        try await services.upsertAnalysis(assetID: asset, ocrText: "words", analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        try await waitUntil("refresh ran") { !store.allCollections.isEmpty }
        #expect(store.colors.isEmpty)
        #expect(store.lastError == nil)
    }

    /// An unreadable palette must read as "no colors", not as an error banner. The
    /// distinction matters to the derivation pass; to someone looking at a picture
    /// it is noise.
    @Test("an unreadable palette is empty, not an error")
    func badJSONIsEmptyNotAnError() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)
        try await services.upsertAnalysis(assetID: asset, colors: "not json", analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        try await waitUntil("refresh ran") { !store.allCollections.isEmpty }
        #expect(store.colors.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - Re-binding

    /// Prev/next re-binds the store. A stale palette left on screen would label the
    /// NEW picture with the OLD one's colors — and clicking a chip would then filter
    /// by a color that is not in the image being looked at.
    @Test("re-binding replaces the previous asset's colors")
    func rebindReplacesColors() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let red = try await seedColor(into: refs.id, services)
        let green = try await seedColor(into: refs.id, services)
        try await services.upsertAnalysis(
            assetID: red, colors: ##"[{"hex":"#ff0000","coverage":0.9}]"##, analyzerVersion: 1)
        try await services.upsertAnalysis(
            assetID: green, colors: ##"[{"hex":"#00ff00","coverage":0.9}]"##, analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: red)
        try await waitUntil("red loads") { store.colors.first?.bucket == .red }

        store.bind(to: green)
        // Cleared SYNCHRONOUSLY by bind, before the async load lands — the row must
        // never show the previous item's colors, not even for a frame.
        #expect(store.colors.isEmpty)
        try await waitUntil("green loads") { store.colors.first?.bucket == .green }
        #expect(store.colors.map(\.bucket) == [.green])
    }

    @Test("unbinding clears the colors")
    func unbindClearsColors() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColor(into: refs.id, services)
        try await services.upsertAnalysis(
            assetID: asset, colors: ##"[{"hex":"#ff0000","coverage":0.9}]"##, analyzerVersion: 1)

        let store = AssetTagsStore(services: services)
        store.bind(to: asset)
        try await waitUntil("colors load") { !store.colors.isEmpty }

        store.bind(to: nil)
        #expect(store.colors.isEmpty)
    }
}
