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

    // MARK: - Picker

    @Test("Nothing shareable yields NO picker rather than an empty sheet")
    @MainActor
    func emptyYieldsNoPicker() {
        #expect(AssetShare.picker(for: selection([])) == nil)
    }

    @Test("A shareable selection yields a picker over the whole payload")
    @MainActor
    func pickerCoversPayload() {
        let picker = AssetShare.picker(for: selection([
            fileEntry("/tmp/hero.png", "hero.png"),
            .text("#112233"),
        ]))
        #expect(picker != nil)
    }

    // MARK: - The cheap predicate (011 · A3 review)

    /// A byte-backed asset — the overwhelmingly common case, and the one that must
    /// be answered from `blobHash` alone.
    private func asset(kind: AssetKind, blobHash: String?, payload: String? = nil) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash,
            mimeType: "image/png", width: 10, height: 10, duration: nil,
            fileSize: 10, downloadState: .downloaded, createdAt: Date(),
            name: nil, sourceId: UUID(), payload: payload)
    }

    @Test("Anything with bytes is shareable, decided from blobHash alone")
    func bytesAreShareable() {
        #expect(AssetShare.canShare(asset(kind: .image, blobHash: "abcdef1234567890")))
        #expect(AssetShare.canShare(asset(kind: .video, blobHash: "abcdef1234567890")))
    }

    @Test("A byte-less ref is shareable when its kind has text to offer")
    func byteLessKindsFallBackToText() {
        let colour = asset(
            kind: .color, blobHash: nil,
            payload: AssetPayload(color: ColorPayload(hex: "#112233")).jsonString())
        #expect(AssetShare.canShare(colour))
    }

    @Test("A byte-less ref with no text at all is not shareable")
    func nothingToShare() {
        // An `.image` with no blob resolves to `AssetContent.unknown` — no bytes and
        // no words. So does a media-less kind whose payload never arrived, which is
        // the corrupt-row case rather than a legitimate one.
        #expect(!AssetShare.canShare(asset(kind: .image, blobHash: nil)))
        #expect(!AssetShare.canShare(asset(kind: .video, blobHash: nil)))
        #expect(!AssetShare.canShare(asset(kind: .link, blobHash: nil, payload: nil)))
        #expect(!AssetShare.canShare(asset(kind: .color, blobHash: nil, payload: nil)))
    }

    @Test("The cheap predicate never consults the filesystem")
    func cheapPredicateIgnoresDisk() {
        // A hash that could not possibly have a file on disk still answers `true`:
        // the whole point is that the menu does not pay for a `stat` per asset. The
        // documented consequence is that a fully-reaped selection can offer Share
        // and then have nothing to hand over.
        #expect(AssetShare.canShare(asset(kind: .image, blobHash: "0000000000000000")))
    }
}
