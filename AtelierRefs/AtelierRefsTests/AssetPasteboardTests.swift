//
//  AssetPasteboardTests.swift
//  AtelierRefsTests
//
//  052 · B1 (export Copy path) — 11A coverage for the ⌘C core: the kind-aware
//  entry builder + selection mapping are PURE (temp-file backed for the byte
//  kinds), and the writer is exercised against a NAMED SCRATCH `NSPasteboard`
//  (never `.general`) so the exact representations per kind are asserted without
//  touching the user's clipboard. Skips (missing blob / unknown) are counted, never
//  silent (7A). Order preservation is checked explicitly (grid / z order).
//

import AppKit
import AtelierArchive
import AtelierCore
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

// MARK: - Factories

private enum Fixture {

    static func asset(
        kind: AssetKind, blobHash: String? = nil, mime: String? = nil, payload: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash, mimeType: mime,
            width: 10, height: 10, duration: nil, fileSize: 10,
            downloadState: .downloaded, createdAt: Date(), sourceId: UUID(), payload: payload)
    }

    static func source(title: String? = nil) -> Source {
        Source(id: UUID(), platform: .web, title: title, capturedAt: Date())
    }

    // `jsonString()` is `String?`; these fixtures always encode a valid payload, so
    // force-unwrap keeps the call sites clean (a nil here is a real test-bug signal).
    static func colorPayload(_ hex: String) -> String {
        AssetPayload(color: ColorPayload(hex: hex)).jsonString()!
    }

    static func linkPayload(_ url: String) -> String {
        AssetPayload(link: LinkPayload(url: url)).jsonString()!
    }

    static func tweetPayload(id: String, handle: String?) -> String {
        AssetPayload(tweet: TweetPayload(tweetID: id, authorHandle: handle)).jsonString()!
    }

    /// A real on-disk **decodable** PNG (a blank 2×2), removed after `body`. Needed
    /// where the writer must actually decode an `NSImage` from the blob.
    static func withTempPNG(_ body: (URL) throws -> Void) rethrows {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try! png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// A named scratch pasteboard (never `.general`), cleared and released after use.
    static func withScratchPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pb = NSPasteboard(name: NSPasteboard.Name("atelier-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        try body(pb)
    }
}

// MARK: - pasteboardEntry (pure, kind-aware — 8A)

@Suite("AssetExport: pasteboardEntry")
struct AssetPasteboardEntryTests {

    @Test("a byte-backed image yields a .file entry reusing exportItem")
    func imageIsFile() throws {
        try Fixture.withTempPNG { url in
            let entry = AssetExport.pasteboardEntry(
                asset: Fixture.asset(kind: .image, blobHash: "abcdef1234"),
                source: Fixture.source(title: "Sunset"), blobURL: url)
            guard case let .file(item) = try #require(entry) else {
                Issue.record("expected .file, got \(String(describing: entry))"); return
            }
            #expect(item.blobURL == url)
            #expect(item.filename == "Sunset-abcdef12.png")
            #expect(item.utType == .png)
        }
    }

    @Test("a video reuses the same file path as an image")
    func videoIsFile() throws {
        try Fixture.withTempPNG { url in
            let entry = AssetExport.pasteboardEntry(
                asset: Fixture.asset(kind: .video, blobHash: "beefbeef99"),
                source: nil, blobURL: url)
            guard case .file = try #require(entry) else {
                Issue.record("expected .file"); return
            }
        }
    }

    // 052 · B1 regression (the "viktoroddy" tweet): a link/tweet whose IMAGE was
    // captured (og:image / card image) renders as an image card, so ⌘C must copy the
    // image FILE, not the URL text — otherwise a paste into Finder fails.

    @Test("a link with a captured og:image copies as the image file, not its URL")
    func linkWithImageIsFile() throws {
        try Fixture.withTempPNG { url in
            let entry = AssetExport.pasteboardEntry(
                asset: Fixture.asset(
                    kind: .link, blobHash: "0f1e2d3c",
                    payload: Fixture.linkPayload("https://example.com/a")),
                source: nil, blobURL: url)
            guard case .file = try #require(entry) else {
                Issue.record("expected .file for an image-backed link"); return
            }
        }
    }

    @Test("a tweet with a captured card image copies as the image file, not its permalink")
    func tweetWithCardImageIsFile() throws {
        try Fixture.withTempPNG { url in
            let entry = AssetExport.pasteboardEntry(
                asset: Fixture.asset(
                    kind: .tweet, blobHash: "2e7cb391",
                    payload: Fixture.tweetPayload(id: "123", handle: "@viktoroddy")),
                source: nil, blobURL: url)
            guard case .file = try #require(entry) else {
                Issue.record("expected .file for an image-backed tweet"); return
            }
        }
    }

    @Test("an image whose blob file is missing yields nil (skip, not empty file)")
    func imageMissingBlobIsNil() {
        let gone = URL(fileURLWithPath: "/tmp/atelier-does-not-exist-\(UUID().uuidString).png")
        #expect(AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .image, blobHash: "abc"),
            source: nil, blobURL: gone) == nil)
    }

    @Test("a color copies as its hex text")
    func colorIsHexText() {
        let entry = AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff8800")),
            source: nil, blobURL: nil)
        #expect(entry == .text("#ff8800"))
    }

    @Test("a link copies as its url text")
    func linkIsURLText() {
        let entry = AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .link, payload: Fixture.linkPayload("https://example.com/a")),
            source: nil, blobURL: nil)
        #expect(entry == .text("https://example.com/a"))
    }

    @Test("a tweet with a handle copies as a rebuilt permalink (@ stripped)")
    func tweetWithHandle() {
        let entry = AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .tweet, payload: Fixture.tweetPayload(id: "123", handle: "@jane")),
            source: nil, blobURL: nil)
        #expect(entry == .text("https://x.com/jane/status/123"))
    }

    @Test("a tweet with no handle falls back to the id-only permalink")
    func tweetNoHandle() {
        let entry = AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .tweet, payload: Fixture.tweetPayload(id: "456", handle: nil)),
            source: nil, blobURL: nil)
        #expect(entry == .text("https://x.com/i/status/456"))
    }

    @Test("an unknown asset (color kind, no payload) yields nil")
    func unknownIsNil() {
        #expect(AssetExport.pasteboardEntry(
            asset: Fixture.asset(kind: .color, payload: nil), source: nil, blobURL: nil) == nil)
    }
}

