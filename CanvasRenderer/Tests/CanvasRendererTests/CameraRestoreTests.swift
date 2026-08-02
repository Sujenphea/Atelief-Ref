//
//  CameraRestoreTests.swift
//  CanvasRendererTests
//
//  018 · Cluster C — where a board opens.
//
//  The renderer half of camera persistence is one rule with one fallback: use the
//  saved camera, unless there ISN'T one or it would open the viewport on empty
//  world space, in which case fit the content. These pin the rule, the round-trip
//  through `CanvasTransform`'s camera conversion (which is what makes a saved
//  camera survive a window resize), and the fact that a restore rides the same
//  one-shot seam the fit always did.
//

import AppKit
import CoreGraphics
import Testing
@testable import CanvasRenderer

// MARK: - The pure conversion

@Suite("CanvasTransform ⇄ CanvasCamera")
struct CanvasCameraConversionTests {

    private let viewport = CGSize(width: 800, height: 600)

    @Test("camera → transform → camera is the identity")
    func roundTrips() {
        let camera = CanvasCamera(centre: CGPoint(x: 1_250, y: -430), zoom: 2.5)
        let transform = CanvasTransform().settingCamera(camera, viewportSize: viewport)
        let back = transform.camera(viewportSize: viewport)
        #expect(Approx.equal(back.centre, camera.centre))
        #expect(Approx.equal(back.zoom, camera.zoom))
    }

    @Test("the restored centre lands at the middle of the viewport")
    func centreLandsAtViewportCentre() {
        let centre = CGPoint(x: 300, y: 900)
        let transform = CanvasTransform()
            .settingCamera(CanvasCamera(centre: centre, zoom: 1.5), viewportSize: viewport)
        #expect(Approx.equal(
            transform.worldToScreen(centre),
            CGPoint(x: viewport.width / 2, y: viewport.height / 2)))
    }

    @Test("the SAME camera keeps the same content centred in a different window")
    func survivesAWindowResize() {
        // The reason a camera is a world CENTRE and not a screen translation: a
        // translation restored into a smaller window slides the board by half the
        // difference, a centre does not move at all.
        let camera = CanvasCamera(centre: CGPoint(x: 500, y: 500), zoom: 1)
        let big = CanvasTransform().settingCamera(camera, viewportSize: viewport)
        let small = CanvasTransform()
            .settingCamera(camera, viewportSize: CGSize(width: 400, height: 300))
        #expect(Approx.equal(big.camera(viewportSize: viewport).centre, camera.centre))
        #expect(Approx.equal(
            small.camera(viewportSize: CGSize(width: 400, height: 300)).centre, camera.centre))
    }

    @Test("a zoom outside the scale range is clamped, and the centre still holds")
    func clampsZoomKeepingCentre() {
        let camera = CanvasCamera(centre: CGPoint(x: 100, y: 100), zoom: 10_000)
        let transform = CanvasTransform().settingCamera(camera, viewportSize: viewport)
        #expect(transform.scale == transform.maxScale)
        // Recomputed from the CLAMPED scale, so the anchor does not skid.
        #expect(Approx.equal(
            transform.worldToScreen(camera.centre),
            CGPoint(x: viewport.width / 2, y: viewport.height / 2)))
    }
}

// MARK: - The engine rule

@MainActor
@Suite("Engine camera restore (one rule, one fallback)")
struct EngineCameraRestoreTests {

    private final class Provider: TileProvider {
        var tiles: [Tile] = []
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// One 400×400 tile at the world origin, and a viewport to look at it through.
    private func makeEngine(tiles: [Tile] = [Tile(id: 0, x: 0, y: 0, w: 400, h: 400, z: 0)])
        -> (engine: CanvasEngine, provider: Provider)
    {
        let provider = Provider()
        provider.tiles = tiles
        let engine = CanvasEngine(provider: provider, images: NoImages())
        engine.viewportSize = CGSize(width: 800, height: 600)
        return (engine, provider)
    }

