//
//  SpaceBarModeTests.swift
//  AtelierRefsTests
//
//  051 Phase 1 [12A] — the action bar's PURE decision logic: `barMode` from the
//  selection count, and each arrange op's enablement threshold (align ≥2,
//  distribute ≥3). Rendering stays compile-only (repo convention); these pin the
//  thresholds so an off-by-one (distribute at 2, align at 1) can't slip in.
//

import Testing
@testable import AtelierRefs

@Suite("Space action bar logic (051 · 12A)")
struct SpaceBarModeTests {

    // MARK: - barMode thresholds

    @Test("selection count maps to the right bar mode",
          arguments: [(0, SpaceBarMode.idle), (1, .single), (2, .multi), (3, .multi), (25, .multi)])
    func barMode(count: Int, expected: SpaceBarMode) {
        #expect(SpaceBarMode.forSelection(count: count) == expected)
    }

    // MARK: - Op enablement thresholds

    @Test("align ops enable at 2, distribute ops at 3 — via minimumCount")
    func enablementThresholds() {
        for op in CanvasArrange.Operation.allCases {
            let minimum = op.isDistribute ? 3 : 2
            #expect(op.minimumCount == minimum)
            // Just below the threshold: disabled. At and above: enabled.
            #expect(op.isEnabled(selectionCount: minimum - 1) == false)
            #expect(op.isEnabled(selectionCount: minimum) == true)
            #expect(op.isEnabled(selectionCount: minimum + 1) == true)
            // Degenerate low counts are always disabled.
            #expect(op.isEnabled(selectionCount: 0) == false)
            #expect(op.isEnabled(selectionCount: 1) == false)
        }
    }

    @Test("distribute is NOT enabled at a 2-item selection (the classic off-by-one)")
    func distributeNeedsThree() {
        #expect(CanvasArrange.Operation.distributeHorizontal.isEnabled(selectionCount: 2) == false)
        #expect(CanvasArrange.Operation.distributeVertical.isEnabled(selectionCount: 2) == false)
        #expect(CanvasArrange.Operation.alignLeft.isEnabled(selectionCount: 2) == true)
    }

    // MARK: - Collapsed group enablement (069)

    @Test("every arrange op lands in exactly one group — none lost behind a collapse")
    func groupsPartitionEveryOp() {
        let grouped = SpaceBarGroup.allCases.flatMap(\.operations)
        #expect(Set(grouped) == Set(CanvasArrange.Operation.allCases))
        // A partition, not just a cover: an op in two panels would apply from two
        // places and drift.
        #expect(grouped.count == CanvasArrange.Operation.allCases.count)
    }

    @Test("a group trigger is live while ANY op inside it would run")
    func groupEnabledIfAnyChildIs() {
        for group in SpaceBarGroup.allCases {
            for count in 0...5 {
                let anyChildLive = group.operations.contains { $0.isEnabled(selectionCount: count) }
                let expected = group == .zOrder ? count >= 1 : anyChildLive
                #expect(group.isEnabled(selectionCount: count) == expected,
                        "group \(group) at \(count)")
            }
        }
    }

    /// The regression this grouping most easily introduces: gating the spacing panel
    /// on its headline op (distribute, ≥3) would bury Tidy Up and the exact gap at a
    /// 2-item selection — which is exactly when someone reaches for a tidy.
    @Test("spacing stays reachable at 2 selected, even though distribute is dead")
    func spacingLiveAtTwo() {
        #expect(SpaceBarGroup.spacing.isEnabled(selectionCount: 2) == true)
        #expect(CanvasArrange.Operation.distributeHorizontal.isEnabled(selectionCount: 2) == false)
        #expect(CanvasArrange.Operation.tidyUp.isEnabled(selectionCount: 2) == true)
    }

    @Test("align and spacing are dead below their floor; z-order lives from 1 up")
    func groupFloors() {
        #expect(SpaceBarGroup.align.isEnabled(selectionCount: 1) == false)
        #expect(SpaceBarGroup.align.isEnabled(selectionCount: 2) == true)
        #expect(SpaceBarGroup.spacing.isEnabled(selectionCount: 1) == false)
        // z-order is the one group shown in `.single`, so it must enable at 1.
        #expect(SpaceBarGroup.zOrder.isEnabled(selectionCount: 0) == false)
        #expect(SpaceBarGroup.zOrder.isEnabled(selectionCount: 1) == true)
    }

    @Test("every group has a distinct trigger glyph")
    func groupSymbolsAreDistinct() {
        let symbols = SpaceBarGroup.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