// MARK: - exportSelection (order + skip counting — 7A / 4A)

@Suite("AssetExport: exportSelection")
struct AssetExportSelectionTests {

    @Test("empty selection yields no entries and no skips")
    func empty() {
        let selection = AssetExport.exportSelection(assets: [], blobURL: { _ in nil })
        #expect(selection.entries.isEmpty)
        #expect(selection.skipped == 0)
        #expect(selection.considered == 0)
    }

    @Test("mixed kinds preserve selection order and count skips")
    func mixedOrderAndSkips() {
        // color, link, unknown(skip) — deterministic, no disk needed.
        let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#111111"))
        let link = Fixture.asset(kind: .link, payload: Fixture.linkPayload("https://b.example"))
        let unknown = Fixture.asset(kind: .color, payload: nil) // media-less, no payload → .unknown

        let selection = AssetExport.exportSelection(
            assets: [(color, nil), (link, nil), (unknown, nil)], blobURL: { _ in nil })

        #expect(selection.entries == [.text("#111111"), .text("https://b.example")])
        #expect(selection.skipped == 1)
        #expect(selection.considered == 3)
    }

    @Test("a missing-blob image is skipped while its neighbours copy")
    func missingBlobImageSkipped() {
        let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#abcdef"))
        let brokenImage = Fixture.asset(kind: .image, blobHash: "gone")
        let selection = AssetExport.exportSelection(
            assets: [(color, nil), (brokenImage, nil)],
            blobURL: { _ in URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).png") })
        #expect(selection.entries == [.text("#abcdef")])
        #expect(selection.skipped == 1)
    }
}

// MARK: - AssetPasteboardWriter (scratch board — 8A / 11A)

@Suite("AssetPasteboardWriter", .serialized)
struct AssetPasteboardWriterTests {

