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
        let measured = SpaceModel.measuredTextSize(for: ts, hugging: true, outerWidth: 0)
        return Double(measured.width) + 2 * Double(TextMetrics.padding)
    }

    // MARK: - anchoredMinX (pure)

    @Test("left-aligned text grows and shrinks from a stationary LEFT edge")
    func anchorLeft() {
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .left) == 100)
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .left) == 100)
    }

    @Test("right-aligned text grows and shrinks from a stationary RIGHT edge")
    func anchorRight() {
        // Growing 50 → 80 pushes the left edge back by 30; the right edge stays at 150.
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .right) == 70)
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .right) == 130)
    }

    @Test("centred text grows both ways — the left edge moves back by half")
    func anchorCenterGrow() {
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 80, alignment: .center) == 85)
    }

    @Test("centred text shrinks both ways — the left edge moves in by half")
    func anchorCenterShrink() {
        #expect(SpaceModel.anchoredMinX(
            oldMinX: 100, oldWidth: 50, newWidth: 20, alignment: .center) == 115)
    }

    @Test("the centre is what a centred box actually holds still")
    func anchorCenterKeepsTheCentre() {
        let oldMinX: CGFloat = 100, oldWidth: CGFloat = 50, newWidth: CGFloat = 80
        let newX = SpaceModel.anchoredMinX(
            oldMinX: oldMinX, oldWidth: oldWidth, newWidth: newWidth, alignment: .center)
        #expect(newX + newWidth / 2 == oldMinX + oldWidth / 2)
    }

    @Test("an unchanged width never moves the box, whatever the alignment")
    func anchorNoOpOnEqualWidth() {
        for align in TextAlign.allCases {
            #expect(SpaceModel.anchoredMinX(
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
