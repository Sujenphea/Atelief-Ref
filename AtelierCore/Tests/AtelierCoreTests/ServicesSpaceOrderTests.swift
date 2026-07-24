// AtelierCore — space manual-order invariants (043 · decision 2B, extended to spaces)
//
// `sort_index` gives the flat space list a persisted order — the space analog of
// `ServicesCollectionOrderTests`. These tests pin the ONE invariant that must
// survive every mutation: the spaces' `sort_index` values are a DENSE, gapless
// `0..<n`. Covered mutations: create (append), delete (close the gap), reorder
// (to front / append / mid), index clamping, and a position-restoring inverse
// move (the service half of undo). Spaces are flat, so there is no cross-parent
// case. House style mirrors `ServicesCollectionOrderTests`.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: space manual order (043 · 2B)")
struct ServicesSpaceOrderTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// The spaces in stored order, as `(name, sortIndex)`.
    private func order(_ services: AppServices) async throws -> [(name: String, index: Int)] {
        try await services.listSpaces().map { ($0.name, $0.sortIndex) }
    }

    /// Assert the spaces are exactly `names` in order AND their `sort_index` values
    /// are the dense `0..<n` — the core invariant.
    private func expectOrder(_ services: AppServices, _ names: [String]) async throws {
        let rows = try await order(services)
        #expect(rows.map(\.name) == names)
        #expect(rows.map(\.index) == Array(0..<names.count))
    }

    // MARK: create appends

    @Test("create appends: sequential spaces get a dense 0..<n")
    func createAppends() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        _ = try await services.createSpace(name: "C")
        try await expectOrder(services, ["A", "B", "C"])
    }

    // MARK: delete closes the gap

    @Test("delete closes the gap: remaining spaces stay dense")
    func deleteClosesGap() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createSpace(name: "A")
        let b = try await services.createSpace(name: "B")
        _ = try await services.createSpace(name: "C")

        try await services.deleteSpace(id: b.id)          // remove the middle one
        try await expectOrder(services, ["A", "C"])
    }

    @Test("create after delete appends by count, not a stale max")
    func createAfterDeleteIsDense() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        _ = try await services.createSpace(name: "C")

        try await services.deleteSpace(id: a.id)          // B,C -> 0,1
        _ = try await services.createSpace(name: "D")     // D -> 2
        try await expectOrder(services, ["B", "C", "D"])
    }

    // MARK: reorder

    @Test("move to index 0 puts it first; the list stays dense")
    func reorderToFront() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        let c = try await services.createSpace(name: "C")

        try await services.moveSpace(id: c.id, index: 0)
        try await expectOrder(services, ["C", "A", "B"])
    }

    @Test("move with a nil index appends to the end")
    func reorderAppend() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        _ = try await services.createSpace(name: "C")

        try await services.moveSpace(id: a.id, index: nil)
        try await expectOrder(services, ["B", "C", "A"])
    }

    @Test("move to a mid index inserts there")
    func reorderMid() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        _ = try await services.createSpace(name: "C")

        try await services.moveSpace(id: a.id, index: 1)
        try await expectOrder(services, ["B", "A", "C"])
    }

    @Test("an out-of-range index clamps (huge -> append, negative -> front)")
    func indexClamps() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createSpace(name: "A")
        _ = try await services.createSpace(name: "B")
        let c = try await services.createSpace(name: "C")

        try await services.moveSpace(id: a.id, index: 999)
        try await expectOrder(services, ["B", "C", "A"])

        try await services.moveSpace(id: c.id, index: -5)
        try await expectOrder(services, ["C", "B", "A"])
    }

    @Test("moving a missing space throws notFound")
    func moveMissingThrows() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "space", id: ghost)) {
            try await services.moveSpace(id: ghost, index: 0)
        }
    }

    @Test("an inverse move restores the prior slot (the service half of undo)")
    func inverseMoveRestores() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createSpace(name: "A")   // 0
        _ = try await services.createSpace(name: "B")       // 1
        _ = try await services.createSpace(name: "C")       // 2

        try await services.moveSpace(id: a.id, index: 2)    // A -> end
        try await expectOrder(services, ["B", "C", "A"])
        try await services.moveSpace(id: a.id, index: 0)    // undo: back to front
        try await expectOrder(services, ["A", "B", "C"])
    }

    // MARK: delete-recoverable + restore keep density

    @Test("recoverable delete closes the gap; restore reinstates the former slot")
    func restoreReinstatesSlot() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createSpace(name: "A")       // 0
        let b = try await services.createSpace(name: "B")   // 1
        _ = try await services.createSpace(name: "C")       // 2

        let backup = try await services.deleteSpaceRecoverable(id: b.id)
        try await expectOrder(services, ["A", "C"])         // gap closed
        try await services.restoreDeletedSpace(backup)
        try await expectOrder(services, ["A", "B", "C"])    // B back in its slot
    }
}