    @Test("a single image writes both a file URL and a decodable NSImage")
    func singleImageWritesURLAndImage() throws {
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                let selection = ExportSelection(entries: [.file(item(url))], skipped: 0)
                let written = AssetPasteboardWriter.write(selection, to: pb)
                #expect(written == 1)
                let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                #expect(urls.contains(url))
                #expect(pb.canReadObject(forClasses: [NSImage.self], options: nil))
            }
        }
    }

    @Test("multiple images write every file URL but no eager NSImage")
    func multipleImagesWriteURLsOnly() throws {
        Fixture.withTempPNG { a in
            Fixture.withTempPNG { b in
                Fixture.withScratchPasteboard { pb in
                    let selection = ExportSelection(
                        entries: [.file(item(a)), .file(item(b))], skipped: 0)
                    let written = AssetPasteboardWriter.write(selection, to: pb)
                    #expect(written == 2)
                    let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                    #expect(Set(urls) == Set([a, b]))
                    // Multi-select stays URL-only — no eager per-item decode.
                    #expect(!pb.canReadObject(forClasses: [NSImage.self], options: nil))
                }
            }
        }
    }

    @Test("a color entry writes its hex string")
    func textWritesString() throws {
        Fixture.withScratchPasteboard { pb in
            let selection = ExportSelection(entries: [.text("#ff0000")], skipped: 0)
            AssetPasteboardWriter.write(selection, to: pb)
            #expect(pb.string(forType: .string) == "#ff0000")
        }
    }

    @Test("a mixed file + text selection exposes both a URL and the string")
    func mixedWritesBoth() throws {
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                let selection = ExportSelection(
                    entries: [.file(item(url)), .text("https://x.example")], skipped: 0)
                AssetPasteboardWriter.write(selection, to: pb)
                let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                #expect(urls.contains(url))
                let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? []
                #expect(strings.contains("https://x.example"))
            }
        }
    }

    @Test("an empty selection clears the board and writes nothing")
    func emptyClears() throws {
        Fixture.withScratchPasteboard { pb in
            pb.clearContents()
            pb.setString("stale", forType: .string)
            let written = AssetPasteboardWriter.write(
                ExportSelection(entries: [], skipped: 0), to: pb)
            #expect(written == 0)
            #expect(pb.string(forType: .string) == nil)
        }
    }

    private func item(_ url: URL) -> AssetExportItem {
        AssetExportItem(blobURL: url, filename: url.lastPathComponent, utType: .png)
    }
}

// MARK: - The app-private second representation (019 · C1)
//
// ⌘C now writes TWO representations of one selection: the byte one above, and an
// `AssetDragPayload` so a ⌘V back into the app pastes the ASSET instead of
// re-importing its bytes. The invariants that matter are ORDER (the payload goes
// on AFTER `write`, which clears), PREFERENCE (the file URL stays what an external
// receiver picks), COVERAGE (the whole selection, including entries the byte pass
// skipped), and "nil, not empty" (an empty copy writes no payload at all).

@Suite("AssetPasteboardWriter: the .assetIDs representation (019)", .serialized)
struct AssetPasteboardPayloadTests {

    @Test("a copy carries BOTH the file URL and the app-private payload")
    func bothRepresentationsPresent() throws {
        try Fixture.withTempPNG { url in
            try Fixture.withScratchPasteboard { pb in
                let ids = [UUID(), UUID()]
                let source = UUID()
                let selection = ExportSelection(
                    entries: [.file(item(url)), .file(item(url))], skipped: 0)
                AssetPasteboardWriter.write(selection, to: pb)
                #expect(AssetPasteboardWriter.appendAssetIDs(ids, from: source, to: pb))

                // The byte representation an external app reads — untouched.
                let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                #expect(urls.contains(url))
                // …and ours, alongside it.
                let payload = try #require(AssetDragPayload.decode(from: pb))
                #expect(payload.assetIDs == ids)
                #expect(payload.sourceCollectionID == source)
            }
        }
    }

