// AtelierCore — updateSpaceItemStyleAndPlacement tests (054 §4.3 · R6 · D5, 2C)
//
// The combined restyle + geometry transaction: style and the derived w/h persist
// in ONE db.write so an auto-sized text element's style and size can never
// half-persist. Verified through the public surface (temp DB fixture, house style
// mirroring `ServicesMoveTests`): a placement writes both; `nil` writes style
// only (no geometry change); an unknown id throws `.notFound`.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: updateSpaceItemStyleAndPlacement (054 §4.3)")
struct ServicesSpaceStylePlacementTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Seed one text element and return its id + starting placement.
    private func seedText(_ services: AppServices, in spaceID: UUID) async throws -> UUID {
        let item = try await services.addElement(
            to: spaceID, kind: .text, style: ElementStyle(text: "Hi"),
            x: 100, y: 200, w: 40, h: 20, z: 0)
        return item.id
    }

    private func fetch(_ services: AppServices, _ spaceID: UUID, _ id: UUID) async throws -> SpaceItem {
        try await services.spaceItems(in: spaceID).first { $0.item.id == id }!.item
    }

    @Test("a placement writes both the style and the geometry atomically")
    func writesStyleAndGeometry() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let id = try await seedText(services, in: space.id)

        var style = ElementStyle(text: "Auto width", fontSize: 22)
        style.resizeMode = TextResize.autoWidth.rawValue
        try await services.updateSpaceItemStyleAndPlacement(
            itemID: id, style: style,
            placement: SpaceItemPlacement(itemID: id, x: 100, y: 200, w: 260, h: 34, z: 0))

        let row = try await fetch(services, space.id, id)
        #expect(ElementStyle(jsonString: row.style)?.text == "Auto width")
        #expect(ElementStyle(jsonString: row.style)?.resize == .autoWidth)
        #expect(row.w == 260) // derived geometry rode along in the same write
        #expect(row.h == 34)
        #expect(row.x == 100) // anchor untouched
        #expect(row.y == 200)
    }

    @Test("a nil placement writes style only, leaving geometry untouched")
    func nilPlacementWritesStyleOnly() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let id = try await seedText(services, in: space.id)

        try await services.updateSpaceItemStyleAndPlacement(
            itemID: id, style: ElementStyle(text: "Recoloured", textColor: "#FF0000"),
            placement: nil)

        let row = try await fetch(services, space.id, id)
        #expect(ElementStyle(jsonString: row.style)?.text == "Recoloured")
        #expect(row.w == 40) // geometry unchanged
        #expect(row.h == 20)
    }

    @Test("an unknown id throws notFound")
    func unknownIDThrows() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createSpace(name: "Board")
        await #expect(throws: (any Error).self) {
            try await services.updateSpaceItemStyleAndPlacement(
                itemID: UUID(), style: ElementStyle(text: "x"), placement: nil)
        }
    }
}
