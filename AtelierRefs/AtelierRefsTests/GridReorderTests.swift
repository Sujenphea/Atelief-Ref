//
//  GridReorderTests.swift
//  AtelierRefsTests
//
//  Guards the pure Library-grid drag-to-reorder math (040): a drag re-inserts the
//  dragged block at the insertion SLOT the live preview chose. An off-by-one or a
//  mishandled foreign/empty block here would scramble the persisted order or
//  diverge from the on-screen preview.
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
    private static let e = UUID()
    private static let f = UUID()
    private var six: [UUID] { [Self.a, Self.b, Self.c, Self.d, Self.e, Self.f] }

    // MARK: - Slot insertion (040 — the live-preview commit)

    @Test("insertAt 0 puts the block first; the end slot puts it last")
    func insertAtEnds() {
        #expect(reorderedIDs(ids: six, movingIDs: [Self.c], insertAt: 0)
                == [Self.c, Self.a, Self.b, Self.d, Self.e, Self.f])
        #expect(reorderedIDs(ids: six, movingIDs: [Self.b], insertAt: 5)
                == [Self.a, Self.c, Self.d, Self.e, Self.f, Self.b])
    }

    @Test("insertAt a middle slot lands in the block-removed order")
    func insertAtMiddle() {
        // Remaining without B is [A,C,D,E,F]; slot 3 → after D.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.b], insertAt: 3)
                == [Self.a, Self.c, Self.d, Self.b, Self.e, Self.f])
    }

    @Test("insertAt clamps at both ends instead of trapping")
    func insertAtClamps() {
        #expect(reorderedIDs(ids: six, movingIDs: [Self.b], insertAt: -2)
                == [Self.b, Self.a, Self.c, Self.d, Self.e, Self.f])
        #expect(reorderedIDs(ids: six, movingIDs: [Self.b], insertAt: 99)
                == [Self.a, Self.c, Self.d, Self.e, Self.f, Self.b])
    }

    @Test("a non-contiguous, reverse-picked block is gathered in feed order")
    func insertAtGathersFeedOrder() {
        // Pick order [E,A], feed order A,E; remaining [B,C,D,F]; slot 2.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.e, Self.a], insertAt: 2)
                == [Self.b, Self.c, Self.a, Self.e, Self.d, Self.f])
    }

    @Test("foreign ids in the block are dropped; a wholly-foreign block is nil")
    func insertAtForeignIDs() {
        let ghost = UUID()
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a, ghost], insertAt: 2)
                == [Self.b, Self.c, Self.a, Self.d, Self.e, Self.f])
        #expect(reorderedIDs(ids: six, movingIDs: [ghost, UUID()], insertAt: 0) == nil)
        #expect(reorderedIDs(ids: six, movingIDs: [], insertAt: 0) == nil)
    }

    @Test("dropping the block back at its own slot is the IDENTITY, not nil")
    func insertAtOwnSlotIsIdentity() {
        // Unlike the onto-a-cell rule (self-drop → nil), a slot drop that lands
        // where the block already sits is a valid no-change commit.
        #expect(reorderedIDs(ids: six, movingIDs: [Self.a], insertAt: 0) == six)
        #expect(reorderedIDs(ids: six, movingIDs: [Self.c, Self.d], insertAt: 2) == six)
    }

    @Test("insertAt results are always same-count permutations")
    func insertAtPermutation() {
        for slot in -1...7 {
            let out = reorderedIDs(
                ids: six, movingIDs: [Self.e, Self.b], insertAt: slot)
            #expect(out?.count == six.count)
            #expect(out.map { Set($0) } == Set(six))
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
