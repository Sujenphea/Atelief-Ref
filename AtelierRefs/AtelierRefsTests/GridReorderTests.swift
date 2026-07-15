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

    // MARK: - Multi-block reorder (009 · N3)

    private static let e = UUID()
    private static let f = UUID()
    private var six: [UUID] { [Self.a, Self.b, Self.c, Self.d, Self.e, Self.f] }

    @Test("a contiguous block moves forward as one run, feed order preserved")
    func blockContiguousForward() {
        // Drag [A,B] onto E (forward) → they land just after E, order A,B.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, Self.b], toIndexOf: Self.e)
                == [Self.c, Self.d, Self.e, Self.a, Self.b, Self.f])
    }

    @Test("a contiguous block moves backward as one run")
    func blockContiguousBackward() {
        // Drag [E,F] onto B (backward) → land just before B, order E,F.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.e, Self.f], toIndexOf: Self.b)
                == [Self.a, Self.e, Self.f, Self.b, Self.c, Self.d])
    }

    @Test("a NON-contiguous selection is gathered into one run in feed order")
    func blockNonContiguous() {
        // Drag [A,C,E] onto F (forward) → gathered as A,C,E just after F.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, Self.c, Self.e], toIndexOf: Self.f)
                == [Self.b, Self.d, Self.f, Self.a, Self.c, Self.e])
    }

    @Test("reverse-picked selection still lands in feed order, not pick order")
    func blockReversePickOrder() {
        // Pick order [E,C,A] but feed order is A,C,E → result uses feed order.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.e, Self.c, Self.a], toIndexOf: Self.f)
                == [Self.b, Self.d, Self.f, Self.a, Self.c, Self.e])
    }

    @Test("dropping the block ONTO one of its own members is a no-op (nil)")
    func blockOntoSelfIsNil() {
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, Self.b], toIndexOf: Self.a) == nil)
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, Self.c], toIndexOf: Self.c) == nil)
    }

    @Test("foreign ids in the block are ignored; a wholly-foreign block is nil")
    func blockForeignIDs() {
        let ghost = UUID()
        // [A, ghost] onto D → only A moves (ghost dropped).
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, ghost], toIndexOf: Self.d)
                == [Self.b, Self.c, Self.d, Self.a, Self.e, Self.f])
        // A block with no present member is a no-op.
        #expect(reorderedIDs(ids: six, movingIDs: [ghost, UUID()], toIndexOf: Self.d) == nil)
    }

    @Test("an empty block is a no-op (nil)")
    func blockEmptyIsNil() {
        #expect(reorderedIDs(ids: six, movingIDs: [], toIndexOf: Self.d) == nil)
    }

    @Test("multi-block result is always a same-count permutation")
    func blockPermutation() {
        let out = reorderedIDs(ids: six, movingIDs: [Self.a, Self.c, Self.e], toIndexOf: Self.f)
        #expect(out?.count == six.count)
        #expect(out.map { Set($0) } == Set(six))
    }

    @Test("single-item block matches the single-id overload (regression)")
    func blockSingleMatchesLegacy() {
        for target in [Self.a, Self.c, Self.d] where target != Self.b {
            #expect(reorderedIDs(ids: six, movingIDs: [Self.b], toIndexOf: target)
                    == reorderedIDs(ids: six, movingID: Self.b, toIndexOf: target))
        }
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
