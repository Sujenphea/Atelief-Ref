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

    @Test("a board copy of ELEMENTS ONLY is refused, not imported (464)")
    func boardElementsAreRefused() {
        // The board writes no asset payload for a text-box-only copy, so without
        // the flag this falls to the importer — which would read the words beside
        // it and capture a text box reading `https://…` as a fresh link.
        #expect(CollectionView.resolvePaste(
            payload: nil, target: target, hasBoardElements: true) == .nothing)
        #expect(CollectionView.resolvePaste(
            payload: .internalMarker, target: target, hasBoardElements: true) == .nothing)
    }

    @Test("a MIXED board copy still adds its assets — the flag never reaches it")
    func boardElementsBesideAssetsStillAdd() {
        let ids = [UUID()]
        #expect(CollectionView.resolvePaste(
            payload: AssetDragPayload(
                assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID),
            target: target, hasBoardElements: true)
                == .add(assetIDs: ids, source: nil))
    }

    @Test("without board elements the guard is exactly what it was")
    func noBoardElementsUnchanged() {
        #expect(CollectionView.resolvePaste(
            payload: nil, target: target, hasBoardElements: false) == .importExternal)
    }
}

// MARK: - The plain-text flavour (464)
//
// ⌘C's third representation: the WORDS. Media are cut out of it — an image
// contributes nothing rather than its file path — and every piece lands on ONE
// pasteboard item, because a receiver reads item 0 and stops.

@Suite("CopyText")
struct CopyTextTests {

    @Test("pieces join in the order given, separated by a blank line")
    func joinsInOrder() {
        #expect(CopyText.joined(["one", "two", "three"]) == "one\n\ntwo\n\nthree")
    }

    @Test("each piece is trimmed and the empty ones drop out")
    func trimsAndDrops() {
        #expect(CopyText.joined(["  hi  ", nil, "", "   ", "\n there \n"]) == "hi\n\nthere")
    }

    @Test("nothing survivable is nil, never an empty string (065 §2.4)")
    func nothingIsNil() {
        #expect(CopyText.joined([]) == nil)
        #expect(CopyText.joined([nil, "", "   "]) == nil)
    }

    @Test("a single piece is itself — no separator, no decoration")
    func singlePiece() {
        #expect(CopyText.joined([nil, "just this"]) == "just this")
    }

    @Test("a file item carries no words of its own — media is cut out for free")
    func fileItemHasNoString() {
        // The measurement the design rests on: an `NSURL` on a pasteboard declares
        // `public.file-url` and nothing else, so a copied picture contributes no
        // string and a text field never pastes a blob path.
        Fixture.withScratchPasteboard { pb in
            pb.clearContents()
            pb.writeObjects([URL(fileURLWithPath: "/tmp/blob-ab12.png") as NSURL])
            #expect(pb.string(forType: .string) == nil)
        }
    }

    @Test("the pasteboard concatenates N string items with a \\n of its own")
    func pasteboardConcatenatesItems() {
        // Why the pieces are joined HERE instead of written as one item each: left
        // to the pasteboard, a copy of three colours reads with a separator this
        // code never chose. Asserted so the day AppKit changes it is a red test,
        // not a silently different paste.
        Fixture.withScratchPasteboard { pb in
            pb.clearContents()
            pb.writeObjects(["a" as NSString, "b" as NSString])
            #expect(pb.string(forType: .string) == "a\nb")
        }
    }
}

// MARK: - The writer's own plain-text join (464)

@Suite("AssetPasteboardWriter: the plain-text flavour (464)", .serialized)
struct AssetPasteboardWriterTextTests {

    @Test("EVERY text entry pastes, as ONE item with OUR separator")
    func allTextEntriesJoin() {
        // Three colours used to go on as three string items, and the pasteboard
        // then read them back joined by a `\n` this code never chose.
        Fixture.withScratchPasteboard { pb in
            let selection = ExportSelection(
                entries: [.text("#ff0000"), .text("#00ff00"), .text("#0000ff")], skipped: 0)
            #expect(AssetPasteboardWriter.write(selection, to: pb) == 3)
            #expect(pb.string(forType: .string) == "#ff0000\n\n#00ff00\n\n#0000ff")
            let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? []
            #expect(strings == ["#ff0000\n\n#00ff00\n\n#0000ff"])
        }
    }

