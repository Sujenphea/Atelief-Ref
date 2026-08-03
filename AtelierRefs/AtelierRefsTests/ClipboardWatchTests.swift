//
//  ClipboardWatchTests.swift
//  AtelierRefsTests
//
//  013 · K3 — the clipboard watcher's decision core. Every privacy rule the
//  feature promises is asserted here, against a fake board: no timer, no
//  `NSPasteboard.general` (a test that wrote to the general pasteboard would
//  clobber the developer's actual clipboard), no ingest.
//
//  What is deliberately NOT tested: the timer, the `NSStatusItem`, and the
//  `UserDefaults` round-trip. Per the repo's convention those are compile-only +
//  manual — and standing up a real menu-bar item inside the test process is
//  exactly the kind of thing that makes a suite flaky for no coverage.
//

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

/// A pasteboard that is whatever a test says it is.
private struct FakeBoard: ClipboardBoard {
    var changeCount: Int
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    /// Marker types carry no data on a real board either — they exist purely to
    /// be present in the type list.
    var markers: [NSPasteboard.PasteboardType] = []
    /// Counts `data(forType:)` calls, so a test can prove the bytes of a
    /// concealed board are never even asked for.
    var reads = Counter()

    var availableTypes: [NSPasteboard.PasteboardType] {
        Array(contents.keys) + markers
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        reads.bump()
        return contents[type]
    }
}

/// A reference box so a `struct` board can record reads without being `mutating`.
private final class Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private let png = NSPasteboard.PasteboardType.png
private let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
private let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])

@Suite("Clipboard watcher decision core (013 · K3)")
struct ClipboardWatchTests {

    // MARK: - changeCount: the gate that runs forever

    @Test("an unmoved changeCount is not even inspected")
    func unchangedBoardIsSkipped() {
        var watch = ClipboardWatch(lastChangeCount: 7)
        let board = FakeBoard(changeCount: 7, contents: [png: imageBytes])

        #expect(watch.evaluate(board) == .skip(.unchanged))
        // The image is right there and is still not read: nothing happened, so
        // there is nothing to look at. This is the once-a-second path.
        #expect(board.reads.count == 0)
        #expect(watch.lastChangeCount == 7)
    }

    @Test("a moved changeCount is evaluated, and captures the image")
    func changedBoardIsCaptured() {
        var watch = ClipboardWatch(lastChangeCount: 7)
        let board = FakeBoard(changeCount: 8, contents: [png: imageBytes])

        #expect(watch.evaluate(board) == .capture(imageBytes))
        #expect(watch.lastChangeCount == 8)
    }

    @Test("arming from a board adopts its count, so what was already copied is not taken")
    func startingFromABoardCapturesNothing() {
        // Turning the watcher on must not sweep up whatever was on the clipboard
        // beforehand — the user consented to what they copy NEXT, and what is
        // already there could be the password they pasted a minute ago.
        let board = FakeBoard(changeCount: 42, contents: [png: imageBytes])
        var watch = ClipboardWatch(startingFrom: board)

        #expect(watch.lastChangeCount == 42)
        #expect(watch.evaluate(board) == .skip(.unchanged))
    }

    @Test("a skipped board is not re-judged on the next tick")
    func skipsAdvanceTheCount() {
        // Without this, a concealed password sitting on the clipboard would be
        // re-inspected once a second until it was replaced.
        var watch = ClipboardWatch(lastChangeCount: 1)
        let concealed = FakeBoard(
            changeCount: 2, contents: [png: imageBytes],
            markers: [ClipboardWatch.concealedType])

        #expect(watch.evaluate(concealed) == .skip(.concealed))
        #expect(watch.evaluate(concealed) == .skip(.unchanged))
        #expect(watch.lastChangeCount == 2)
    }

    // MARK: - The marker gates

