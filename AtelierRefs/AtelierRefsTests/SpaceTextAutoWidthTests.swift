//
//  SpaceTextAutoWidthTests.swift
//  AtelierRefsTests
//
//  063 §3.2 / §4 Stage 2 — a text box that derives its own WIDTH.
//
//  `SpaceTextResizeTests` holds 062's contract (the user owns the width, the height
//  is derived) and every one of its assertions must keep passing: auto-width is
//  opt-in, so a box that does not carry the flag behaves exactly as it did. What is
//  pinned here is the second behaviour — and, as much as anything, the boundary
//  between the two.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel text auto-width (063 · width derived, x anchored)")
struct SpaceTextAutoWidthTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-autowidth-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Text Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem {
        model.items.first { $0.item.id == id }!.item
    }

    /// Seed a box the way a CLICK does — an origin-only rect (063 §3.2).
    private func seedClicked(_ model: SpaceModel, at point: CGPoint) async -> UUID {
        model.addText(worldRect: CGRect(origin: point, size: .zero))
        await model.waitForWrites()
        return model.selectedItemID!
    }

    private func restyle(
        _ model: SpaceModel, _ id: UUID,
        text: String? = nil, align: TextAlign? = nil, hugs: Bool? = nil
    ) async {
        var s = model.style(forItemID: id)
        if let text { s.text = text }
        if let align { s.textAlign = align.rawValue }
        if let hugs { s.textAutoWidth = hugs }
        model.updateStyle(itemID: id, style: s)
        await model.waitForWrites()
        await model.load()
    }

    /// The outer width a hugging box should settle at for `text`.
    private func huggedWidth(_ model: SpaceModel, _ id: UUID) -> Double {
        let ts = ElementRendering.textStyle(for: model.style(forItemID: id))
        let measured = TextMetrics.size(for: ts, hugging: true, outerWidth: 0)
        return Double(measured.width) + 2 * Double(TextMetrics.padding)
    }

    // MARK: - anchoredMinX (pure)

    @Test("left-aligned text grows and shrinks from a stationary LEFT edge")
    func anchorLeft() {
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .left) == 100)
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .left) == 100)
    }

    @Test("right-aligned text grows and shrinks from a stationary RIGHT edge")
    func anchorRight() {
        // Growing 50 → 80 pushes the left edge back by 30; the right edge stays at 150.
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .right) == 70)
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .right) == 130)
    }

    @Test("centred text grows both ways — the left edge moves back by half")
    func anchorCenterGrow() {
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .center) == 85)
    }

    @Test("centred text shrinks both ways — the left edge moves in by half")
    func anchorCenterShrink() {
        #expect(canvasInlineEditorAnchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .center) == 115)
    }

    @Test("the centre is what a centred box actually holds still")
    func anchorCenterKeepsTheCentre() {
        let oldMinX: CGFloat = 100, oldWidth: CGFloat = 50, newWidth: CGFloat = 80
        let newX = canvasInlineEditorAnchoredMinX(
            oldMinX: oldMinX, oldWidth: oldWidth, newWidth: newWidth, alignment: .center)
        #expect(newX + newWidth / 2 == oldMinX + oldWidth / 2)
    }

    @Test("an unchanged width never moves the box, whatever the alignment")
    func anchorNoOpOnEqualWidth() {
        for align in TextAlignment.allCases {
            #expect(canvasInlineEditorAnchoredMinX(
                oldMinX: 42, oldWidth: 77, newWidth: 77, alignment: align) == 42)
        }
    }

    // MARK: - Birth state

    @Test("a CLICK-placed box is born hugging, snug around its text")
    func clickedBoxIsBornHugging() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: CGPoint(x: 40, y: 60))
        let born = item(model, id)

        #expect(model.style(forItemID: id).hugsWidth)
        #expect(born.x == 40 && born.y == 60)
        #expect(born.w == huggedWidth(model, id))
        // The point of the change: not the 260 literal every click used to inherit.
        #expect(born.w < 260)
    }

    @Test("a DRAG-placed box is fixed at the width the user dragged")
    func draggedBoxIsFixed() async throws {
        let model = try await makeModel()
        model.addText(worldRect: CGRect(x: 0, y: 0, width: 300, height: 80))
        await model.waitForWrites()
        let id = model.selectedItemID!

        #expect(model.style(forItemID: id).hugsWidth == false)
        #expect(item(model, id).w == 300)   // they chose it; honour it
    }

    @Test("pasted text stays fixed-width — a paragraph is a column, not a line")
    func pastedTextIsFixed() async throws {
        let model = try await makeModel()
        model.pasteText("A reasonably long sentence pasted in from somewhere else",
                        at: CGPoint(x: 0, y: 0))
        await model.waitForWrites()
        let id = model.selectedItemID!

        #expect(model.style(forItemID: id).hugsWidth == false)
        #expect(item(model, id).w == Double(SpaceModel.pastedTextWidth))
    }

    // MARK: - Growth

    @Test("a hugging box grows sideways as the text gets longer, and shrinks back")
    func hugGrowsAndShrinks() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)

        await restyle(model, id, text: "Hi")
        let short = item(model, id)
        await restyle(model, id, text: "A considerably longer single line of text")
        let long = item(model, id)
        await restyle(model, id, text: "Hi")
        let back = item(model, id)

        #expect(long.w > short.w)
        #expect(back.w == short.w)          // exactly back, not approximately
        // …and it never wrapped on the way: one line throughout.
        #expect(long.h == short.h)
    }

    @Test("a fixed box is untouched by all of this — 062's contract holds")
    func fixedBoxUnaffected() async throws {
        let model = try await makeModel()
        model.addText(worldRect: CGRect(x: 10, y: 20, width: 160, height: 24))
        await model.waitForWrites()
        let id = model.selectedItemID!

        await restyle(model, id, text: "A line long enough that it has to wrap in 160 units")
        let now = item(model, id)
        #expect(now.x == 10 && now.w == 160)   // width still the user's
        #expect(now.h > 24)                    // height still derived
    }

    @Test("the anchor edge follows the alignment through the real write path",
          arguments: [TextAlign.left, .right, .center])
    func anchorAppliedOnRestyle(_ align: TextAlign) async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: CGPoint(x: 500, y: 0))
        await restyle(model, id, text: "Hi", align: align)
        let before = item(model, id)

        await restyle(model, id, text: "Something appreciably wider than before")
        let after = item(model, id)
        #expect(after.w > before.w)

        switch align {
        case .left:
            #expect(after.x == before.x)
        case .right:
            #expect(after.x + after.w == before.x + before.w)
        case .center:
            #expect(after.x + after.w / 2 == before.x + before.w / 2)
        }
    }

    // MARK: - The cap

    @Test("past the cap a hugging box wraps instead of growing, and recovers")
    func capWrapsRatherThanRuns() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)

        let paragraph = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 20)
        await restyle(model, id, text: paragraph)
        let capped = item(model, id)
        let maxOuter = Double(TextMetrics.maxAutoWidth + 2 * TextMetrics.padding)
        #expect(capped.w <= maxOuter)
        #expect(capped.h > 40)   // it grew downward instead

        // The flag never changed, so shrinking the text lets it hug again — this is
        // what makes the cap a wrap rather than a mode switch.
        #expect(model.style(forItemID: id).hugsWidth)
        await restyle(model, id, text: "Hi")
        #expect(item(model, id).w == huggedWidth(model, id))
    }

    // MARK: - Conversion (§3.4)

    @Test("a side drag turns hugging off and keeps the width you dropped")
    func sideDragConvertsToFixed() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)
        await restyle(model, id, text: "Hi")
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        model.resizeTile(tileID: tid, to: CGRect(x: 0, y: 0, width: 240, height: 30), in: content)
        await model.waitForWrites()
        await model.load()

        #expect(model.style(forItemID: id).hugsWidth == false)
        #expect(item(model, id).w == 240)
        // …and it stays 240 through the next edit, which is the point of converting.
        await restyle(model, id, text: "Hi again")
        #expect(item(model, id).w == 240)
    }

    @Test("a top/bottom drag changes no width, so the box keeps hugging")
    func verticalDragKeepsHugging() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)
        await restyle(model, id, text: "Hi")
        let before = item(model, id)
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        // The same width, a different y/height — what a `.bottom` handle produces.
        model.resizeTile(
            tileID: tid,
            to: CGRect(x: before.x, y: before.y, width: before.w, height: before.h + 50),
            in: content)
        await model.waitForWrites()
        await model.load()

        #expect(model.style(forItemID: id).hugsWidth)
        #expect(item(model, id).w == before.w)   // re-hugged, not stretched
    }

    @Test("ONE undo restores both the width and the hugging state")
    func oneUndoRevertsTheConversion() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)
        await restyle(model, id, text: "Hi")
        let before = item(model, id)
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        model.resizeTile(tileID: tid, to: CGRect(x: 0, y: 0, width: 240, height: 30), in: content)
        await model.waitForWrites()
        #expect(model.undoActionName == "Resize")

        model.undo()
        await model.waitForWrites()
        await model.load()
        #expect(model.style(forItemID: id).hugsWidth)   // the flag came back…
        #expect(item(model, id).w == before.w)          // …and so did the width
    }

    @Test("resizing a box that never hugged is unchanged — one undo entry, no restyle")
    func fixedResizeIsUntouched() async throws {
        let model = try await makeModel()
        model.addText(worldRect: CGRect(x: 0, y: 0, width: 160, height: 24))
        await model.waitForWrites()
        let id = model.selectedItemID!
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!

        model.resizeTile(tileID: tid, to: CGRect(x: 0, y: 0, width: 260, height: 24), in: content)
        await model.waitForWrites()
        await model.load()
        #expect(item(model, id).w == 260)
        #expect(model.style(forItemID: id).hugsWidth == false)
        #expect(model.undoActionName == "Resize")
    }

    // MARK: - The control (§3.5)

    @Test("switching to Fixed freezes the box at the width it had just hugged")
    func fixedFreezesTheCurrentWidth() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)
        await restyle(model, id, text: "A line of text")
        let hugged = item(model, id).w

        await restyle(model, id, hugs: false)
        #expect(item(model, id).w == hugged)   // frozen where it was, not reset

        // …and it now behaves as any fixed box: the text grows downward.
        await restyle(model, id, text: "A considerably longer line that must now wrap")
        #expect(item(model, id).w == hugged)
        #expect(item(model, id).h > 0)
    }

    @Test("switching back to Auto re-hugs — the state is reversible, unlike the gesture")
    func autoReHugs() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model, at: .zero)
        await restyle(model, id, text: "A line of text")
        let hugged = item(model, id).w

        await restyle(model, id, hugs: false)
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        model.resizeTile(tileID: tid, to: CGRect(x: 0, y: 0, width: 500, height: 30), in: content)
        await model.waitForWrites(); await model.load()
        #expect(item(model, id).w == 500)

        await restyle(model, id, hugs: true)
        #expect(item(model, id).w == hugged)   // back to snug
    }

    // MARK: - Load

    @Test("a hugging row is re-derived on load; a fixed row is left alone")
    func refitOnLoad() async throws {
        let model = try await makeModel()
        let hugging = await seedClicked(model, at: CGPoint(x: 0, y: 0))
        model.addText(worldRect: CGRect(x: 0, y: 400, width: 200, height: 30))
        await model.waitForWrites()
        let fixed = model.selectedItemID!

        await model.load()
        #expect(item(model, hugging).w == huggedWidth(model, hugging))
        #expect(item(model, fixed).w == 200)
    }
}

