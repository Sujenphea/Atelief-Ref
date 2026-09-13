//
//  HostEditingTests.swift
//  CanvasRendererTests
//
//  Inline editing as the host now owns it. The `NSTextView`'s own behaviour —
//  first responder, IME, blur — is live-only and verified by hand; what is pinned here
//  is everything around it: when an edit begins, that it begins exactly once, what the
//  app is told, and that every teardown path reports an outcome rather than losing the
//  text.
//

import AppKit
import CoreGraphics
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Host-owned inline text editing")
struct HostEditingTests {
    private final class TextProvider: TileProvider {
        var tiles: [Tile] = [
            Tile(id: 0, x: 0, y: 0, w: 300, h: 40, z: 0),
            Tile(id: 1, x: 400, y: 0, w: 300, h: 300, z: 1),
        ]
        var texts: [Int: TextStyle] = [
            0: TextStyle(string: "hello", fontSize: 16, color: RGBAColor(red: 1, green: 1, blue: 1)),
        ]
        /// Every string the renderer was handed for tile 0, in order — so a test can ask
        /// what the canvas actually drew, not just what it ended up with.
        var served: [String] = []
        func content(for tile: Tile) -> TileContent {
            if let style = texts[tile.id] {
                if tile.id == 0 { served.append(style.string) }
                return .text(style)
            }
            return .image
        }
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private func makeHost(_ provider: TextProvider = TextProvider()) -> CanvasHostView {
        let host = CanvasHostView(
            provider: provider, images: NoImages(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.framesContentWhenReady = false // keep the camera at identity for exact frames
        host.layout()
        return host
    }

    // MARK: - Beginning

    @Test("editing a text tile begins, reports itself, and blanks the committed glyphs")
    func beginEditing() {
        let host = makeHost()
        var changed: [Int?] = []
        host.onEditingChanged = { changed.append($0) }

        host.beginEditingText(tileID: 0, isNewlyCreated: false)

        #expect(host.editingTileID == 0)
        #expect(changed == [0])
        // The engine must blank that tile's committed text, or the live glyphs are
        // drawn on top of the rendered ones.
        #expect(host.contentLayer.sublayers?.isEmpty == false)
    }

    @Test("a tile that draws no text cannot be edited")
    func nonTextTileIsNotEditable() {
        let host = makeHost()
        var changed: [Int?] = []
        host.onEditingChanged = { changed.append($0) }

        host.beginEditingText(tileID: 1, isNewlyCreated: false)   // an image tile
        host.beginEditingText(tileID: 99, isNewlyCreated: false)  // no such tile

        #expect(host.editingTileID == nil)
        #expect(changed.isEmpty)
    }

    @Test("beginning on the tile already being edited is a no-op, not a restart")
    func reentrantBeginIsIgnored() {
        let host = makeHost()
        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        var changed: [Int?] = []
        var finished: [CanvasTextEditOutcome] = []
        host.onEditingChanged = { changed.append($0) }
        host.onFinishEditingText = { _, outcome in finished.append(outcome) }

        host.beginEditingText(tileID: 0, isNewlyCreated: false)

        #expect(changed.isEmpty)
        #expect(finished.isEmpty)
        #expect(host.editingTileID == 0)
    }

    // MARK: - Finishing

    @Test("ending an edit reports the outcome once, then clears")
    func endEditingReportsOnce() {
        let host = makeHost()
        var finished: [(Int, CanvasTextEditOutcome)] = []
        var changed: [Int?] = []
        host.onFinishEditingText = { finished.append(($0, $1)) }
        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        host.onEditingChanged = { changed.append($0) }

        host.endEditingText(commit: true)

        #expect(finished.count == 1)
        #expect(finished.first?.0 == 0)
        #expect(finished.first?.1 == .committed("hello"))
        #expect(host.editingTileID == nil)
        #expect(changed == [nil])   // …and the app is told, after the outcome
    }

    @Test("a second end is inert — the commit guard means one edit, one outcome")
    func endingTwiceReportsOnce() {
        let host = makeHost()
        var finished = 0
        host.onFinishEditingText = { _, _ in finished += 1 }
        host.beginEditingText(tileID: 0, isNewlyCreated: false)

        host.endEditingText(commit: true)
        host.endEditingText(commit: true)
        host.endEditingText(commit: false)

        #expect(finished == 1)
    }

    @Test("ending with no edit open does nothing at all")
    func endingWithoutAnEditIsSafe() {
        let host = makeHost()
        var finished = 0
        host.onFinishEditingText = { _, _ in finished += 1 }
        host.endEditingText(commit: true)
        #expect(finished == 0)
    }

    /// ⎋ no longer reaches here — it commits, as it does in Figma (see
    /// ``CanvasTextEditOutcome/cancelled``). What remains is the host's own
    /// `endEditingText(commit: false)`, which is still an abandon.
    @Test("an explicitly abandoned edit writes nothing")
    func cancelOutcomes() {
        let host = makeHost()
        var outcome: CanvasTextEditOutcome?
        host.onFinishEditingText = { _, o in outcome = o }

        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        host.endEditingText(commit: false)
        #expect(outcome == .cancelled)
    }

    @Test("editing a different tile commits the one already open")
    func switchingTilesCommitsTheFirst() {
        let provider = TextProvider()
        provider.texts[1] = TextStyle(
            string: "second", fontSize: 16, color: RGBAColor(red: 1, green: 1, blue: 1))
        let host = makeHost(provider)
        var finished: [(Int, CanvasTextEditOutcome)] = []
        host.onFinishEditingText = { finished.append(($0, $1)) }

        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        host.beginEditingText(tileID: 1, isNewlyCreated: false)

        #expect(finished.count == 1)
        #expect(finished.first?.0 == 0)
        #expect(finished.first?.1 == .committed("hello"))
        #expect(host.editingTileID == 1)
    }

    // MARK: - editRequest

    @Test("a request begins exactly one edit, however many times it is re-pushed")
    func requestIsIdempotent() {
        let host = makeHost()
        var changed: [Int?] = []
        host.onEditingChanged = { changed.append($0) }

        let request = CanvasTextEditRequest(tileID: 0, isNewlyCreated: true, token: 1)
        host.editRequest = request
        host.editRequest = request   // SwiftUI re-pushing the same state
        host.editRequest = request

        #expect(changed == [0])
    }

    @Test("clearing the request does NOT end the edit")
    func nilRequestIsNotAnEnd() {
        let host = makeHost()
        var finished = 0
        host.onFinishEditingText = { _, _ in finished += 1 }

        host.editRequest = CanvasTextEditRequest(tileID: 0, isNewlyCreated: true, token: 1)
        // The app clears its state once the request is taken. If that read as "stop
        // editing", every new text box would lose its editor the moment it appeared.
        host.editRequest = nil

        #expect(host.editingTileID == 0)
        #expect(finished == 0)
    }

    @Test("a new token re-opens the same tile — an id alone could not say that")
    func newTokenReopensTheSameTile() {
        let host = makeHost()
        var changed: [Int?] = []
        host.onEditingChanged = { changed.append($0) }

        host.editRequest = CanvasTextEditRequest(tileID: 0, isNewlyCreated: false, token: 1)
        host.endEditingText(commit: true)
        host.editRequest = CanvasTextEditRequest(tileID: 0, isNewlyCreated: false, token: 2)

        #expect(changed == [0, nil, 0])
    }

    @Test("a request arriving before the first layout is held, not dropped")
    func requestSurvivesAnUnlaidOutCanvas() {
        let provider = TextProvider()
        let host = CanvasHostView(
            provider: provider, images: NoImages(), frame: .zero) // no viewport yet
        host.framesContentWhenReady = false
        var changed: [Int?] = []
        host.onEditingChanged = { changed.append($0) }

        host.editRequest = CanvasTextEditRequest(tileID: 0, isNewlyCreated: true, token: 1)
        #expect(changed.isEmpty) // nothing to measure against yet

        host.setFrameSize(NSSize(width: 800, height: 600))
        host.layout()
        #expect(changed == [0])  // …and it is honoured as soon as there is
    }

    // MARK: - Teardown

    @Test("leaving the window commits rather than losing the text")
    func leavingTheWindowCommits() async {
        let host = makeHost()
        var finished: [CanvasTextEditOutcome] = []
        host.onFinishEditingText = { _, o in finished.append(o) }
        host.beginEditingText(tileID: 0, isNewlyCreated: false)

        host.viewWillMove(toWindow: nil)

        // The edit is over at once — only the REPORT is deferred, because a teardown
        // commit publishes into the very view update that is removing this host.
        #expect(host.editingTileID == nil)
        #expect(finished.isEmpty)
        await Task.yield()
        #expect(finished == [.committed("hello")])
    }

    // MARK: - The stale-redraw contract

    @Test("the box is never redrawn with the old text — the app writes before the un-blank")
    func committedGlyphsAreNeverDrawnStale() {
        let provider = TextProvider()
        let host = makeHost(provider)
        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        // The app, writing where it is told to: synchronously, as `SpaceModel` does by
        // mirroring into the live content before its persistence is enqueued.
        host.onFinishEditingText = { tileID, _ in
            provider.texts[tileID] = TextStyle(
                string: "typed", fontSize: 16, color: RGBAColor(red: 1, green: 1, blue: 1))
        }
        provider.served.removeAll()

        host.endEditingText(commit: true)

        // Ending an edit restores the stored height and un-blanks the glyphs, and both
        // re-read the provider. If the outcome were reported late — or reported after
        // those two steps — the canvas would draw the OLD string at the OLD height for a
        // turn and then reflow, which is a flicker on every single commit.
        #expect(!provider.served.isEmpty)              // it did redraw…
        #expect(!provider.served.contains("hello"))    // …and never with the stale string
    }

    // MARK: - Handles vs the caret

    @Test("the edited box yields most of its grab zone to the caret, but not all")
    func editedBoxKeepsCatchableHandles() {
        let host = makeHost()
        host.selectedTileIDs = [0]
        // A 300×40 tile at identity. The zones are centred on the handles, so they
        // reach hitSize/2 inward: 11pt normally, 5pt while editing. A point 10pt below
        // the top edge is therefore the top handle's when idle and the caret's when
        // editing — that 6pt band, top and bottom, is what the text gets back.
        let reclaimed = CGPoint(x: 150, y: 10)
        #expect(host.resizeHandleForTesting(at: reclaimed) == .top)

        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        #expect(host.resizeHandleForTesting(at: reclaimed) == nil)   // now the caret's

        // The edge itself still resizes: 062 keeps resize-while-editing deliberately.
        #expect(host.resizeHandleForTesting(at: CGPoint(x: 150, y: 1)) != nil)
        #expect(host.resizeHandleForTesting(at: CGPoint(x: 1, y: 20)) != nil)
    }
}