    @Test("a concealed pasteboard is skipped, and its bytes are never read")
    func concealedIsSkippedWithoutReading() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1, contents: [png: imageBytes],
            markers: [ClipboardWatch.concealedType])

        #expect(watch.evaluate(board) == .skip(.concealed))
        // The whole promise: a password manager's copy is not read, not hashed,
        // and not logged. Ordering the marker gate before the byte read is what
        // makes that true rather than merely intended.
        #expect(board.reads.count == 0)
    }

    @Test("a transient pasteboard is skipped, and its bytes are never read")
    func transientIsSkippedWithoutReading() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1, contents: [png: imageBytes],
            markers: [ClipboardWatch.transientType])

        #expect(watch.evaluate(board) == .skip(.transient))
        #expect(board.reads.count == 0)
    }

    @Test("the marker identifiers are the nspasteboard.org conventional ones")
    func markerIdentifiers() {
        // There is no Apple constant for either — they are a convention password
        // managers and clipboard utilities agree on, so a typo here would silently
        // disable the entire protection with every test above still passing.
        #expect(ClipboardWatch.concealedType.rawValue == "org.nspasteboard.ConcealedType")
        #expect(ClipboardWatch.transientType.rawValue == "org.nspasteboard.TransientType")
    }

    @Test("a marker on a board with no image still reports the marker, not noImage")
    func markersOutrankTheImageGate() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1, contents: [.string: Data("hunter2".utf8)],
            markers: [ClipboardWatch.concealedType])

        #expect(watch.evaluate(board) == .skip(.concealed))
    }

    // MARK: - The own-copy trap

    @Test("a pasteboard carrying the app's own asset payload is skipped")
    func ownCopyIsSkipped() {
        // ⌘C in the grid / detail writes an app-private `AssetDragPayload` under
        // `com.ref-atelier.asset-ids` alongside the image, so the watcher can tell
        // the library's own copy from an ambient one and not re-ingest it.
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1,
            contents: [png: imageBytes, AssetDragPayload.pasteboardType: Data([0x1])])

        #expect(watch.evaluate(board) == .skip(.ownCopy))
    }

    @Test("the own-copy marker is the app-private asset-ids type")
    func ownCopyMarkerIdentifier() {
        #expect(AssetDragPayload.pasteboardType.rawValue == "com.ref-atelier.asset-ids")
    }

    // MARK: - Images only

    @Test("a text pasteboard produces no capture")
    func textIsSkipped() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(changeCount: 1, contents: [.string: Data("a note".utf8)])

        #expect(watch.evaluate(board) == .skip(.noImage))
    }

    @Test("a file pasteboard produces no capture")
    func filesAreSkipped() {
        // Never files. A folder of copied documents is not a reference library,
        // and reaching for them is the step that turns this into surveillance.
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1, contents: [.fileURL: Data("file:///etc/passwd".utf8)])

        #expect(watch.evaluate(board) == .skip(.noImage))
    }

    @Test("an empty pasteboard produces no capture")
    func emptyIsSkipped() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        #expect(watch.evaluate(FakeBoard(changeCount: 1)) == .skip(.noImage))
    }

    @Test("an image type present but empty is not a capture")
    func zeroLengthImageIsSkipped() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(changeCount: 1, contents: [png: Data()])

        #expect(watch.evaluate(board) == .skip(.noImage))
    }

    @Test("every recognized image representation captures", arguments: [
        NSPasteboard.PasteboardType.png,
        NSPasteboard.PasteboardType.tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    ])
    func eachImageTypeCaptures(_ type: NSPasteboard.PasteboardType) {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(changeCount: 1, contents: [type: imageBytes])

        #expect(watch.evaluate(board) == .capture(imageBytes))
    }

    @Test("the recognized types match the paste path's, in the same order")
    func imageTypesAgreeWithPaste() {
        // Ambient capture and ⌘V must agree on what counts as an image; a drift
        // means the watcher silently ignoring things the user can paste by hand.
        #expect(ClipboardWatch.imageTypes.map(\.rawValue)
            == ["public.png", "public.tiff", "public.jpeg"])
    }

    @Test("PNG wins over JPEG when a board carries both")
    func preferenceOrderIsHonoured() {
        var watch = ClipboardWatch(lastChangeCount: 0)
        let board = FakeBoard(
            changeCount: 1, contents: [png: imageBytes, jpeg: Data([0xFF, 0xD8])])

        #expect(watch.evaluate(board) == .capture(imageBytes))
    }

    // MARK: - Dedup tolerance

    @Test("the same image copied twice is captured twice, and that is harmless")
    func repeatedCopiesAreBothCaptured() {
        // The watcher does not try to remember bytes: 18A content-hash dedup in
        // the pipeline resolves a repeat to the asset that already exists, so a
        // double-fire costs one wasted decode and nothing else. Suppressing it
        // here would mean the watcher holding on to image data between ticks —
        // strictly worse for a feature whose whole point is touching as little as
        // possible.
        var watch = ClipboardWatch(lastChangeCount: 0)
        let first = FakeBoard(changeCount: 1, contents: [png: imageBytes])
        let second = FakeBoard(changeCount: 2, contents: [png: imageBytes])

        #expect(watch.evaluate(first) == .capture(imageBytes))
        #expect(watch.evaluate(second) == .capture(imageBytes))
    }

    // MARK: - The reasons carry nothing

    @Test("a skip reason is a bare case — it cannot carry pasteboard content")
    func skipReasonsAreOpaque() {
        // This is the property that makes logging a decision safe. If a reason
        // ever grows an associated value, this stops compiling, which is the
        // point: the type enforces it, not a habit at each call site.
        for reason in ClipboardSkip.allCases {
            #expect(!reason.rawValue.isEmpty)
        }
        #expect(ClipboardSkip.allCases.count == 5)
    }
}

// MARK: - Provenance

@Suite("Clipboard capture provenance (013 · K3)")
struct ClipboardProvenanceTests {

    @Test("an unresolved frontmost app is carried as nils, not as invented strings")
    func frontmostAppIsRawAtThisLayer() {
        // Normalization and the "Clipboard" fallback live in exactly one place —
        // `DirectInputReader.clipboardInput` — so this layer stays honest about
        // what it did and did not learn. (The fallback itself is asserted in
        // AtelierIngestionTests/DirectInputReaderTests.)
        let unknown = FrontmostApp(name: nil, bundleID: nil)
        #expect(unknown.name == nil)
        #expect(unknown.bundleID == nil)
    }

    @Test("a resolved app carries both its localized name and its bundle id")
    func frontmostAppCarriesBoth() {
        let app = FrontmostApp(name: "Preview", bundleID: "com.apple.Preview")
        #expect(app.name == "Preview")
        #expect(app.bundleID == "com.apple.Preview")
    }

    @Test("the watcher's defaults key is namespaced by library id (016 §C)")
    func preferenceKeyIsLibraryScoped() {
        // Multi-library is deferred, but new keys take the prefix from now on so
        // that deferral doesn't turn into a migration later.
        #expect(ClipboardWatcher.enabledKey(libraryID: "atelier-abc123")
            == "library.atelier-abc123.clipboardCaptureEnabled")
    }

    @Test("ambient capture is off by default")
    func offByDefault() {
        let defaults = UserDefaults(suiteName: "clipboard-watcher-tests-\(UUID().uuidString)")!
        let watcher = ClipboardWatcher(defaults: defaults)

        // Before the library binds it, it cannot even be turned on.
        #expect(!watcher.isEnabled)
        #expect(!watcher.isAvailable)
        #expect(!watcher.isWatching)
        watcher.setEnabled(true)
        #expect(!watcher.isEnabled)
    }
}
