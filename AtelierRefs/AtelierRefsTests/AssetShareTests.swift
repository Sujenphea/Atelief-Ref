//
//  AssetShareTests.swift
//  AtelierRefsTests
//
//  011 · A3 — the share payload mapping. The whole point of this layer is that it
//  adds no new decisions: `AssetExport.exportSelection` already decided what a
//  selection contains (and is tested in `AssetPasteboardTests`), so what is
//  checked here is the handoff to AppKit — originals go as file URLs, byte-less
//  refs as text, order survives, and multi-select shares N things rather than the
//  first one.
//

import AppKit
import AtelierCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

@Suite("Share sheet: payload mapping")
struct AssetShareTests {

    // MARK: - Fixtures

    private func fileEntry(_ path: String, _ name: String) -> AssetPasteboardEntry {
        .file(AssetExportItem(
            blobURL: URL(fileURLWithPath: path), filename: name, utType: .png))
    }

    private func selection(
        _ entries: [AssetPasteboardEntry], skipped: Int = 0
    ) -> ExportSelection {
        ExportSelection(entries: entries, skipped: skipped)
    }

    // MARK: - Mapping

    @Test("An original shares as its on-disk file URL")
    func fileSharesAsURL() {
        let items = AssetShare.items(
            for: selection([fileEntry("/tmp/hero.png", "hero-ab12cd34.png")]))

        #expect(items.count == 1)
        #expect((items[0] as? URL) == URL(fileURLWithPath: "/tmp/hero.png"))
    }

    @Test("A byte-less ref shares as the text ⌘C would have written")
    func textSharesAsString() {
        let items = AssetShare.items(for: selection([.text("#112233")]))

        #expect(items.count == 1)
        #expect((items[0] as? String) == "#112233")
    }

    @Test("A mixed selection keeps both kinds, in selection order")
    func mixedKeepsOrder() {
        let items = AssetShare.items(for: selection([
            fileEntry("/tmp/a.png", "a.png"),
            .text("https://example.com/post"),
            fileEntry("/tmp/b.png", "b.png"),
        ]))

        #expect(items.count == 3)
        #expect((items[0] as? URL) == URL(fileURLWithPath: "/tmp/a.png"))
        #expect((items[1] as? String) == "https://example.com/post")
        #expect((items[2] as? URL) == URL(fileURLWithPath: "/tmp/b.png"))
    }

    @Test("Multi-select shares every ref, not just the first")
    func multiSelectSharesAll() {
        let entries = (0..<12).map { fileEntry("/tmp/ref-\($0).png", "ref-\($0).png") }
        #expect(AssetShare.items(for: selection(entries)).count == 12)
    }

    @Test("Skips do not become share items — they were never shareable")
    func skipsAreNotShared() {
        let items = AssetShare.items(
            for: selection([fileEntry("/tmp/a.png", "a.png")], skipped: 4))
        #expect(items.count == 1)
    }

    @Test("An empty selection maps to an empty payload")
    func emptySelection() {
        #expect(AssetShare.items(for: selection([])).isEmpty)
    }

    // MARK: - Menu item

    @Test("Nothing shareable yields NO menu item rather than a dead one")
    @MainActor
    func emptyYieldsNoMenuItem() {
        #expect(AssetShare.menuItem(for: selection([])) == nil)
    }

    @Test("A shareable selection yields an item that owns its picker")
    @MainActor
    func menuItemRetainsPicker() {
        let item = AssetShare.menuItem(
            for: selection([fileEntry("/tmp/hero.png", "hero.png")]))

        #expect(item != nil)
        // The picker populates the submenu lazily, so the item must keep it alive
        // past the builder's return — see `AssetShare.menuItem`.
        #expect(item?.representedObject is NSSharingServicePicker)
    }
}
