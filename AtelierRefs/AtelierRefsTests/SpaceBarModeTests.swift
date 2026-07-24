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
}
