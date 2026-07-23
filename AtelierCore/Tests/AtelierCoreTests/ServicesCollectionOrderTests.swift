// AtelierCore — collection manual-order invariants (043 · decision 2B, test 9A)
//
// `sort_index` gives collections a persisted sibling order. These tests pin the
// ONE invariant that must survive every mutation: within any parent group (roots
// share the `nil` group) the children's `sort_index` values are a DENSE, gapless
// `0..<n`. Covered mutations: create (append), delete (close the gap), move
// within a parent (reorder), move across parents (append + at an index), index
// clamping, a longer mixed sequence, and a position-restoring inverse move (the
// service half of undo). House style mirrors `ServicesFolderTests`.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: collection manual order (043 · 2B)")
struct ServicesCollectionOrderTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// The children of `parent` in stored order, as `(name, sortIndex)`.
    private func order(
        _ services: AppServices, of parent: UUID?
    ) async throws -> [(name: String, index: Int)] {
        try await services.childCollections(of: parent).map { ($0.name, $0.sortIndex) }
    }

    /// Assert `parent`'s children are exactly `names` in order AND their
    /// `sort_index` values are the dense `0..<n` — the core invariant.
    private func expectOrder(
        _ services: AppServices, of parent: UUID?, _ names: [String]
    ) async throws {
        let rows = try await order(services, of: parent)
        #expect(rows.map(\.name) == names)
        #expect(rows.map(\.index) == Array(0..<names.count))
    }

    // MARK: create appends

    @Test("create appends: sequential children get a dense 0..<n")
    func createAppends() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        _ = try await services.createCollection(name: "A", parent: p.id)
        _ = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "C", parent: p.id)
        try await expectOrder(services, of: p.id, ["A", "B", "C"])
    }

    // MARK: delete closes the gap

    @Test("delete closes the gap: remaining siblings stay dense")
    func deleteClosesGap() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let a = try await services.createCollection(name: "A", parent: p.id)
        let b = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "C", parent: p.id)
        _ = a

        try await services.deleteCollection(id: b.id)   // remove the middle one
        try await expectOrder(services, of: p.id, ["A", "C"])
    }

    @Test("create after delete reuses the freed index (append by count, not stale max)")
    func createAfterDeleteIsDense() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let a = try await services.createCollection(name: "A", parent: p.id)
        _ = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "C", parent: p.id)

        try await services.deleteCollection(id: a.id)             // B,C -> 0,1
        _ = try await services.createCollection(name: "D", parent: p.id) // D -> 2
        try await expectOrder(services, of: p.id, ["B", "C", "D"])
    }

    // MARK: reorder within a parent

    @Test("move within a parent to index 0 puts it first; group stays dense")
    func reorderToFront() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        _ = try await services.createCollection(name: "A", parent: p.id)
        _ = try await services.createCollection(name: "B", parent: p.id)
        let c = try await services.createCollection(name: "C", parent: p.id)

        try await services.moveCollection(id: c.id, toParent: p.id, index: 0)
        try await expectOrder(services, of: p.id, ["C", "A", "B"])
    }

    @Test("move within a parent with nil index appends to the end")
    func reorderAppend() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let a = try await services.createCollection(name: "A", parent: p.id)
        _ = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "C", parent: p.id)

        try await services.moveCollection(id: a.id, toParent: p.id, index: nil)
        try await expectOrder(services, of: p.id, ["B", "C", "A"])
    }

    // MARK: move across parents

    @Test("move across parents appends to the new group and closes the old gap")
    func moveAcrossAppends() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let q = try await services.createCollection(name: "Q")
        _ = try await services.createCollection(name: "A", parent: p.id)
        let b = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "C", parent: p.id)
        _ = try await services.createCollection(name: "X", parent: q.id)
        _ = try await services.createCollection(name: "Y", parent: q.id)

        try await services.moveCollection(id: b.id, toParent: q.id) // append
        try await expectOrder(services, of: p.id, ["A", "C"])       // gap closed
        try await expectOrder(services, of: q.id, ["X", "Y", "B"])  // appended
    }

    @Test("move across parents at an explicit index inserts there")
    func moveAcrossAtIndex() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let q = try await services.createCollection(name: "Q")
        let b = try await services.createCollection(name: "B", parent: p.id)
        _ = try await services.createCollection(name: "X", parent: q.id)
        _ = try await services.createCollection(name: "Y", parent: q.id)

        try await services.moveCollection(id: b.id, toParent: q.id, index: 1)
        try await expectOrder(services, of: q.id, ["X", "B", "Y"])
    }

    // MARK: index clamping

    @Test("an out-of-range index clamps (huge -> append, negative -> front)")
    func indexClamps() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let a = try await services.createCollection(name: "A", parent: p.id)
        _ = try await services.createCollection(name: "B", parent: p.id)
        let c = try await services.createCollection(name: "C", parent: p.id)

        try await services.moveCollection(id: a.id, toParent: p.id, index: 999)
        try await expectOrder(services, of: p.id, ["B", "C", "A"])

        try await services.moveCollection(id: c.id, toParent: p.id, index: -5)
        try await expectOrder(services, of: p.id, ["C", "B", "A"])
    }

    // MARK: position-restoring undo (service half)

    @Test("an inverse move to the captured (parent, index) restores position")
    func inverseMoveRestoresPosition() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let q = try await services.createCollection(name: "Q")
        _ = try await services.createCollection(name: "A", parent: p.id)
        let b = try await services.createCollection(name: "B", parent: p.id) // index 1
        _ = try await services.createCollection(name: "C", parent: p.id)

        let capturedParent = b.parentCollectionID
        let capturedIndex = try await services.childCollections(of: p.id)
            .firstIndex { $0.id == b.id }

        try await services.moveCollection(id: b.id, toParent: q.id)          // move away
        try await expectOrder(services, of: p.id, ["A", "C"])

        // Undo = reinsert at the captured slot.
        try await services.moveCollection(
            id: b.id, toParent: capturedParent, index: capturedIndex)
        try await expectOrder(services, of: p.id, ["A", "B", "C"])
    }

    // MARK: mixed sequence — the invariant holds throughout

    @Test("a longer mixed sequence leaves every group dense")
    func mixedSequenceStaysDense() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let q = try await services.createCollection(name: "Q")
        let a = try await services.createCollection(name: "A", parent: p.id)
        let b = try await services.createCollection(name: "B", parent: p.id)
        let c = try await services.createCollection(name: "C", parent: p.id)
        _ = try await services.createCollection(name: "D", parent: p.id)

        try await services.moveCollection(id: c.id, toParent: p.id, index: 0) // reorder
        try await services.moveCollection(id: a.id, toParent: q.id)           // across
        try await services.deleteCollection(id: b.id)                         // delete
        _ = try await services.createCollection(name: "E", parent: p.id)      // create

        // Both groups dense 0..<n, whatever the exact names.
        let pKids = try await services.childCollections(of: p.id)
        #expect(pKids.map(\.sortIndex) == Array(0..<pKids.count))
        let qKids = try await services.childCollections(of: q.id)
        #expect(qKids.map(\.sortIndex) == Array(0..<qKids.count))
    }

    // MARK: fresh-store seed

    @Test("the seeded Unsorted root has sort_index 0 on a fresh store")
    func unsortedSeedIndex() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let unsorted = try await services.getCollection(id: services.unsortedFolderID)
        #expect(unsorted.sortIndex == 0)
    }
}