    @Test("the file URL stays the PREFERRED type for an external receiver")
    func fileURLRemainsPreferred() throws {
        try Fixture.withTempPNG { url in
            try Fixture.withScratchPasteboard { pb in
                AssetPasteboardWriter.write(
                    ExportSelection(entries: [.file(item(url))], skipped: 0), to: pb)
                AssetPasteboardWriter.appendAssetIDs([UUID()], from: UUID(), to: pb)

                // `.assetIDs` conforms to `public.data`, so a receiver that accepts
                // anything could match it — writing it LAST keeps the file URL ahead
                // of it in the board's declared type order.
                let types = try #require(pb.types)
                let fileURL = try #require(types.firstIndex(of: .fileURL))
                let assetIDs = try #require(types.firstIndex(of: AssetDragPayload.pasteboardType))
                #expect(fileURL < assetIDs)
            }
        }
    }

    @Test("a selection whose entries are ALL skipped still writes the payload")
    func allSkippedStillWritesPayload() throws {
        // A media-less `.unknown` plus a missing-blob image: nothing copyable, so the
        // byte pass writes zero entries — but pasting by id needs no bytes, so ⌘C→⌘V
        // starts working for items that cannot leave the app at all.
        try Fixture.withScratchPasteboard { pb in
            let ids = [UUID(), UUID()]
            let written = AssetPasteboardWriter.write(
                ExportSelection(entries: [], skipped: 2), to: pb)
            #expect(written == 0)
            #expect(AssetPasteboardWriter.appendAssetIDs(ids, from: UUID(), to: pb))
            let payload = try #require(AssetDragPayload.decode(from: pb))
            #expect(payload.assetIDs == ids)
        }
    }

    @Test("an EMPTY selection writes no payload at all (nil, not empty)")
    func emptySelectionWritesNothing() {
        Fixture.withScratchPasteboard { pb in
            AssetPasteboardWriter.write(ExportSelection(entries: [], skipped: 0), to: pb)
            #expect(!AssetPasteboardWriter.appendAssetIDs([], from: UUID(), to: pb))
            // Nothing on the board means a later ⌘V falls through to the importer
            // instead of matching a copy that carried no assets (065 §2.4).
            #expect(AssetDragPayload.decode(from: pb) == nil)
        }
    }

    @Test("the payload survives the clear because it is written AFTER the byte pass")
    func orderIsLoadBearing() throws {
        try Fixture.withTempPNG { url in
            try Fixture.withScratchPasteboard { pb in
                // The WRONG order, proven wrong: `write` clears, so a payload put on
                // first is gone by the time the URLs land.
                AssetPasteboardWriter.appendAssetIDs([UUID()], from: UUID(), to: pb)
                AssetPasteboardWriter.write(
                    ExportSelection(entries: [.file(item(url))], skipped: 0), to: pb)
                #expect(AssetDragPayload.decode(from: pb) == nil)

                // The order `copyToPasteboard` uses.
                let ids = [UUID()]
                AssetPasteboardWriter.write(
                    ExportSelection(entries: [.file(item(url))], skipped: 0), to: pb)
                AssetPasteboardWriter.appendAssetIDs(ids, from: UUID(), to: pb)
                let payload = try #require(AssetDragPayload.decode(from: pb))
                #expect(payload.assetIDs == ids)
            }
        }
    }

    private func item(_ url: URL) -> AssetExportItem {
        AssetExportItem(blobURL: url, filename: url.lastPathComponent, utType: .png)
    }
}

// MARK: - Paste dispatch (who the ⌘V belongs to, before the board is read)

/// The gate in FRONT of `resolvePaste`, added after a production report that the item
/// detail page's Name / Note fields could not be pasted into: the keystroke imported the
/// clipboard into the collection behind the page instead.
///
/// The cause is the precedence `SpaceView` documents as measured — a sibling
/// `keyboardShortcut` is dispatched BEFORE the event reaches the first responder — so
/// the grid's hidden ⌘V button answered for every text field in the window. Two rules
/// close it, and they are asserted here rather than only against a live window: the
/// binding is withdrawn while the page is up, and a ⌘V that still reaches the button
/// while a field editor holds the keyboard is handed back to the responder chain.
@Suite("Grid paste dispatch")
struct GridPasteDispatchTests {