    @Test("contentWorldBounds is the union of the drawable tiles, ignoring degenerates")
    func contentBounds() {
        let (engine, _) = makeEngine(tiles: [
            Tile(id: 0, x: 0, y: 0, w: 100, h: 100, z: 0),
            Tile(id: 1, x: 300, y: 200, w: 100, h: 100, z: 0),
            Tile(id: 2, x: -5_000, y: -5_000, w: 0, h: 0, z: 0),   // degenerate
        ])
        #expect(engine.contentWorldBounds == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test("an empty board has no content bounds")
    func emptyBoardHasNoBounds() {
        let (engine, _) = makeEngine(tiles: [])
        #expect(engine.contentWorldBounds == nil)
    }

    @Test("a saved camera over the content is used verbatim")
    func restoresASavedCamera() {
        let (engine, _) = makeEngine()
        let saved = CanvasCamera(centre: CGPoint(x: 200, y: 200), zoom: 3)

        #expect(engine.restoreCamera(saved))    // reports "used the saved camera"

        #expect(Approx.equal(engine.camera.centre, saved.centre))
        #expect(Approx.equal(engine.camera.zoom, saved.zoom))
    }

    @Test("NULL / undecodable — i.e. nil — falls back to frameToContent")
    func nilFallsBackToFit() {
        let (engine, _) = makeEngine()

        #expect(!engine.restoreCamera(nil))     // reports "re-fitted"
        let restored = engine.camera

        // Exactly what a plain fit would have produced.
        let (reference, _) = makeEngine()
        reference.frameToContent()
        #expect(Approx.equal(restored.centre, reference.camera.centre))
        #expect(Approx.equal(restored.zoom, reference.camera.zoom))
        // …and the content really is on screen.
        #expect(engine.showsContent(under: restored))
    }

    @Test("a camera whose viewport intersects NO content re-fits")
    func offscreenCameraRefits() {
        let (engine, _) = makeEngine()
        // Parked in deep space, far past the 400×400 tile at the origin.
        let marooned = CanvasCamera(centre: CGPoint(x: 500_000, y: 500_000), zoom: 4)
        #expect(!engine.showsContent(under: marooned))

        #expect(!engine.restoreCamera(marooned))    // reports "re-fitted"

        let (reference, _) = makeEngine()
        reference.frameToContent()
        #expect(Approx.equal(engine.camera.centre, reference.camera.centre))
        #expect(Approx.equal(engine.camera.zoom, reference.camera.zoom))
    }

    @Test("a camera showing only a SLIVER of content is honoured, not clamped")
    func slightlyOffCentreCameraIsKept() {
        // The rejected design was "clamp until some fraction is visible", which has
        // to invent a threshold. The rule is intersects-or-not: panning until the
        // board is a sliver at the edge is a place the user chose to be.
        let (engine, _) = makeEngine()
        // Viewport is 800×600 world units at zoom 1; centred here its left edge sits
        // at x = 399, clipping one world unit of the tile.
        let sliver = CanvasCamera(centre: CGPoint(x: 799, y: 200), zoom: 1)
        #expect(engine.showsContent(under: sliver))
        #expect(engine.restoreCamera(sliver))
        #expect(Approx.equal(engine.camera.centre, sliver.centre))
    }

    @Test("a restore notifies the transform seam exactly once")
    func notifiesOnce() {
        let (engine, _) = makeEngine()
        var count = 0
        engine.onTransformChanged = { count += 1 }
        engine.restoreCamera(CanvasCamera(centre: CGPoint(x: 200, y: 200), zoom: 2))
        #expect(count == 1)     // routes through setTransform, like frameToContent
    }

    @Test("with no viewport nothing shows content, so the restore cannot run")
    func emptyViewportShowsNothing() {
        let (engine, _) = makeEngine()
        engine.viewportSize = .zero
        #expect(!engine.showsContent(under: CanvasCamera(centre: .zero, zoom: 1)))
    }
}

// MARK: - The host seam

@MainActor
@Suite("Host camera restore rides the framing one-shot")
struct HostCameraRestoreTests {

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

    @Test("a saved camera is restored instead of fitting, once the rows arrive")
    func restoresOnFirstContent() {
        let provider = LateProvider()
        let host = makeHost(provider)
        var framed = 0
        host.onDidFrameContent = { framed += 1 }
        let saved = CanvasCamera(centre: CGPoint(x: 111, y: 222), zoom: 2)
        host.restoreCamera = saved

        host.layout()               // the async read hasn't returned yet
        #expect(framed == 0)

        provider.tiles = content    // …rows arrive
        host.syncToken = 1
        #expect(framed == 1)        // the SAME one-shot reports it
        #expect(Approx.equal(host.camera.centre, saved.centre))
        #expect(Approx.equal(host.camera.zoom, saved.zoom))
    }

    @Test("no saved camera still fits the board, exactly as before")
    func nilStillFits() {
        let provider = LateProvider()
        provider.tiles = content
        let host = makeHost(provider)
        host.restoreCamera = nil

        host.layout()

        // The 400×400 board centred in an 800×600 viewport.
        #expect(Approx.equal(host.camera.centre, CGPoint(x: 200, y: 200)))
    }

    @Test("the restore is one-shot: later layouts and syncs never move the camera")
    func restoresOnlyOnce() {
        let provider = LateProvider()
        provider.tiles = content
        let host = makeHost(provider)
        host.restoreCamera = CanvasCamera(centre: CGPoint(x: 111, y: 222), zoom: 2)

        host.layout()
        let after = host.transform

        host.setFrameSize(NSSize(width: 1_000, height: 700))
        host.layout()
        host.syncToken = 1
        #expect(host.transform.scale == after.scale)
        #expect(host.transform.translation == after.translation)
    }

    @Test("the opening camera is reported through onCameraChanged")
    func reportsTheOpeningCamera() {
        let provider = LateProvider()
        provider.tiles = content
        let host = makeHost(provider)
        var seen: [CanvasCamera] = []
        host.onCameraChanged = { seen.append($0) }
        host.restoreCamera = CanvasCamera(centre: CGPoint(x: 111, y: 222), zoom: 2)

        host.layout()

        // One report, carrying the value — the app never has to read it back off a
        // (weakly held) host.
        #expect(seen.count == 1)
        #expect(Approx.equal(seen.first?.centre ?? .zero, CGPoint(x: 111, y: 222)))
    }
}
