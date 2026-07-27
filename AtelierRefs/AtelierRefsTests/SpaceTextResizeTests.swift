//
//  SpaceTextResizeTests.swift
//  AtelierRefsTests
//
//  054 §4.2–4.3 (2C · R9) — the auto-size write path over the real (temp)
//  AppServices harness (like `SpaceArrangeTests`). The pure measurement is proven
//  in `TextMetricsTests`; these pin the MODEL contract: an `autoWidth` text change
//  updates `w` and freezes `x`/`y`/`z`; the top-left anchor is invariant across
//  grow AND shrink; `autoHeight` shrink-back reduces `h` with `w` frozen; a restyle
//  + auto-size is exactly ONE undo step that reverts BOTH text and size;
//  `fixed→autoWidth` re-fits and `autoWidth→fixed` freezes; a `.fixed` restyle
//  writes NO geometry yet still re-syncs in place (bumps `renderRevision`, never
//  `contentVersion` — the restyle applies to the live content without a host rebuild).
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel text resize-mode (2C · 054 §4)")
struct SpaceTextResizeTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-textresize-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Text Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    /// Add one text element at `rect`; returns its id (the add selects it).
    private func seedText(_ model: SpaceModel, _ rect: CGRect) async -> UUID {
        model.addText(worldRect: rect)
        await model.waitForWrites()
        return model.selectedItemID!
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem {
        model.items.first { $0.item.id == id }!.item
    }

    /// A copy of the row's current style with the given resize token + text.
    private func styled(_ model: SpaceModel, _ id: UUID,
                        resize: TextResize, text: String) -> ElementStyle {
        var s = model.style(forItemID: id)
        s.resizeMode = resize.rawValue
        s.text = text
        return s
    }

    // MARK: - autoWidth updates w, freezes x/y/z

    @Test("an autoWidth text change updates w and freezes x/y/z; bumps renderRevision")
    func autoWidthUpdatesWidthFreezesAnchor() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 100, y: 200, width: 40, height: 20))
        let before = item(model, id)
        let rev = model.renderRevision

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth, text: "Hello World"))
        await model.waitForWrites()
        await model.load()

        let now = item(model, id)
        #expect(now.w != before.w)   // width follows the text
        #expect(now.w > before.w)    // "Hello World" @ 22pt is far wider than 40
        #expect(now.x == 100)        // anchor frozen
        #expect(now.y == 200)
        #expect(now.z == before.z)
        #expect(model.renderRevision == rev + 1) // geometry changed → one re-sync
        #expect(model.undoActionName == "Restyle Text")
    }

    // MARK: - anchor invariance across grow AND shrink

    @Test("top-left anchor is invariant across grow and shrink (autoWidth)")
    func anchorInvariantGrowAndShrink() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 320, y: 88, width: 30, height: 24))

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth, text: "Short"))
        await model.waitForWrites(); await model.load()
        let small = item(model, id)

        // Grow: a much longer line.
        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth,
                                                     text: "A considerably longer line of text"))
        await model.waitForWrites(); await model.load()
        let grown = item(model, id)
        #expect(grown.w > small.w)

        // Shrink: back to a short line.
        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth, text: "Hi"))
        await model.waitForWrites(); await model.load()
        let shrunk = item(model, id)
        #expect(shrunk.w < grown.w)

        // x/y/z never moved through either transition.
        for s in [small, grown, shrunk] {
            #expect(s.x == 320)
            #expect(s.y == 88)
            #expect(s.z == small.z)
        }
    }

    // MARK: - autoHeight shrink-back reduces h, w frozen

    @Test("autoHeight grows then shrinks height while width stays the create-time width")
    func autoHeightShrinkBackReducesHeight() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))

        let long = "The quick brown fox jumps over the lazy dog again and again and again"
        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoHeight, text: long))
        await model.waitForWrites(); await model.load()
        let tall = item(model, id)
        #expect(tall.w == 160)     // width frozen at the create-time box
        #expect(tall.h > 24)       // wrapped to several lines

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoHeight, text: "one"))
        await model.waitForWrites(); await model.load()
        let shortH = item(model, id)
        #expect(shortH.w == 160)   // still frozen
        #expect(shortH.h < tall.h) // shrink-back reduces height
    }

    // MARK: - exactly one undo step; ⌘Z reverts BOTH text and size

    @Test("a restyle + auto-size is ONE undo step that reverts both text and size")
    func oneUndoStepRevertsTextAndSize() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 50, height: 24))

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth, text: "Hi"))
        await model.waitForWrites(); await model.load()
        let wA = item(model, id).w

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth,
                                                    text: "A considerably longer line of text"))
        await model.waitForWrites(); await model.load()
        let wB = item(model, id).w
        #expect(wB > wA)
        #expect(model.undoActionName == "Restyle Text")

        // ONE undo reverts BOTH the string and the derived width…
        model.undo()
        await model.waitForWrites(); await model.load()
        #expect(model.style(forItemID: id).text == "Hi")
        #expect(item(model, id).w == wA)
        // …and the NEXT undo is the prior restyle → exactly one step per edit.
        #expect(model.undoActionName == "Restyle Text")
    }

    // MARK: - fixed ↔ auto transitions

    @Test("fixed → autoWidth re-fits the box to the text")
    func fixedToAutoWidthRefits() async throws {
        let model = try await makeModel()
        // A wide fixed box holding the default short "Text".
        let id = await seedText(model, CGRect(x: 10, y: 10, width: 300, height: 50))
        #expect(item(model, id).w == 300)

        // Switch to autoWidth WITHOUT changing the string → it re-fits to "Text".
        var s = model.style(forItemID: id)
        s.resizeMode = TextResize.autoWidth.rawValue
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites(); await model.load()
        let now = item(model, id)
        #expect(now.w != 300)  // re-fit to the (much narrower) text
        #expect(now.x == 10)   // anchor frozen
        #expect(now.y == 10)
    }

    @Test("autoWidth → fixed freezes the box; later text changes do not resize it")
    func autoWidthToFixedFreezes() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 40, height: 24))

        model.updateStyle(itemID: id, style: styled(model, id, resize: .autoWidth, text: "Hi"))
        await model.waitForWrites(); await model.load()
        let wAuto = item(model, id).w

        // Switch to fixed (string unchanged) → NO geometry write, box stays.
        var f = model.style(forItemID: id)
        f.resizeMode = TextResize.fixed.rawValue
        model.updateStyle(itemID: id, style: f)
        await model.waitForWrites(); await model.load()
        #expect(item(model, id).w == wAuto)

        // A later text change while fixed must NOT resize the frozen box.
        model.updateStyle(itemID: id, style: styled(model, id, resize: .fixed,
                                                    text: "A very long line that would be wide"))
        await model.waitForWrites(); await model.load()
        #expect(item(model, id).w == wAuto) // frozen
    }

    // MARK: - .fixed restyle writes no geometry but still re-syncs in place

    @Test("a .fixed restyle writes no geometry, bumps renderRevision, and never rebuilds the host")
    func fixedRestyleNoGeometryStillReSyncs() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 5, y: 6, width: 120, height: 40))
        let rev = model.renderRevision
        let ver = model.contentVersion
        let before = item(model, id)

        // A style-only change (colour) on a fixed box.
        var s = model.style(forItemID: id)
        s.textColor = "#FF0000"
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        let now = item(model, id)
        #expect(now.w == before.w)              // geometry untouched
        #expect(now.h == before.h)
        #expect(now.x == before.x && now.y == before.y && now.z == before.z)
        // The redraw now rides `renderRevision` (in-memory re-sync) instead of a
        // reload → host rebuild, so a style-only edit DOES bump it exactly once...
        #expect(model.renderRevision == rev + 1)
        // ...and must NOT bump `contentVersion` (which is `.id`-bound and would tear
        // the canvas host down, resetting pan/zoom + dropping the double-click).
        #expect(model.contentVersion == ver)
        // The change is live in `items` immediately, with no reload.
        #expect(model.style(forItemID: id).textColor == "#FF0000")
    }

    // MARK: - a restyle never rebuilds the host (the core in-place-restyle fix)

    @Test("an autoWidth restyle keeps contentVersion stable (no host rebuild)")
    func restyleDoesNotBumpContentVersion() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 80, height: 30))

        // Switch to autoWidth + change the string — a geometry-changing restyle.
        var s = model.style(forItemID: id)
        s.resizeMode = TextResize.autoWidth.rawValue
        s.text = "A considerably longer run of text than before"
        let verBefore = model.contentVersion
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        // Geometry changed in memory (auto-width grew) but the host was NOT rebuilt.
        #expect(item(model, id).w != 80)
        #expect(model.contentVersion == verBefore)
    }

    // MARK: - a restyle after a move anchors on the LIVE position (no snap-back)

    @Test("a style-only restyle after a move keeps the moved position")
    func restyleAfterMoveKeepsPosition() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        // Move it — a drag persists with `reload: false`, so `items` x/y goes stale
        // while the live tile (and the DB) hold the moved position.
        model.moveTile(tileID: tid, to: CGPoint(x: 250, y: 180), in: content)
        await model.waitForWrites()

        // A style-only edit must anchor on the LIVE (moved) position, not stale items.
        var s = model.style(forItemID: id)
        s.textColor = "#00FF00"
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        // The live tile stays where it was dropped — no snap-back...
        #expect(content.tiles[tid].x == 250)
        #expect(content.tiles[tid].y == 180)
        // ...and `items` is de-staled to the live position too.
        #expect(item(model, id).x == 250)
        #expect(item(model, id).y == 180)
    }

    // MARK: - an auto-size restyle after a move keeps the moved anchor

    @Test("an autoWidth restyle after a move grows from the moved anchor")
    func autosizeAfterMoveKeepsAnchor() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        model.moveTile(tileID: tid, to: CGPoint(x: 300, y: 200), in: content)
        await model.waitForWrites()

        var s = model.style(forItemID: id)
        s.resizeMode = TextResize.autoWidth.rawValue
        s.text = "A longer run of text so the box must grow in width"
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        // Top-left anchor is the MOVED position, not the origin it was created at.
        #expect(item(model, id).x == 300)
        #expect(item(model, id).y == 200)
        #expect(content.tiles[tid].x == 300)
    }
}
