//
//  EngineMembershipWashTests.swift
//  CanvasRendererTests
//
//  100 · P3 — the SECOND driver of the membership highlight.
//
//  062 built the mechanism for one gesture: while a frame is being resized, the tiles
//  it will contain on release are washed, because membership is derived from
//  containment and a resize therefore changes it invisibly. ⌘G has the same defect
//  from the other end — a frame drawn at a selection's bounding box adopts whatever
//  sat between the tiles you picked (100 §3) — so it raises the same wash, timed,
//  over the adopted ids only.
//
//  Two drivers, one field, one meaning on screen. What these tests are really pinning
//  is the precedence between them: the resize wins in both directions, and a wash's
//  self-clear must never be able to fire into a gesture that started after it.
//

import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Engine membership wash — the ⌘G driver (100 · P3)")
struct EngineMembershipWashTests {

    /// The same containment-based provider `EngineFrameMembershipTests` uses, so the
    /// resize half of these tests exercises the real rule rather than a stub.
    private struct FrameProvider: TileProvider {
        let tiles: [Tile]
        let frameIDs: Set<Int>

        func content(for tile: Tile) -> TileContent {
            frameIDs.contains(tile.id)
                ? .frame(FrameStyle(fill: nil, stroke: nil, strokeWidth: 0, cornerRadius: 0))
                : .image
        }

        func groupMembers(forDraggedTileID id: Int) -> [Int] {
            guard tiles.indices.contains(id) else { return [] }
            return groupMembers(forTileID: id, in: tiles[id].worldFrame)
        }

        func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int] {
            guard frameIDs.contains(id) else { return [] }
            return tiles.indices.filter { i in
                i != id && worldRect.contains(CGPoint(x: tiles[i].worldFrame.midX,
                                                      y: tiles[i].worldFrame.midY))
            }
        }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// Tile 0 is a frame at 0…200; tile 2's centre (x = 100) is inside it and tile 1's
    /// (x = 250) is not — the same fixture 062's preview tests are built on.
    private func engine() -> CanvasEngine {
        let tiles = [
            Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
            Tile(id: 1, x: 240, y: 80, w: 20, h: 20, z: 1),
            Tile(id: 2, x: 90, y: 90, w: 20, h: 20, z: 1),
        ]
        let e = CanvasEngine(
            provider: FrameProvider(tiles: tiles, frameIDs: [0]), images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        e.setSelected(0)
        return e
    }

    /// A wash short enough to expire inside a test, and a wait comfortably past it.
    /// The shipped duration is a UI judgement (``CanvasEngine/membershipWashDuration``)
    /// and nothing here should depend on its value — only on the fact that it elapses.
    private static let brief: Duration = .milliseconds(40)
    private static let pastBrief: Duration = .milliseconds(400)

    /// The layers actually drawn for the wash, found by their fill. Distinct from
    /// ``CanvasEngine/prospectiveMembers``, which is only the intent: this asserts the
    /// new driver reaches the SAME drawing the resize preview uses, rather than having
    /// quietly grown a second highlight.
    private func washLayerCount(_ e: CanvasEngine) -> Int {
        (e.rootLayer.sublayers ?? []).count { $0.backgroundColor == CanvasChrome.membershipWash }
    }

    @Test("a wash raises the set it is given, and draws it")
    func washRaisesTheSet() {
        let e = engine()
        #expect(e.prospectiveMembers.isEmpty)

        e.washMembership([1, 2], for: Self.brief)
        #expect(e.prospectiveMembers == [1, 2])
        // Syncs on the way in rather than waiting for the next frame — the adopted
        // tiles already exist, so there is nothing to wait for.
        #expect(washLayerCount(e) == 2)
    }

    @Test("a wash clears itself once its duration elapses")
    func washClearsItself() async throws {
        let e = engine()
        e.washMembership([1, 2], for: Self.brief)
        #expect(!e.prospectiveMembers.isEmpty)

        try await Task.sleep(for: Self.pastBrief)
        #expect(e.prospectiveMembers.isEmpty)
        // And gives its layers back — the expiry syncs, or the fill would stay on
        // screen with nothing behind it in the model.
        #expect(washLayerCount(e) == 0)
    }

    @Test("an empty set raises nothing at all")
    func emptySetRaisesNothing() {
        let e = engine()
        e.washMembership([], for: Self.brief)
        #expect(e.prospectiveMembers.isEmpty)
        #expect(washLayerCount(e) == 0)
    }

    @Test("an empty set does not retract a wash already up")
    func emptySetDoesNotRetract() {
        // Having nothing to report is not the same as withdrawing an earlier report —
        // and ⌘G on a selection that adopts nothing is the COMMON case, so if empty
        // cleared, every silent group would cancel the one before it.
        let e = engine()
        e.washMembership([2], for: Self.brief)
        e.washMembership([], for: Self.brief)
        #expect(e.prospectiveMembers == [2])
    }

    @Test("a resize starting mid-wash retracts it immediately")
    func resizeRetractsAStandingWash() {
        let e = engine()
        e.washMembership([1, 2], for: Self.brief)

        e.beginResize(tileID: 0, handle: .right)
        // Not merely overwritten on the first tick: between mouse-down and the first
        // move the wash would otherwise still be claiming membership for a rect the
        // user has already stopped caring about.
        #expect(e.prospectiveMembers.isEmpty)
        #expect(washLayerCount(e) == 0)
    }

    @Test("an expiring wash cannot clear a resize's preview")
    func expiryCannotStompTheResize() async throws {
        // The interaction the shared field makes possible: ⌘G raises a wash, the user
        // grabs a handle before it lapses, and the pending timer wakes up inside a live
        // resize. `beginResize` cancels it, so the preview survives its deadline.
        let e = engine()
        e.washMembership([1, 2], for: Self.brief)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 0), snapping: false)
        #expect(e.prospectiveMembers == [1, 2]) // the RESIZE's set now, not the wash's

        try await Task.sleep(for: Self.pastBrief)
        #expect(e.prospectiveMembers == [1, 2])
        #expect(washLayerCount(e) == 2)

        e.endResize()
        e.sync()
        #expect(e.prospectiveMembers.isEmpty)
    }

    @Test("a wash refuses to raise while a resize is live")
    func washYieldsToALiveResize() {
        // The other direction of the same precedence. A resize preview is a promise
        // about a rect the user is actively aiming; a creation wash is a note about one
        // they already committed, so it waits rather than overwriting a tick.
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 50, y: 0), snapping: false)
        #expect(e.prospectiveMembers.isEmpty) // shrunk past tile 2's centre

        e.washMembership([1, 2], for: Self.brief)
        #expect(e.prospectiveMembers.isEmpty)
    }

    @Test("a second wash replaces the first, and only the second's timer survives")
    func laterWashOwnsTheField() async throws {
        let e = engine()
        e.washMembership([1], for: Self.brief)
        e.washMembership([2], for: .milliseconds(250))
        #expect(e.prospectiveMembers == [2])

        // Past the FIRST deadline: the superseded timer must have been cancelled, or it
        // would clear a set it never raised.
        try await Task.sleep(for: .milliseconds(150))
        #expect(e.prospectiveMembers == [2])

        try await Task.sleep(for: Self.pastBrief)
        #expect(e.prospectiveMembers.isEmpty)
    }
}
