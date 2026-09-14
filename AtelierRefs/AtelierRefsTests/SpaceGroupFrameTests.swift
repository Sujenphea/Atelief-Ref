//
//  SpaceGroupFrameTests.swift
//  AtelierRefsTests
//
//  100 · P1 — ⌘G wraps a multi-selection in an ORDINARY frame. No new entity, no
//  stored member set, no parent pointer: membership stays derived from containment
//  (062 §6), and the whole gesture is "the frame you would have drawn by hand".
//
//  Two things are worth testing, and they are the two the design argues hardest for:
//
//  1. **Adoption is the membership rule, not a second rule.** A bounding box holds
//     its members' centres by construction, so it may also hold a stray tile's — and
//     that tile IS in the frame, whatever the selection was. `adoptionAgreesWith...`
//     below builds the frame the model would create and asks it what it contains; the
//     answer has to be exactly the selection plus the reported adopted set, or the
//     wash P3 draws would be a promise the next drag breaks.
//  2. **Padding is geometry, not decoration.** It is what makes the result look drawn
//     rather than computed (100 §4), and because the padded band is part of the frame
//     it decides membership too — a tile just outside the contents can be inside the
//     frame.
//
//  The pure suite runs on bare `[Tile]`: `groupBounds` takes no store and no database,
//  the same bargain `CanvasArrange` strikes, so the geometry is pinned without a board.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceContent.groupBounds (100 · P1)")
struct SpaceGroupBoundsTests {

    /// Two selected tiles 300 apart, so the union is wide and every case below can
    /// place a third tile relative to a known rect: union (0, 0, 400, 100), padded
    /// (-16, -16, 432, 132).
    private let a = Tile(id: 1, x: 0, y: 0, w: 100, h: 100)
    private let b = Tile(id: 2, x: 300, y: 0, w: 100, h: 100)
    private var pad: CGFloat { SpaceContent.groupPadding }

    // MARK: - Padding

    @Test("the rect is the union of the selected frames, outset by the padding")
    func paddingOutsetsTheUnion() {
        let bounds = SpaceContent.groupBounds(for: [1, 2], in: [a, b])
        #expect(bounds?.rect == CGRect(x: 0, y: 0, width: 400, height: 100)
            .insetBy(dx: -pad, dy: -pad))
        // Pinned to the board's one breathing unit, not a number of its own — see
        // `SpaceContent.groupPadding`. A frame flush against its contents reads as a bug.
        #expect(SpaceContent.groupPadding == CanvasArrange.gridSpacing)
        #expect(SpaceContent.groupPadding == 16)
    }

    @Test("the padding is a margin on the union, not a gap per tile")
    func paddingIsNotPerTile() {
        // Outsetting each member first and unioning after would give the same OUTER
        // rect here, so the distinguishing fact is the interior: nothing about the
        // members moves or grows, and the 200pt gap between them is untouched.
        let bounds = SpaceContent.groupBounds(for: [1, 2], in: [a, b])!
        #expect(bounds.rect.width == 400 + 2 * pad)
        #expect(bounds.adopted.isEmpty)
    }

    // MARK: - Adoption (100 §3)

    @Test("an unselected tile whose CENTRE is inside the union is adopted")
    func adoptsATileBetweenTheSelected() {
        // Sitting in the gap between the two selected tiles — the exact picture in 100 §3.
        let stray = Tile(id: 3, x: 180, y: 20, w: 40, h: 40) // centre (200, 40)
        let bounds = SpaceContent.groupBounds(for: [1, 2], in: [a, b, stray])
        #expect(bounds?.adopted == [3])
    }

    @Test("a tile OVERLAPPING the union but centred outside it is not adopted")
    func doesNotAdoptAnEdgeOverlap() {
        // Spans y 100…200 against a padded rect ending at y 116, so it genuinely
        // intersects — but its centre (150, 150) is outside, and centre is the rule.
        // Were this intersection instead, the frame would half-own a tile, and a drag
        // would carry something the user can see is mostly outside it.
        let straddling = Tile(id: 3, x: 100, y: 100, w: 100, h: 100)
        let bounds = SpaceContent.groupBounds(for: [1, 2], in: [a, b, straddling])!
        #expect(bounds.rect.intersects(straddling.worldFrame))
        #expect(bounds.adopted.isEmpty)
    }

    @Test("the padded band is part of the frame, so it adopts too")
    func paddingItselfAdopts() {
        // Centre (350, -8): clear of the CONTENTS' union (which ends at y 0) but inside
        // the padding. The frame contains it, so the honest answer is "adopted".
        let inMargin = Tile(id: 3, x: 340, y: -18, w: 20, h: 20)
        #expect(SpaceContent.groupBounds(for: [1, 2], in: [a, b, inMargin])?.adopted == [3])
    }

    @Test("a selected tile is never reported as adopted")
    func selectionIsNotAdopted() {
        let inner = Tile(id: 3, x: 180, y: 20, w: 40, h: 40)
        #expect(SpaceContent.groupBounds(for: [1, 2, 3], in: [a, b, inner])?.adopted.isEmpty == true)
    }

    // MARK: - No special case for a frame in the selection (100 §4)

    @Test("a selected frame contributes its own rect to the union")
    func aSelectedFrameContributesItsRect() {
        // The frame is the big tile; the other selected tile sits well inside its
        // right-hand side. If frames were skipped (or asked for their members' bounds
        // instead), the union would start at the small tile's edge, not the frame's.
        let frame = Tile(id: 1, x: 0, y: 0, w: 500, h: 500, z: -1)
        let inside = Tile(id: 2, x: 600, y: 600, w: 100, h: 100)
        let bounds = SpaceContent.groupBounds(for: [1, 2], in: [frame, inside])!
        #expect(bounds.rect == CGRect(x: 0, y: 0, width: 700, height: 700)
            .insetBy(dx: -pad, dy: -pad))
        #expect(bounds.rect.contains(frame.worldFrame))
    }

    // MARK: - Degenerate selections (100 §4)

    @Test("fewer than two tiles is nil — the caller's no-op")
    func belowTwoIsNil() {
        #expect(SpaceContent.groupBounds(for: [], in: [a, b]) == nil)
        #expect(SpaceContent.groupBounds(for: [1], in: [a, b]) == nil)
        // Ids that aren't on the board contribute no geometry, so they cannot make up
        // the count — a selection of one drawn tile and one undrawable row is still one.
        #expect(SpaceContent.groupBounds(for: [1, 99], in: [a, b]) == nil)
        #expect(SpaceContent.groupBounds(for: [1, 2], in: []) == nil)
    }
}