    @Test("a mixed copy pastes the WORDS as text and the FILE as a file")
    func mediaIsCutOutOfTheText() {
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                let selection = ExportSelection(
                    entries: [
                        .file(AssetExportItem(
                            blobURL: url, filename: url.lastPathComponent, utType: .png)),
                        .text("https://x.example"),
                    ],
                    skipped: 0)
                AssetPasteboardWriter.write(selection, to: pb)
                // The words only — the picture contributes none.
                #expect(pb.string(forType: .string) == "https://x.example")
                // …and the file is untouched: Finder and Preview see what they saw.
                let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                #expect(urls.contains(url))
            }
        }
    }

    @Test("a media-only copy puts no string on the board at all")
    func mediaOnlyWritesNoWords() {
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                let selection = ExportSelection(
                    entries: [.file(AssetExportItem(
                        blobURL: url, filename: url.lastPathComponent, utType: .png))],
                    skipped: 0)
                AssetPasteboardWriter.write(selection, to: pb)
                #expect(pb.string(forType: .string) == nil)
            }
        }
    }

    @Test("a caller's own words REPLACE the ones the selection would have derived")
    func callerTextOverrides() {
        // The board's case: its text boxes are not assets, so it hands over the
        // whole selection's words — interleaved in ITS order — and the derivation
        // from the assets alone must not also go on.
        Fixture.withScratchPasteboard { pb in
            let selection = ExportSelection(entries: [.text("#ff0000")], skipped: 0)
            AssetPasteboardWriter.write(
                selection, to: pb, text: "a note\n\n#ff0000\n\nanother note")
            #expect(pb.string(forType: .string) == "a note\n\n#ff0000\n\nanother note")
        }
    }

    @Test("words with NO entries is still a copy — the board's text-only ⌘C")
    func wordsWithoutEntriesStillWrite() {
        Fixture.withScratchPasteboard { pb in
            let written = AssetPasteboardWriter.write(
                ExportSelection(entries: [], skipped: 0), to: pb, text: "just a text box")
            // Zero ENTRIES — the byte-side count the report is about — but the
            // words are on the board.
            #expect(written == 0)
            #expect(pb.string(forType: .string) == "just a text box")
        }
    }
}

// MARK: - The board's words (464)
//
// What a board ⌘C says to an app that takes nothing but text: the text boxes'
// strings and the media-less assets' words, in z-order, with the media cut out.
// Pure — no board, no model, no pasteboard.

@Suite("SpaceView.copiedText")
struct SpaceCopiedTextTests {

    private func element(kind: SpaceItemKind, text: String?, z: Int) -> SpaceItemDetail {
        SpaceItemDetail(
            item: SpaceItem(
                id: UUID(), spaceID: UUID(), kind: kind, assetID: nil,
                x: 0, y: 0, w: 10, h: 10, z: z,
                style: text.flatMap { ElementStyle(text: $0).jsonString() },
                createdAt: Date(), updatedAt: Date()),
            asset: nil, source: nil)
    }

    private func assetRow(_ asset: Asset, z: Int) -> SpaceItemDetail {
        SpaceItemDetail(
            item: SpaceItem(
                id: UUID(), spaceID: UUID(), kind: .asset, assetID: asset.id,
                x: 0, y: 0, w: 10, h: 10, z: z, style: nil,
                createdAt: Date(), updatedAt: Date()),
            asset: asset, source: Fixture.source())
    }

