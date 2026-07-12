//
//  GridReorderTests.swift
//  AtelierRefsTests
//
//  Guards the pure Library-grid drag-to-reorder math: dropping one thumbnail onto
//  another moves the dragged id to the target's slot (before it). An off-by-one
//  or a mishandled foreign/self drop here would scramble the persisted order.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("Grid drag-to-reorder")
struct GridReorderTests {

    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let d = UUID()
    private var ids: [UUID] { [Self.a, Self.b, Self.c, Self.d] }

    @Test("move forward: dragged id lands just after the target")
    func moveForward() {
        // Drop A onto C (forward) → A lands right after C.
        #expect(reorderedIDs(ids: ids, movingID: Self.a, toIndexOf: Self.c)
                == [Self.b, Self.c, Self.a, Self.d])
    }

    @Test("move backward: dragged id lands just before the target")
    func moveBackward() {
        // Drop D onto B (backward) → D lands right before B.
        #expect(reorderedIDs(ids: ids, movingID: Self.d, toIndexOf: Self.b)
                == [Self.a, Self.d, Self.b, Self.c])
    }

    @Test("move to the first slot")
    func moveToFront() {
        #expect(reorderedIDs(ids: ids, movingID: Self.c, toIndexOf: Self.a)
                == [Self.c, Self.a, Self.b, Self.d])
    }

    @Test("move onto the last item (forward) lands after it → new last")
    func moveOntoLast() {
        // Drop A onto D (forward) → A lands after D, becoming last.
        #expect(reorderedIDs(ids: ids, movingID: Self.a, toIndexOf: Self.d)
                == [Self.b, Self.c, Self.d, Self.a])
    }

    @Test("dropping onto itself is a no-op (nil)")
    func selfDropIsNil() {
        #expect(reorderedIDs(ids: ids, movingID: Self.b, toIndexOf: Self.b) == nil)
    }

    @Test("unknown moving id is a no-op (foreign drop)")
    func unknownMovingIsNil() {
        #expect(reorderedIDs(ids: ids, movingID: UUID(), toIndexOf: Self.b) == nil)
    }

    @Test("unknown target id is a no-op")
    func unknownTargetIsNil() {
        #expect(reorderedIDs(ids: ids, movingID: Self.a, toIndexOf: UUID()) == nil)
    }

    @Test("result is always a same-count permutation of the input")
    func resultIsPermutation() {
        let out = reorderedIDs(ids: ids, movingID: Self.a, toIndexOf: Self.d)
        #expect(out?.count == ids.count)
        #expect(out.map { Set($0) } == Set(ids))
    }

    @Test("adjacent forward swap")
    func adjacentForward() {
        // Drop A onto B → they swap.
        #expect(reorderedIDs(ids: ids, movingID: Self.a, toIndexOf: Self.b)
                == [Self.b, Self.a, Self.c, Self.d])
    }

    @Test("keyedByAssetID keeps the first on duplicate ids (G3)")
    func keyedByAssetIDDedupsGracefully() {
        struct Item: Equatable {
            let id: UUID
            let label: String
        }
        let dup = Self.a
        let items = [
            Item(id: dup, label: "first"),
            Item(id: Self.b, label: "b"),
            Item(id: dup, label: "second"),
        ]
        let byID = keyedByAssetID(items) { $0.id }
        #expect(byID.count == 2)
        #expect(byID[dup]?.label == "first")
        #expect(byID[Self.b]?.label == "b")
        // Rebuilding an order that includes the duplicate id does not trap.
        let order = [Self.b, dup, Self.b]
        let rebuilt = order.compactMap { byID[$0] }
        #expect(rebuilt.map(\.label) == ["b", "first", "b"])
    }
}
