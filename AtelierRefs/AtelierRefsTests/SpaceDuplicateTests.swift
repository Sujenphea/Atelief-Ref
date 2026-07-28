//
//  SpaceDuplicateTests.swift
//  AtelierRefsTests
//
//  065 — duplicate (⌘D / ⌥-drag) and the board clipboard.
//
//  The pure halves are pinned directly (`duplicatedRows`, `SpaceElementPayload`), and
//  the model contract over the real temp-`AppServices` harness the other Space suites
//  use: a duplicate is ONE undo step, it selects the copies, and it never touches the
//  originals.
//

import AppKit
import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Duplicate + board clipboard (065)")
struct SpaceDuplicateTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-dup-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Duplicate Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    private func seedFrames(_ model: SpaceModel, _ rects: [CGRect]) async -> [UUID] {
        var ids: [UUID] = []
        for r in rects {
            model.addFrame(worldRect: r)
            await model.waitForWrites()
            ids.append(model.selectedItemID!)
        }
        return ids
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem? {
        model.items.first { $0.item.id == id }?.item
    }

    private func row(
        _ kind: SpaceItemKind = .text, x: Double, y: Double, z: Int, style: String? = "{}"
    ) -> SpaceItem {
        SpaceItem(
            id: UUID(), spaceID: UUID(), kind: kind, assetID: nil,
            x: x, y: y, w: 100, h: 50, z: z, style: style,
            createdAt: Date(), updatedAt: Date())
    }

    // MARK: - The pure clone rules

    @Test("a copy is a NEW row that carries everything the user can see")
    func duplicatedRowsCarryContent() {
        let source = row(x: 10, y: 20, z: 3, style: #"{"text":"hello"}"#)
        let copies = SpaceModel.duplicatedRows(
            of: [source], offset: CGSize(width: 5, height: 7), startZ: 9)

        let copy = try! #require(copies.first)
        #expect(copy.id != source.id)          // a new row…
        #expect(copy.style == source.style)    // …that looks exactly like the old one
        #expect(copy.kind == source.kind)
        #expect(copy.w == source.w && copy.h == source.h)
        #expect(copy.x == 15 && copy.y == 27)
        #expect(copy.z == 9)
    }

    @Test("duplicating a stack keeps the stack — relative z order survives")
    func duplicatePreservesRelativeOrder() {
        // Deliberately out of order in the input: the sources arrive as a Set-derived
        // array in practice, so the function must not depend on the caller sorting.
        let sources = [row(x: 0, y: 0, z: 7), row(x: 0, y: 0, z: 2), row(x: 0, y: 0, z: 5)]
        let copies = SpaceModel.duplicatedRows(of: sources, offset: .zero, startZ: 100)

        #expect(copies.map(\.z) == [100, 101, 102])
        // …and they are stacked in the SOURCES' order, not the input array's.
        #expect(copies.map(\.x) == [0, 0, 0])
        let sourceOrder = sources.sorted { $0.z < $1.z }.map(\.id)
        #expect(copies.count == sourceOrder.count)
    }

    @Test("an asset row duplicates as another PLACEMENT of the same asset")
    func duplicateOfAnAssetKeepsItsAssetID() {
        let assetID = UUID()
        var source = row(.asset, x: 0, y: 0, z: 0, style: nil)
        source.assetID = assetID
        let copy = try! #require(
            SpaceModel.duplicatedRows(of: [source], offset: .zero, startZ: 1).first)

        #expect(copy.assetID == assetID)  // same asset…
        #expect(copy.id != source.id)     // …different placement
    }

    @Test("nothing selected duplicates nothing")
    func duplicateOfNothing() {
        #expect(SpaceModel.duplicatedRows(of: [], offset: .zero, startZ: 0).isEmpty)
    }

    // MARK: - The model contract

    @Test("⌘D copies the selection, selects the copies, and leaves the originals put")
    func duplicateSelectionIntegration() async throws {
        let model = try await makeModel()
        let ids = await seedFrames(model, [CGRect(x: 0, y: 0, width: 100, height: 80)])
        let originalX = item(model, ids[0])!.x

        model.duplicateSelection()
        await model.waitForWrites()

        #expect(model.items.count == 2)
        // The original has not moved…
        #expect(item(model, ids[0])!.x == originalX)
        // …and the selection is the COPY, not the source — so a second ⌘D walks away
        // rather than piling copies on the same spot.
        #expect(model.selectedItemIDs.count == 1)
        #expect(!model.selectedItemIDs.contains(ids[0]))
        let copy = try #require(model.items.first { $0.item.id != ids[0] }?.item)
        #expect(copy.x == originalX + Double(SpaceModel.duplicateOffset.width))
    }

