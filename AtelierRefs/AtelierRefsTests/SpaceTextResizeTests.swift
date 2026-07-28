//
//  SpaceTextResizeTests.swift
//  AtelierRefsTests
//
//  054 §4.2–4.3 (2C · R9) / 062 — the text auto-size write path over the real
//  (temp) AppServices harness (like `SpaceArrangeTests`). The pure measurement is
//  proven in `TextMetricsTests`; these pin the MODEL contract.
//
//  062 retired the three-way resize mode. A text box now has ONE behaviour: the
//  user owns the width (create, or a resize-handle drag), and the height is always
//  derived from the text wrapped to that width. Two properties follow, and most of
//  this suite exists to hold them:
//
//    * **Truncation is unreachable.** The box is re-fitted on every edit, so text
//      can never overflow the box it is drawn in. The old `.fixed` default could,
//      and did — that was the bug.
//    * **Width only ever changes on purpose.** No text edit, restyle, or undo may
//      move `x`/`y`/`w`; only `resizeTile` does.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel text sizing (062 · width owned, height derived)")
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

    /// A copy of the row's current style with a new string.
    private func styled(_ model: SpaceModel, _ id: UUID, text: String) -> ElementStyle {
        var s = model.style(forItemID: id)
        s.text = text
        return s
    }

    /// The height the text in `id`'s current style needs at world width `width`.
    private func fittedHeight(_ model: SpaceModel, _ id: UUID, width: Double) -> Double {
        let ts = ElementRendering.textStyle(for: model.style(forItemID: id))
        let measured = TextMetrics.size(
            for: ts, maxWidth: max(1, CGFloat(width) - 2 * TextMetrics.padding))
        return Double(measured.height) + 2 * Double(TextMetrics.padding)
    }

    // MARK: - Height follows the text; x/y/w never move on their own

    @Test("a text change grows the height and freezes x/y/w/z; bumps renderRevision")
    func textChangeGrowsHeightFreezesBox() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 100, y: 200, width: 160, height: 20))
        let before = item(model, id)
        let rev = model.renderRevision

        model.updateStyle(itemID: id, style: styled(
            model, id, text: "The quick brown fox jumps over the lazy dog again and again"))
        await model.waitForWrites()
        #expect(model.renderRevision == rev + 1) // the restyle: exactly one re-sync
        await model.load()

        let now = item(model, id)
        #expect(now.h > before.h)     // wrapped to several lines
        #expect(now.w == before.w)    // width is the user's — untouched
        #expect(now.x == 100)         // anchor frozen
        #expect(now.y == 200)
        #expect(now.z == before.z)
        // …and the reload adds its own redraw signal. A reload reconciles the live
        // content in place now instead of rebuilding the host, so `renderRevision` is
        // how the canvas hears about it — there is no `.id` swap to do the job.
        #expect(model.renderRevision == rev + 2)
        #expect(model.undoActionName == "Restyle Text")
    }

    @Test("the height shrinks back when the text gets shorter, width still frozen")
    func shrinkBackReducesHeight() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))

        let long = "The quick brown fox jumps over the lazy dog again and again and again"
        model.updateStyle(itemID: id, style: styled(model, id, text: long))
        await model.waitForWrites(); await model.load()
        let tall = item(model, id)
        #expect(tall.w == 160)
        #expect(tall.h > 24)

        model.updateStyle(itemID: id, style: styled(model, id, text: "one"))
        await model.waitForWrites(); await model.load()
        let short = item(model, id)
        #expect(short.w == 160)     // still the user's width
        #expect(short.h < tall.h)   // shrink-back reduces height
    }

    @Test("the top-left anchor is invariant across grow AND shrink")
    func anchorInvariantGrowAndShrink() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 320, y: 88, width: 120, height: 24))

        for text in ["Short", "A considerably longer line of text that must wrap", "Hi"] {
            model.updateStyle(itemID: id, style: styled(model, id, text: text))
            await model.waitForWrites(); await model.load()
            let now = item(model, id)
            #expect(now.x == 320)
            #expect(now.y == 88)
            #expect(now.w == 120)
        }
    }

    // MARK: - The box always fits its text (truncation is unreachable)

    @Test("after any edit the box is exactly as tall as its wrapped text")
    func boxAlwaysFitsItsText() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 200, height: 24))

        for text in ["one", "a much longer run of words that has to wrap onto several lines", "x"] {
            model.updateStyle(itemID: id, style: styled(model, id, text: text))
            await model.waitForWrites(); await model.load()
            let now = item(model, id)
            #expect(abs(now.h - fittedHeight(model, id, width: now.w)) < 0.001)
        }
    }

    @Test("a created box is born fitting its text, not at the dragged height")
    func createdBoxIsFitted() async throws {
        let model = try await makeModel()
        // Drag out a tall box: the WIDTH is the user's, the height is not.
        let id = await seedText(model, CGRect(x: 12, y: 34, width: 240, height: 400))
        let now = item(model, id)
        #expect(now.w == 240)   // dragged width kept
        #expect(now.x == 12 && now.y == 34)
        #expect(now.h < 400)    // the default string does not need 400pt
        #expect(abs(now.h - fittedHeight(model, id, width: 240)) < 0.001)
    }

    // MARK: - Resize-handle drag (062)

    @Test("a resize sets the width and re-derives the height, as ONE undo step")
    func resizeSetsWidthAndDerivesHeight() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 400, height: 24))
        model.updateStyle(itemID: id, style: styled(
            model, id, text: "A run of text long enough to wrap once the box narrows"))
        await model.waitForWrites(); await model.load()
        let wide = item(model, id)

        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        // Drag the right handle left: the height the drag reports is ignored.
        model.resizeTile(
            tileID: tid, to: CGRect(x: 0, y: 0, width: 140, height: 9_999), in: content)
        await model.waitForWrites(); await model.load()

        let narrow = item(model, id)
        #expect(narrow.w == 140)                  // the dragged width is authoritative
        #expect(narrow.h != 9_999)                // the dragged height is NOT
        #expect(narrow.h > wide.h)                // narrower ⇒ more wrapping ⇒ taller
        #expect(abs(narrow.h - fittedHeight(model, id, width: 140)) < 0.001)
        #expect(model.undoActionName == "Resize")

        // ONE undo restores BOTH the width and the derived height.
        model.undo()
        await model.waitForWrites(); await model.load()
        let back = item(model, id)
        #expect(back.w == wide.w)
        #expect(back.h == wide.h)
    }

    @Test("a left-handle resize moves the origin as well as the width")
    func resizeFromLeftMovesOrigin() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 100, y: 50, width: 200, height: 24))
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        // Dragging the LEFT edge right keeps maxX pinned: origin moves, width shrinks.
        model.resizeTile(
            tileID: tid, to: CGRect(x: 160, y: 50, width: 140, height: 24), in: content)
        await model.waitForWrites(); await model.load()

        let now = item(model, id)
        #expect(now.x == 160)
        #expect(now.w == 140)
        #expect(now.x + now.w == 300)   // the far edge stayed put
        #expect(now.y == 50)
    }

    @Test("a resize updates the live tile in place and never rebuilds the host")
    func resizeUpdatesLiveTileWithoutRebuild() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 300, height: 24))
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        let rev = model.renderRevision
        let ver = model.contentVersion

        model.resizeTile(
            tileID: tid, to: CGRect(x: 0, y: 0, width: 180, height: 24), in: content)
        await model.waitForWrites()

        #expect(content.tile(forTileID: tid)!.w == 180)      // live content updated immediately
        #expect(model.renderRevision == rev + 1)  // re-sync in place...
        #expect(model.contentVersion == ver)      // ...never an `.id`-bound rebuild
    }

    @Test("a NON-text element keeps the dragged height — nothing is derived")
    func nonTextResizeKeepsDraggedHeight() async throws {
        // The contrast that makes the text rule visible: only text re-derives its
        // height. A frame takes the rect it was dragged to, both dimensions.
        let model = try await makeModel()
        model.addFrame(worldRect: CGRect(x: 0, y: 0, width: 200, height: 150))
        await model.waitForWrites()
        let id = model.selectedItemID!
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        model.resizeTile(
            tileID: tid, to: CGRect(x: 10, y: 20, width: 320, height: 240), in: content)
        await model.waitForWrites(); await model.load()

        let now = item(model, id)
        #expect(now.x == 10 && now.y == 20)
        #expect(now.w == 320)
        #expect(now.h == 240)   // kept, not re-derived
    }

    @Test("a resize to the same box writes nothing")
    func noOpResizeWritesNothing() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 7, y: 8, width: 220, height: 24))
        await model.load()
        let before = item(model, id)
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        let name = model.undoActionName

        model.resizeTile(
            tileID: tid,
            to: CGRect(x: before.x, y: before.y, width: before.w, height: before.h),
            in: content)
        await model.waitForWrites()

        #expect(model.undoActionName == name) // no new undo step registered
    }

    // MARK: - Legacy rows are re-fitted on load

    @Test("a stale stored height is corrected on load, in memory, with no write")
    func loadRefitsStaleTextHeights() async throws {
        // Simulates a row written before 062: a `.fixed`-era height its text outgrew.
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 200, height: 24))
        model.updateStyle(itemID: id, style: styled(
            model, id, text: "A long run of text that must wrap onto several lines indeed"))
        await model.waitForWrites(); await model.load()
        let fitted = item(model, id).h

        // Force the stored height back to something too small, as a legacy row would be.
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        model.resizeTile(
            tileID: tid, to: CGRect(x: 0, y: 0, width: 200, height: 24), in: content)
        await model.waitForWrites()

        // A fresh load must present the row at its FITTED height, not the stale one.
        await model.load()
        #expect(abs(item(model, id).h - fitted) < 0.001)
    }

    // MARK: - Exactly one undo step; ⌘Z reverts BOTH text and size

    @Test("a restyle + auto-size is ONE undo step that reverts both text and size")
    func oneUndoStepRevertsTextAndSize() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 120, height: 24))

        model.updateStyle(itemID: id, style: styled(model, id, text: "Hi"))
        await model.waitForWrites(); await model.load()
        let hA = item(model, id).h

        model.updateStyle(itemID: id, style: styled(
            model, id, text: "A considerably longer line of text that wraps several times over"))
        await model.waitForWrites(); await model.load()
        let hB = item(model, id).h
        #expect(hB > hA)
        #expect(model.undoActionName == "Restyle Text")

        // ONE undo reverts BOTH the string and the derived height…
        model.undo()
        await model.waitForWrites(); await model.load()
        #expect(model.style(forItemID: id).text == "Hi")
        #expect(item(model, id).h == hA)
        // …and the NEXT undo is the prior restyle → exactly one step per edit.
        #expect(model.undoActionName == "Restyle Text")
    }

    // MARK: - A style-only restyle re-syncs in place without a host rebuild

    @Test("a colour-only restyle writes no geometry, bumps renderRevision, never rebuilds")
    func colourRestyleNoGeometryStillReSyncs() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 5, y: 6, width: 120, height: 40))
        await model.load()
        let rev = model.renderRevision
        let ver = model.contentVersion
        let before = item(model, id)

        var s = model.style(forItemID: id)
        s.textColor = "#FF0000"
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        let now = item(model, id)
        #expect(now.w == before.w)  // geometry untouched — the string didn't change
        #expect(now.h == before.h)
        #expect(now.x == before.x && now.y == before.y && now.z == before.z)
        // The redraw rides `renderRevision` (in-memory re-sync) instead of a reload →
        // host rebuild, so a style-only edit DOES bump it exactly once...
        #expect(model.renderRevision == rev + 1)
        // ...and must NOT bump `contentVersion` (which is `.id`-bound and would tear
        // the canvas host down, resetting pan/zoom + dropping the double-click).
        #expect(model.contentVersion == ver)
        #expect(model.style(forItemID: id).textColor == "#FF0000")
    }

    @Test("a geometry-changing restyle keeps contentVersion stable (no host rebuild)")
    func restyleDoesNotBumpContentVersion() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 80, height: 30))
        await model.load()
        let hBefore = item(model, id).h
        let verBefore = model.contentVersion

        model.updateStyle(itemID: id, style: styled(
            model, id, text: "A considerably longer run of text than before"))
        await model.waitForWrites()

        // Geometry changed in memory (the box grew taller) but the host was NOT rebuilt.
        #expect(item(model, id).h != hBefore)
        #expect(model.contentVersion == verBefore)
    }

    // MARK: - A restyle after a move anchors on the LIVE position (no snap-back)

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

        var s = model.style(forItemID: id)
        s.textColor = "#00FF00"
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()

        // The live tile stays where it was dropped — no snap-back...
        #expect(content.tile(forTileID: tid)!.x == 250)
        #expect(content.tile(forTileID: tid)!.y == 180)
        // ...and `items` is de-staled to the live position too.
        #expect(item(model, id).x == 250)
        #expect(item(model, id).y == 180)
    }

    @Test("an auto-size restyle after a move grows from the moved anchor")
    func autosizeAfterMoveKeepsAnchor() async throws {
        let model = try await makeModel()
        let id = await seedText(model, CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        model.moveTile(tileID: tid, to: CGPoint(x: 300, y: 200), in: content)
        await model.waitForWrites()

        model.updateStyle(itemID: id, style: styled(
            model, id, text: "A longer run of text so the box must grow taller"))
        await model.waitForWrites()

        // Top-left anchor is the MOVED position, not the origin it was created at.
        #expect(item(model, id).x == 300)
        #expect(item(model, id).y == 200)
    }
}
