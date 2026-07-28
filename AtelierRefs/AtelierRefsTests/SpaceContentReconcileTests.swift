//
//  SpaceContentReconcileTests.swift
//  AtelierRefsTests
//
//  A reload updates the `SpaceContent` the renderer already holds instead of handing
//  it a new one, so the `CanvasHostView` is never rebuilt and the user's pan / zoom is
//  never thrown away. Two properties make that safe, and both are pinned here:
//
//  1. **A surviving row keeps its tile id.** Everything interactive is keyed on that
//     id — the selection, an open inline editor, a live drag, the format chrome — so a
//     renumbering id would silently repoint all of them at different rows.
//  2. **An id is never reused.** A tile that goes away takes its id with it, so a
//     stale reference resolves to nothing rather than to whatever moved into its slot.
//
//  The id used to BE the array index, and rows arrive ordered by `(z, id)` — so a
//  bring-to-front already renumbered every tile. That was survivable only because a
//  z-op rebuilt the host and reset all the state keyed on those ids. `zOrderChange...`
//  below is that latent bug, made explicit.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceContent: reconcile in place")
struct SpaceContentReconcileTests {

    // MARK: - Fixtures

    private func assetDetail(id: UUID = UUID(), z: Int, x: Double = 0, hash: String? = nil)
        -> SpaceItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: hash ?? UUID().uuidString,
            mimeType: "image/png", width: 120, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = SpaceItem(
            id: id, spaceID: UUID(), kind: .asset, assetID: assetID,
            x: x, y: 0, w: 120, h: 90, z: z, style: nil,
            createdAt: Date(), updatedAt: Date())
        return SpaceItemDetail(item: item, asset: asset, source: source)
    }

    /// The same row with a different placement — what a reload brings back after a
    /// move, an align, or the undo of either.
    private func moved(_ detail: SpaceItemDetail, x: Double, z: Int? = nil) -> SpaceItemDetail {
        var item = detail.item
        item.x = x
        if let z { item.z = z }
        return SpaceItemDetail(item: item, asset: detail.asset, source: detail.source)
    }

    /// An asset row whose asset failed to resolve — not drawable, so it gets no tile.
    private func unresolved(_ detail: SpaceItemDetail) -> SpaceItemDetail {
        SpaceItemDetail(item: detail.item, asset: nil, source: detail.source)
    }

    private func textDetail(id: UUID = UUID(), text: String, z: Int) -> SpaceItemDetail {
        let item = SpaceItem(
            id: id, spaceID: UUID(), kind: .text, assetID: nil,
            x: 0, y: 0, w: 200, h: 60, z: z,
            style: ElementStyle(text: text).jsonString(), createdAt: Date(), updatedAt: Date())
        return SpaceItemDetail(item: item, asset: nil, source: nil)
    }

    private func makeContent(_ details: [SpaceItemDetail]) -> SpaceContent {
        SpaceContent(items: details, store: MediaStore(root: FileManager.default.temporaryDirectory))
    }

    private func tileID(_ content: SpaceContent, _ detail: SpaceItemDetail) -> Int? {
        content.tileID(forSpaceItemID: detail.item.id)
    }

    // MARK: - Identity across a reload

    @Test("a survivor keeps its tile id when another row is inserted")
    func insertKeepsSurvivorIDs() {
        let a = assetDetail(z: 0), b = assetDetail(z: 1)
        let content = makeContent([a, b])
        let idA = tileID(content, a)!, idB = tileID(content, b)!

        let c = assetDetail(z: 2)
        #expect(content.reconcile(items: [a, b, c]) == true) // the SET changed

        #expect(tileID(content, a) == idA)
        #expect(tileID(content, b) == idB)
        #expect(content.tiles.count == 3)
        // The newcomer got an identity of its own, distinct from both survivors.
        let idC = tileID(content, c)!
        #expect(idC != idA && idC != idB)
    }

    @Test("a survivor keeps its tile id when an EARLIER row is removed")
    func removalDoesNotRenumber() {
        let a = assetDetail(z: 0), b = assetDetail(z: 1), c = assetDetail(z: 2)
        let content = makeContent([a, b, c])
        let idB = tileID(content, b)!, idC = tileID(content, c)!

        #expect(content.reconcile(items: [b, c]) == true)

        // Under the old index-as-id scheme both of these would have shifted down by
        // one, quietly repointing the selection and any open editor at another row.
        #expect(tileID(content, b) == idB)
        #expect(tileID(content, c) == idC)
        #expect(tileID(content, a) == nil)
        #expect(content.tiles.count == 2)
    }

    @Test("a z-order change reorders the rows but renumbers nothing")
    func zOrderChangeDoesNotRenumber() {
        let a = assetDetail(z: 0), b = assetDetail(z: 1), c = assetDetail(z: 2)
        let content = makeContent([a, b, c])
        let ids = [tileID(content, a)!, tileID(content, b)!, tileID(content, c)!]

        // `AppServices.spaceItems` orders by (z, id), so sending `a` to the front
        // re-sorts the array the reload hands back.
        let reordered = [moved(b, x: 0, z: 1), moved(c, x: 0, z: 2), moved(a, x: 0, z: 3)]
        #expect(content.reconcile(items: reordered) == false) // same SET, new order

        #expect([tileID(content, a)!, tileID(content, b)!, tileID(content, c)!] == ids)
        // …and the new z actually landed.
        #expect(content.tile(forTileID: ids[0])!.z == 3)
    }

    @Test("a removed id is never handed out again")
    func idsAreNeverReused() {
        let a = assetDetail(z: 0)
        let content = makeContent([a])
        let idA = tileID(content, a)!

        content.reconcile(items: [])
        #expect(content.tiles.isEmpty)

        let b = assetDetail(z: 0)
        content.reconcile(items: [b])
        // A stale reference to `idA` must resolve to nothing, never to whatever took
        // its place — which is exactly what an index-as-id would have given it.
        #expect(tileID(content, b)! != idA)
        #expect(content.tile(forTileID: idA) == nil)
        #expect(content.detail(forTileID: idA) == nil)
    }

    // MARK: - Content refresh

    @Test("a survivor takes the incoming geometry — a reload is the durable truth")
    func survivorTakesIncomingGeometry() {
        let a = assetDetail(z: 0, x: 10)
        let content = makeContent([a])
        let id = tileID(content, a)!

        content.reconcile(items: [moved(a, x: 999)])
        #expect(content.tile(forTileID: id)!.x == 999)
        #expect(content.detail(forTileID: id)!.item.x == 999)
    }

    @Test("a survivor's drawn content is re-derived, not stale")
    func survivorRefreshesDrawnContent() {
        let t = textDetail(text: "before", z: 0)
        let content = makeContent([t])
        let id = tileID(content, t)!

        content.reconcile(items: [textDetail(id: t.item.id, text: "after", z: 0)])
        guard case .text(let style) = content.content(for: content.tile(forTileID: id)!) else {
            Issue.record("a text row should still draw as .text"); return
        }
        #expect(style.string == "after")
    }

    @Test("an asset row that stops resolving loses its tile; one that starts, gains one")
    func drawabilityIsRecomputed() {
        let a = assetDetail(z: 0)
        let content = makeContent([a])
        #expect(content.tiles.count == 1)

        #expect(content.reconcile(items: [unresolved(a)]) == true)
        #expect(content.tiles.isEmpty)
        #expect(tileID(content, a) == nil)

        #expect(content.reconcile(items: [a]) == true)
        #expect(content.tiles.count == 1)
    }

    // MARK: - The return value

    @Test("reconcile reports a SET change only when an id appeared or vanished")
    func setChangeIsAboutIdentityNotGeometry() {
        let a = assetDetail(z: 0), b = assetDetail(z: 1)
        let content = makeContent([a, b])

        #expect(content.reconcile(items: [a, b]) == false)              // nothing moved
        #expect(content.reconcile(items: [moved(a, x: 77), b]) == false) // geometry only
        #expect(content.reconcile(items: [a]) == true)                   // b vanished
        #expect(content.reconcile(items: [a, b]) == true)                // b came back
    }

    @Test("reconciling an empty board, and reconciling to empty, are both safe")
    func degenerateReconciles() {
        let content = makeContent([])
        #expect(content.reconcile(items: []) == false)
        #expect(content.tiles.isEmpty)

        let a = assetDetail(z: 0)
        #expect(content.reconcile(items: [a]) == true)
        #expect(content.reconcile(items: []) == true)
        #expect(content.tiles.isEmpty)
        #expect(content.rows.isEmpty)
        #expect(content.contentByTile.isEmpty)
    }

    // MARK: - Lookups stay consistent afterwards

    @Test("every id-keyed accessor agrees after an insert, a removal and a reorder")
    func accessorsStayConsistent() {
        let a = assetDetail(z: 0), b = assetDetail(z: 1), c = assetDetail(z: 2)
        let content = makeContent([a, b, c])
        content.reconcile(items: [c, a])                       // drop b, reorder
        let d = assetDetail(z: 5)
        content.reconcile(items: [c, a, d])                     // add d

        for detail in [a, c, d] {
            let id = tileID(content, detail)!
            #expect(content.tile(forTileID: id)?.id == id)
            #expect(content.detail(forTileID: id)?.item.id == detail.item.id)
            #expect(content.spaceItemID(forTileID: id) == detail.item.id)
        }
        #expect(tileID(content, b) == nil)
        // The arrays stay index-aligned to each other, whatever the ids are.
        #expect(content.tiles.count == content.rows.count)
        #expect(content.tiles.count == content.contentByTile.count)
        #expect(Set(content.tiles.map(\.id)).count == content.tiles.count) // ids unique
    }

    @Test("frame membership reports tile IDS, not array positions")
    func groupMembersReturnsIDs() {
        // Removing an earlier row makes id and index disagree, which is precisely when
        // returning `tiles.indices` instead of `tile.id` would start pointing the
        // carried-drag set and the membership wash at the wrong tiles.
        let filler = assetDetail(z: 0)
        let frameItem = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .frame, assetID: nil,
            x: 0, y: 0, w: 500, h: 500, z: -1,
            style: ElementStyle(strokeColor: "#000000", strokeWidth: 2).jsonString(),
            createdAt: Date(), updatedAt: Date())
        let frame = SpaceItemDetail(item: frameItem, asset: nil, source: nil)
        let inside = assetDetail(z: 1, x: 100)

        let content = makeContent([filler, frame, inside])
        content.reconcile(items: [frame, inside])               // filler leaves

        let frameID = tileID(content, frame)!
        let insideID = tileID(content, inside)!
        #expect(frameID != content.tiles.firstIndex { $0.id == frameID }) // id ≠ index now
        #expect(content.groupMembers(forDraggedTileID: frameID) == [insideID])
    }
}