// MARK: - The mid-edit flip (the 8 × 441 bug)

/// A regression suite for the worst bug 063's design allowed: **"Fixed" froze a width
/// nobody could see.**
///
/// While a box hugs its text, the width on screen lives only in the renderer's
/// display-only span (`CanvasEngine.setEditingBoxSpan`, which writes no row). So until
/// an edit commits, the model's width is whatever the box was BORN at. Turning hugging
/// off re-derives geometry with `hugsWidth == false`, and `autosizedFrame` answers
/// "the width you already have" — the birth width.
///
/// Measured, on a click-placed box holding "Hello world this is a caption":
///
/// | | stored | on screen |
/// |---|---|---|
/// | after typing | 8 | 207 |
/// | after Fixed  | **8** | 207 (stale span) |
/// | after commit | **8 × 441** | 8 × 441 |
///
/// The stale span is why nobody saw it coming: the override outlived the mode that
/// justified it, so the box looked right until the edit ended.
///
/// `live:` is the fix — the renderer hands over the frame it is drawing and the string
/// it is holding, and the freeze lands on those. These tests pass that bundle directly
/// rather than standing a canvas up: what is being pinned is what `SpaceModel` does
/// with it, which is where the bug was.
@MainActor
@Suite("SpaceModel mid-edit restyle — the live box, not the committed one")
struct SpaceTextLiveEditRestyleTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-liveedit-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Text Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem {
        model.items.first { $0.item.id == id }!.item
    }

    /// A click-placed box: born hugging, born empty, and never committed — exactly the
    /// state the bug needed.
    private func seedClicked(_ model: SpaceModel) async -> UUID {
        model.addText(worldRect: CGRect(origin: .zero, size: .zero))
        await model.waitForWrites()
        return model.selectedItemID!
    }

    private static let caption = "Hello world this is a caption"

    /// The box as the renderer would be drawing it after the caption is typed: the
    /// hugged width of the LIVE string, which is the number the user can see.
    private func liveBox(_ model: SpaceModel, _ id: UUID) -> SpaceModel.LiveEdit {
        var style = model.style(forItemID: id)
        style.text = Self.caption
        let measured = TextMetrics.size(
            for: ElementRendering.textStyle(for: style), hugging: true, outerWidth: 0)
        let pad = TextMetrics.padding
        return SpaceModel.LiveEdit(
            frame: CGRect(x: 0, y: 0,
                          width: measured.width + 2 * pad, height: measured.height + 2 * pad),
            text: Self.caption)
    }

    @Test("the birth width is tiny — which is what made the bug so violent")
    func aBornBoxIsBarelyWide() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model)
        let born = item(model, id).w
        let live = liveBox(model, id).frame.width
        #expect(born < 20)
        #expect(live > 100, "the typed caption is an order of magnitude wider than the box's row")
    }

    @Test("Fixed freezes the width ON SCREEN, not the width in the row")
    func fixedFreezesTheLiveWidth() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model)
        let live = liveBox(model, id)

        var style = model.style(forItemID: id)
        style.textAutoWidth = false
        model.updateStyle(itemID: id, style: style, live: live)
        await model.waitForWrites()
        await model.load()

        let frozen = item(model, id)
        #expect(frozen.w == Double(live.frame.width))
        // The bug, stated as the thing that must not happen again.
        #expect(frozen.w > 100, "froze the box's birth width instead of the one on screen")
        #expect(frozen.h < 100, "an 8pt column wraps the caption into a 441pt sliver")
    }

    @Test("without the live bundle it still freezes the row — the seam is what fixes it")
    func theSeamIsLoadBearing() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model)

        var style = model.style(forItemID: id)
        style.textAutoWidth = false
        model.updateStyle(itemID: id, style: style)   // no `live:` — the old behaviour
        await model.waitForWrites()
        await model.load()

        // Not an endorsement: this pins WHY `live:` exists. With no editor open this is
        // the correct answer (the row IS the truth); mid-edit it was the bug.
        #expect(item(model, id).w < 20)
    }

    @Test("a mid-edit restyle measures the typed words, not the committed ones")
    func geometryFollowsTheLiveString() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model)
        let live = liveBox(model, id)

        // Still hugging; only the point size changes. The height must come from the
        // caption in the editor, not from the empty string still on the row.
        var style = model.style(forItemID: id)
        style.fontSize = 32
        model.updateStyle(itemID: id, style: style, live: live)
        await model.waitForWrites()
        await model.load()

        let restyled = item(model, id)
        #expect(restyled.w > Double(live.frame.width),
                "32pt text hugs wider than the 16pt measurement handed in")
        #expect(model.style(forItemID: id).text == Self.caption,
                "the typed words ride along, so the row and its size agree")
    }

    @Test("undoing a mid-edit restyle reverts the STYLE and keeps the sentence")
    func undoKeepsTheTypedWords() async throws {
        let model = try await makeModel()
        let id = await seedClicked(model)
        let live = liveBox(model, id)

        var style = model.style(forItemID: id)
        style.fontSize = 32
        model.updateStyle(itemID: id, style: style, live: live)
        await model.waitForWrites()
        await model.load()

        model.undo()
        await model.waitForWrites()
        await model.load()

        #expect(model.style(forItemID: id).fontSize == ElementRendering.defaultFontSize)
        #expect(model.style(forItemID: id).text == Self.caption,
                "undoing a font change must not also undo what was being typed")
    }
}