    @Test("a text box copies its string")
    func textBoxCopiesItsString() {
        #expect(SpaceView.copiedText(
            [element(kind: .text, text: "hello", z: 0)], blobURL: { _ in nil }) == "hello")
    }

    @Test("a frame contributes nothing — its label is furniture, not content")
    func frameLabelIsNotCopied() {
        #expect(SpaceView.copiedText(
            [element(kind: .frame, text: "Moodboard", z: 0)], blobURL: { _ in nil }) == nil)
    }

    @Test("an EMPTY text box drops out, and does not leave a blank line behind")
    func emptyTextBoxDropsOut() {
        let rows = [
            element(kind: .text, text: "one", z: 0),
            element(kind: .text, text: "   ", z: 1),
            element(kind: .text, text: nil, z: 2),
            element(kind: .text, text: "two", z: 3),
        ]
        #expect(SpaceView.copiedText(rows, blobURL: { _ in nil }) == "one\n\ntwo")
    }

    @Test("an image contributes nothing — the media is cut out of the words")
    func imageIsCutOut() {
        Fixture.withTempPNG { url in
            let image = Fixture.asset(kind: .image, blobHash: "abcdef1234", mime: "image/png")
            let rows = [assetRow(image, z: 0), element(kind: .text, text: "a caption", z: 1)]
            #expect(SpaceView.copiedText(rows, blobURL: { _ in url }) == "a caption")
        }
    }

    @Test("a media-LESS asset contributes its words, in the board's z-order")
    func mediaLessAssetsContributeText() {
        let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff0000"))
        let link = Fixture.asset(kind: .link, payload: Fixture.linkPayload("https://x.example"))
        // Given out of z-order to prove the caller's order is what is honoured:
        // `onCopyTiles` hands these over sorted, and nothing re-sorts them here.
        let rows = [
            assetRow(color, z: 0),
            element(kind: .text, text: "between", z: 1),
            assetRow(link, z: 2),
        ]
        #expect(SpaceView.copiedText(rows, blobURL: { _ in nil })
                == "#ff0000\n\nbetween\n\nhttps://x.example")
    }

    @Test("a link that HAS an og:image is a picture, and copies as one")
    func linkWithImageIsMedia() {
        // The same rule the byte write uses (`pasteboardEntry`), so the two can
        // never disagree about what this row is.
        Fixture.withTempPNG { url in
            let link = Fixture.asset(
                kind: .link, blobHash: "abcdef1234", mime: "image/png",
                payload: Fixture.linkPayload("https://x.example"))
            #expect(SpaceView.copiedText([assetRow(link, z: 0)], blobURL: { _ in url }) == nil)
        }
    }

    @Test("a selection with no words at all is nil, not an empty string")
    func nothingIsNil() {
        #expect(SpaceView.copiedText([], blobURL: { _ in nil }) == nil)
        #expect(SpaceView.copiedText(
            [element(kind: .frame, text: "Frame", z: 0)], blobURL: { _ in nil }) == nil)
    }
}

// MARK: - Copy as Text (465)
//
// ⌥⌘C's flavour: ONE string item and nothing else. The absence is the feature —
// a file URL beside the words is a copy every rich editor reads as a file,
// because `availableType(from:)` answers in the order the RECEIVER asks.

@Suite("CopyText.write(only:)", .serialized)
struct CopyTextOnlyTests {

    @Test("writes the words and NOTHING else")
    func writesOnlyTheWords() {
        Fixture.withScratchPasteboard { pb in
            #expect(CopyText.write(only: "the caption", to: pb))
            #expect(pb.string(forType: .string) == "the caption")
            #expect(pb.pasteboardItems?.count == 1)
            #expect(pb.availableType(from: [.fileURL, .string]) == .string)
            #expect(!pb.canReadObject(forClasses: [NSURL.self], options: nil))
        }
    }

    @Test("replaces a rich copy rather than adding to one")
    func clearsTheRichCopyFirst() {
        // The failure this prevents: ⌘C then ⌥⌘C leaving the file URL behind, so
        // the very apps this command exists for still paste the file.
        Fixture.withTempPNG { url in
            Fixture.withScratchPasteboard { pb in
                AssetPasteboardWriter.write(
                    ExportSelection(
                        entries: [.file(AssetExportItem(
                            blobURL: url, filename: url.lastPathComponent, utType: .png))],
                        skipped: 0),
                    to: pb)
                AssetPasteboardWriter.appendAssetIDs([UUID()], from: UUID(), to: pb)
                #expect(pb.canReadObject(forClasses: [NSURL.self], options: nil))

                CopyText.write(only: "the caption", to: pb)
                #expect(pb.string(forType: .string) == "the caption")
                #expect(!pb.canReadObject(forClasses: [NSURL.self], options: nil))
                #expect(AssetDragPayload.decode(from: pb) == nil)
                #expect(SpaceElementPayload.decode(from: pb) == nil)
            }
        }
    }
}