@MainActor
@Suite("SpaceModel.groupSelectionInFrame (100 · P1)")
struct SpaceGroupFrameTests {

    // MARK: - Fixtures

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-groupframe-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Group Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    /// Add a frame per rect; returns the created ids in rect order (each add selects
    /// the new element, so `selectedItemID` is that row's id).
    private func seedFrames(_ model: SpaceModel, _ rects: [CGRect]) async -> [UUID] {
        var ids: [UUID] = []
        for r in rects {
            model.addFrame(worldRect: r)
            await model.waitForWrites()
            ids.append(model.selectedItemID!)
        }
        return ids
    }

    private func select(_ model: SpaceModel, _ ids: [UUID]) {
        let content = model.content()
        model.select(tileIDs: Set(ids.map { content.tileID(forSpaceItemID: $0)! }), in: content)
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem {
        model.items.first { $0.item.id == id }!.item
    }

    private func rect(_ model: SpaceModel, _ id: UUID) -> CGRect {
        let i = item(model, id)
        return CGRect(x: i.x, y: i.y, width: i.w, height: i.h)
    }

    // MARK: - The happy path

    @Test("two selected tiles become one padded frame, behind them, selected, in one undo step")
    func groupsSelectionIntoOneFrame() async throws {
        let model = try await makeModel()
        let ids = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 300, y: 0, width: 100, height: 100),
        ])
        select(model, ids)
        let before = ids.map { rect(model, $0) }

        model.groupSelectionInFrame()
        await model.waitForWrites()

        #expect(model.items.count == 3)
        let created = model.selectedItemID!          // the add selects it, alone
        #expect(model.selectedItemIDs == [created])
        #expect(!ids.contains(created))
        let frame = item(model, created)
        #expect(frame.kind == .frame)
        let pad = SpaceContent.groupPadding
        #expect(rect(model, created) == CGRect(x: 0, y: 0, width: 400, height: 100)
            .insetBy(dx: -pad, dy: -pad))
        // Lowest z: the references it groups have to draw on top of it.
        #expect(ids.allSatisfy { frame.z < item(model, $0).z })

        // ONE step, named for the verb the user used — not "Add Frame", which is the
        // same write reached by drawing one with the F tool.
        #expect(model.undoActionName == "Group in Frame")
        model.undo()
        await model.waitForWrites()
        #expect(model.items.count == 2)
        // Nothing but the frame was created, so the undo is exact — no tile was moved,
        // restacked or reparented (100 §4), and there is nothing left to put back.
        #expect(ids.map { rect(model, $0) } == before)
        #expect(model.undoActionName == "Add Frame")
    }

    @Test("a selected frame is just another rect in the union")
    func mixedSelectionUnionsLiveRects() async throws {
        let model = try await makeModel()
        let frameID = await seedFrames(model, [CGRect(x: 0, y: 0, width: 300, height: 300)])[0]
        // A text box derives its own height (062), so the expectation is computed from
        // the rect that actually landed rather than the one asked for.
        model.addText(worldRect: CGRect(x: 500, y: 500, width: 100, height: 40))
        await model.waitForWrites()
        let textID = model.selectedItemID!
        select(model, [frameID, textID])

        model.groupSelectionInFrame()
        await model.waitForWrites()

        let pad = SpaceContent.groupPadding
        let expected = rect(model, frameID).union(rect(model, textID)).insetBy(dx: -pad, dy: -pad)
        #expect(rect(model, model.selectedItemID!) == expected)
        // The frame's own left/top edge drove the union — it was not skipped, and it
        // was not asked for its members' bounds instead (100 §4: no special case).
        #expect(expected.minX == -pad)
        #expect(expected.minY == -pad)
    }

    // MARK: - Adoption, reported back for the wash (100 §3, P3)

    @Test("an unselected tile inside the new frame comes back as adopted")
    func reportsAdoptedTiles() async throws {
        let model = try await makeModel()
        let ids = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 300, y: 0, width: 100, height: 100),
            CGRect(x: 180, y: 20, width: 40, height: 40),   // the stray, NOT selected
        ])
        select(model, [ids[0], ids[1]])
        let content = model.content()
        let strayTile = content.tileID(forSpaceItemID: ids[2])!

        #expect(model.groupSelectionInFrame() == [strayTile])
    }

    @Test("when the selection is the whole membership, nothing is adopted")
    func noAdoptionIsSilent() async throws {
        let model = try await makeModel()
        let ids = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 300, y: 0, width: 100, height: 100),
            CGRect(x: 900, y: 900, width: 100, height: 100), // far outside
        ])
        select(model, [ids[0], ids[1]])
        #expect(model.groupSelectionInFrame().isEmpty)
    }

    @Test("the adopted set is what the created frame actually contains")
    func adoptionAgreesWithMembership() async throws {
        // The claim P3's wash rests on: what is washed at creation is what a later drag
        // carries. Both answers come from `SpaceContent.tileIDs(withCentreIn:...)`, so
        // this fails only if someone gives one of the two callers a rule of its own.
        let model = try await makeModel()
        let ids = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 300, y: 0, width: 100, height: 100),
            CGRect(x: 180, y: 20, width: 40, height: 40),    // adopted
            CGRect(x: 100, y: 100, width: 100, height: 100), // overlaps, centred outside
        ])
        select(model, [ids[0], ids[1]])
        let adopted = model.groupSelectionInFrame()
        await model.waitForWrites()

        let content = model.content()
        let createdTile = content.tileID(forSpaceItemID: model.selectedItemID!)!
        let selectedTiles = Set(ids.prefix(2).map { content.tileID(forSpaceItemID: $0)! })
        #expect(Set(content.groupMembers(forDraggedTileID: createdTile))
            == selectedTiles.union(adopted))
    }

    // MARK: - No-ops (100 §4)

    @Test("a selection of fewer than two tiles does nothing at all")
    func belowTwoIsANoOp() async throws {
        let model = try await makeModel()
        let ids = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 300, y: 0, width: 100, height: 100),
        ])

        select(model, [ids[0]])
        #expect(model.groupSelectionInFrame().isEmpty)
        await model.waitForWrites()
        #expect(model.items.count == 2)
        // One tile in a frame is not a group: no row written, and no undo step spent.
        #expect(model.undoActionName == "Add Frame")

        model.select(tileIDs: [], in: model.content())
        #expect(model.groupSelectionInFrame().isEmpty)
        await model.waitForWrites()
        #expect(model.items.count == 2)
    }
}