    @Test("the binding is withdrawn while the detail page is up")
    func withdrawnOnDetailPage() {
        #expect(CollectionView.pasteShortcut(detailPresented: true) == nil)
    }

    @Test("…and carried on the grid")
    func boundOnGrid() {
        #expect(CollectionView.pasteShortcut(detailPresented: false)
                == KeyboardShortcut("v", modifiers: .command))
    }

    @Test("a focused field editor keeps its own ⌘V")
    func fieldEditorWins() {
        #expect(CollectionView.resolvePasteDispatch(fieldEditorFocused: true, isReady: true)
                == .fieldEditor)
    }

    @Test("the field editor is checked BEFORE readiness")
    func fieldEditorBeatsUnready() {
        // Typing in the search field is not the library's to gate: a ⌘V swallowed
        // because the model was still opening is the same bug in a narrower window.
        #expect(CollectionView.resolvePasteDispatch(fieldEditorFocused: true, isReady: false)
                == .fieldEditor)
    }

    @Test("with nobody typing, the collection takes it")
    func collectionOtherwise() {
        #expect(CollectionView.resolvePasteDispatch(fieldEditorFocused: false, isReady: true)
                == .collection)
    }

    @Test("an unopened library ignores the keystroke rather than importing")
    func unreadyIgnores() {
        #expect(CollectionView.resolvePasteDispatch(fieldEditorFocused: false, isReady: false)
                == .ignore)
    }
}

// MARK: - Paste routing (pure decode + branch, no DB — 019 · C2)

@Suite("Grid paste routing (019 · C2)")
struct GridPasteRoutingTests {

    private let target = UUID()

    @Test("our own payload WINS over a board that also carries file URLs")
    func payloadBeatsFileURLs() throws {
        try Fixture.withTempPNG { url in
            try Fixture.withScratchPasteboard { pb in
                // Exactly what ⌘C leaves behind: blob URLs AND the private payload.
                let ids = [UUID(), UUID()]
                let source = UUID()
                AssetPasteboardWriter.write(
                    ExportSelection(
                        entries: [.file(AssetExportItem(
                            blobURL: url, filename: url.lastPathComponent, utType: .png))],
                        skipped: 0),
                    to: pb)
                AssetPasteboardWriter.appendAssetIDs(ids, from: source, to: pb)

                #expect(CollectionView.resolvePaste(
                    payload: AssetDragPayload.decode(from: pb), target: target)
                        == .add(assetIDs: ids, source: source))
            }
        }
    }

    @Test("a Finder-copied file still takes the import branch")
    func finderFileImports() {
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                pb.clearContents()
                pb.writeObjects([url as NSURL])
                #expect(CollectionView.resolvePaste(
                    payload: AssetDragPayload.decode(from: pb), target: target)
                        == .importExternal)
            }
        }
    }

    @Test("an ABSENT payload cannot stop the chain")
    func absentPayloadFallsThrough() {
        #expect(CollectionView.resolvePaste(payload: nil, target: target) == .importExternal)
    }

    @Test("an EMPTY payload cannot stop the chain either (the internal marker)")
    func emptyPayloadFallsThrough() {
        #expect(CollectionView.resolvePaste(payload: .internalMarker, target: target)
                == .importExternal)
        #expect(CollectionView.resolvePaste(
            payload: AssetDragPayload(assetIDs: [], sourceCollectionID: target), target: target)
                == .importExternal)
    }

    @Test("pasting back into the collection it was copied from is a no-op with a notice")
    func sameCollectionIsNoop() {
        #expect(CollectionView.resolvePaste(
            payload: AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: target),
            target: target)
                == .alreadyMembers)
    }

    @Test("a membership-less copy (search / a board) always reads as an add")
    func nilSourceIsAlwaysAnAdd() {
        let ids = [UUID()]
        #expect(CollectionView.resolvePaste(
            payload: AssetDragPayload(
                assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID),
            target: target)
                == .add(assetIDs: ids, source: nil))
        // The sentinel is the all-zero UUID, which `UUID()` never produces — so a
        // membership-less copy can never accidentally read as a same-collection
        // paste into a real target.
        #expect(AssetDragPayload.nilSourceID != target)
    }
}