@Suite("AssetExport: the words of an asset selection (465)")
struct AssetCopiedTextTests {

    @Test("media-less assets contribute their words, in selection order")
    func mediaLessAssetsJoin() {
        let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff0000"))
        let link = Fixture.asset(kind: .link, payload: Fixture.linkPayload("https://x.example"))
        #expect(AssetExport.copiedText(
            assets: [(asset: color, source: nil), (asset: link, source: nil)],
            blobURL: { _ in nil }) == "#ff0000\n\nhttps://x.example")
    }

    @Test("a picture contributes nothing — not even its path")
    func pictureContributesNothing() {
        Fixture.withTempPNG { url in
            let image = Fixture.asset(kind: .image, blobHash: "abcdef1234", mime: "image/png")
            let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#00ff00"))
            #expect(AssetExport.copiedText(
                assets: [(asset: image, source: nil), (asset: color, source: nil)],
                blobURL: { $0.id == image.id ? url : nil }) == "#00ff00")
        }
    }

    @Test("a selection of pure media has no text copy at all")
    func pureMediaIsNil() {
        Fixture.withTempPNG { url in
            let image = Fixture.asset(kind: .image, blobHash: "abcdef1234", mime: "image/png")
            #expect(AssetExport.copiedText(
                assets: [(asset: image, source: nil)], blobURL: { _ in url }) == nil)
        }
    }
}

@Suite("AssetExport.mayHaveText — the cheap menu predicate (465)")
struct MayHaveTextTests {

    @Test("agrees with the exact rule on every ordinary row")
    func agreesWithTheExactRule() {
        Fixture.withTempPNG { url in
            let rows: [(Asset, URL?)] = [
                (Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff0000")), nil),
                (Fixture.asset(kind: .link, payload: Fixture.linkPayload("https://x.example")), nil),
                (Fixture.asset(kind: .tweet, payload: Fixture.tweetPayload(id: "1", handle: "@a")), nil),
                (Fixture.asset(kind: .image, blobHash: "abcdef1234", mime: "image/png"), url),
                (Fixture.asset(kind: .video, blobHash: "abcdef1234", mime: "video/mp4"), url),
                // A media-less kind whose payload will not parse reads as
                // `.unknown` content: no bytes AND no words.
                (Fixture.asset(kind: .color), nil),
                // A link WITH an og:image is a picture: no words, either way.
                (Fixture.asset(
                    kind: .link, blobHash: "abcdef1234", mime: "image/png",
                    payload: Fixture.linkPayload("https://x.example")), url),
            ]
            for (asset, blob) in rows {
                let exact = AssetExport.pasteboardEntry(
                    asset: asset, source: nil, blobURL: blob)?.text != nil
                #expect(AssetExport.mayHaveText(asset) == exact,
                        "disagreed on \(asset.kind)")
            }
        }
    }

    @Test("the ONE row the two disagree on: a claimed blob whose file is gone")
    func disagreesOnAMissingBlob() {
        // Documented, not accidental: the exact rule falls back to the link's URL,
        // the cheap one greys the menu out. A library in this state is broken.
        let orphan = Fixture.asset(
            kind: .link, blobHash: "abcdef1234", mime: "image/png",
            payload: Fixture.linkPayload("https://x.example"))
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).png")
        #expect(AssetExport.pasteboardEntry(
            asset: orphan, source: nil, blobURL: missing)?.text == "https://x.example")
        #expect(AssetExport.mayHaveText(orphan) == false)
    }

    @Test("an empty blobHash counts as no bytes, like a nil one")
    func emptyHashIsNoBytes() {
        let color = Fixture.asset(kind: .color, blobHash: "", payload: Fixture.colorPayload("#ff0000"))
        #expect(AssetExport.mayHaveText(color))
    }
}