    @Test("a duplicate of N is ONE undo step, and redo brings them back")
    func duplicateIsOneUndoStep() async throws {
        let model = try await makeModel()
        _ = await seedFrames(model, [
            CGRect(x: 0, y: 0, width: 50, height: 50),
            CGRect(x: 100, y: 0, width: 50, height: 50),
            CGRect(x: 200, y: 0, width: 50, height: 50),
        ])
        let content = model.content()
        model.select(
            tileIDs: Set(model.items.compactMap { content.tileID(forSpaceItemID: $0.item.id) }),
            in: content)

        model.duplicateSelection()
        await model.waitForWrites()
        #expect(model.items.count == 6)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.count == 3)   // one ⌘Z, all three copies gone

        model.redo()
        await model.waitForWrites()
        #expect(model.items.count == 6)
    }

    // MARK: - The clipboard payload

    @Test("a payload is anchored on the selection, not on where it was copied from")
    func payloadIsPositionIndependent() {
        let rows = [row(x: 500, y: 300, z: 4), row(x: 600, y: 380, z: 6)]
        let payload = SpaceElementPayload(items: rows)

        // Relative to the copy's own top-left, and z normalised to start at 0 — so the
        // same copy pastes identically onto any board at any point.
        #expect(payload.rows.map(\.dx) == [0, 100])
        #expect(payload.rows.map(\.dy) == [0, 80])
        #expect(payload.rows.map(\.z) == [0, 2])
    }

    @Test("a pasted copy keeps its layout and belongs to the board it lands on")
    func payloadRebuildsLayout() {
        let payload = SpaceElementPayload(items: [
            row(x: 500, y: 300, z: 4), row(x: 600, y: 380, z: 6),
        ])
        let boardID = UUID()
        let rebuilt = payload.rows(forSpaceID: boardID, at: CGPoint(x: 0, y: 0), startZ: 10)

        #expect(rebuilt.allSatisfy { $0.spaceID == boardID })
        #expect(Set(rebuilt.map(\.id)).count == 2)      // fresh ids, and distinct
        #expect(rebuilt.map(\.x) == [0, 100])           // the gap between them survives
        #expect(rebuilt.map(\.y) == [0, 80])
        #expect(rebuilt.map(\.z) == [10, 12])
    }

    @Test("the payload round-trips through pasteboard bytes")
    func payloadRoundTrips() throws {
        let payload = SpaceElementPayload(items: [row(x: 1, y: 2, z: 0, style: #"{"text":"hi"}"#)])
        let data = try payload.pasteboardData()
        let board = NSPasteboard(name: .init("space-element-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(data, forType: SpaceElementPayload.pasteboardType)

        #expect(SpaceElementPayload.decode(from: board) == payload)
    }

    @Test("an empty copy is not a payload — it must not swallow a paste")
    func emptyPayloadReadsAsNothing() throws {
        // A copy of nothing writes no rows. If `decode` returned it anyway, the paste
        // chain would stop at branch 1 and a pasted URL would never reach the importer.
        let empty = SpaceElementPayload(items: [])
        let board = NSPasteboard(name: .init("space-element-empty-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(try empty.pasteboardData(), forType: SpaceElementPayload.pasteboardType)

        #expect(SpaceElementPayload.decode(from: board) == nil)
    }

    @Test("pasting centres the copy on the paste point")
    func pasteCentresOnThePoint() async throws {
        let model = try await makeModel()
        let payload = SpaceElementPayload(items: [row(x: 0, y: 0, z: 0)]) // 100 × 50

        model.pasteElements(payload, at: CGPoint(x: 1000, y: 1000))
        await model.waitForWrites()

        let pasted = try #require(model.items.first?.item)
        // Centred, not hung off the bottom-right of the point.
        #expect(pasted.x == 950)
        #expect(pasted.y == 975)
    }

    @Test("pasting plain text makes a text box holding it")
    func pasteTextMakesATextBox() async throws {
        let model = try await makeModel()

        model.pasteText("  hello board  ", at: CGPoint(x: 0, y: 0))
        await model.waitForWrites()

        let pasted = try #require(model.items.first?.item)
        #expect(pasted.kind == .text)
        // Trimmed — a paste that is only whitespace is not a text box at all.
        #expect(ElementStyle(jsonString: pasted.style)?.text == "hello board")
        // The height is DERIVED from the text (062), never zero from the seed rect.
        #expect(pasted.h > 0)
    }

    @Test("pasting only whitespace makes nothing")
    func pasteBlankTextIsANoOp() async throws {
        let model = try await makeModel()
        model.pasteText("   \n  ", at: .zero)
        await model.waitForWrites()
        #expect(model.items.isEmpty)
    }
}
