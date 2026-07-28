//
//  HostFramingTests.swift
//  CanvasRendererTests
//
//  When the host is allowed to frame the board to fit — the one camera move the
//  renderer makes on its own, and therefore the one that can take the viewport away
//  from the user.
//
//  It used to be "the first `layout()` with a non-empty bounds, once per host
//  instance", which was wrong twice over. It fired too EARLY: a board reads its rows
//  asynchronously, so that first layout runs with no tiles at all, and framing an
//  empty world is a silent no-op that nonetheless burned the one shot. And it was
//  scoped to the wrong thing: "once per host" means any rebuild of the host reframes,
//  which is how deleting a tile — or undoing anything — used to throw away the user's
//  pan and zoom.
//
//  It is now "once per board, when there is something to frame", with the arming
//  owned by the app.
//

import AppKit
import CoreGraphics
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Host framing one-shot")
struct HostFramingTests {
    /// A provider whose tiles arrive later — the whole point. A board's rows come from
    /// an async read, so the canvas is laid out before there is anything to frame.
    private final class LateProvider: TileProvider {
        var tiles: [Tile] = []
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private let content = [Tile(id: 0, x: 0, y: 0, w: 400, h: 400, z: 0)]

    private func makeHost(_ provider: LateProvider) -> CanvasHostView {
        CanvasHostView(
            provider: provider, images: NoImages(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    // MARK: - hasDrawableContent

    @Test("hasDrawableContent is false for an empty provider and for degenerate tiles")
    func drawableContentPrecondition() {
        let provider = LateProvider()
        let host = makeHost(provider)
        var framed = 0
        host.onDidFrameContent = { framed += 1 }

        host.layout()
        #expect(framed == 0)

        // A tile with no area is not something you can frame to.
        provider.tiles = [Tile(id: 0, x: 0, y: 0, w: 0, h: 0, z: 0)]
        host.syncToken = 1
        #expect(framed == 0)

        provider.tiles = content
        host.syncToken = 2
        #expect(framed == 1)
    }

    // MARK: - The one-shot

    @Test("an empty first layout does not consume the one shot; the content does")
    func lateContentIsStillFramed() {
        let provider = LateProvider()
        let host = makeHost(provider)
        var framed = 0
        host.onDidFrameContent = { framed += 1 }
        let identity = host.transform

        host.layout()                    // the async read hasn't returned yet
        #expect(framed == 0)
        #expect(host.transform.scale == identity.scale)

        provider.tiles = content         // …rows arrive, with no bounds change
        host.syncToken = 1
        #expect(framed == 1)
        #expect(host.transform.scale != identity.scale) // the camera actually moved
    }

    @Test("framing happens exactly once, however many layouts and syncs follow")
    func framesOnlyOnce() {
        let provider = LateProvider()
        provider.tiles = content
        let host = makeHost(provider)
        var framed = 0
        host.onDidFrameContent = { framed += 1 }

        host.layout()
        #expect(framed == 1)
        let afterFraming = host.transform

        // A window resize must re-sync, never re-frame: the camera is the user's now.
        host.setFrameSize(NSSize(width: 1_000, height: 700))
        host.layout()
        host.syncToken = 1
        host.syncToken = 2
        #expect(framed == 1)
        #expect(host.transform.scale == afterFraming.scale)
        #expect(host.transform.translation == afterFraming.translation)
    }

    @Test("a disarmed host never frames, at any layout or sync")
    func disarmedHostNeverFrames() {
        let provider = LateProvider()
        provider.tiles = content
        let host = makeHost(provider)
        var framed = 0
        host.onDidFrameContent = { framed += 1 }
        // What the app passes for a board it has already framed once.
        host.framesContentWhenReady = false
        let identity = host.transform

        host.layout()
        host.syncToken = 1
        host.syncToken = 2
        #expect(framed == 0)
        #expect(host.transform.scale == identity.scale)
        #expect(host.transform.translation == identity.translation)
    }

    @Test("a sync that does not frame still re-syncs the layers")
    func nonFramingSyncStillDraws() {
        let provider = LateProvider()
        let host = makeHost(provider)
        host.framesContentWhenReady = false // never frames, so only the sync branch runs
        host.layout()
        #expect(host.layer?.sublayers?.isEmpty != false) // nothing to draw yet

        // The redraw path must not be swallowed by the framing branch: a reload
        // signals through `syncToken`, and nothing else would draw the new rows.
        provider.tiles = content
        host.syncToken = 1
        #expect(host.layer?.sublayers?.count == 1)
    }
}
