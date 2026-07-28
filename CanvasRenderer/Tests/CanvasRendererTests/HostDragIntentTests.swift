//
//  HostDragIntentTests.swift
//  CanvasRendererTests
//
//  065 — what ⌥ means for a tile drag.
//
//  ⌥ carries two meanings that must never both fire: drag-OUT to another board or a
//  collection (059 · SP7), and duplicate-in-place. The tie-break lives in one pure
//  function so the precedence is pinned here rather than in the shape of an `if` —
//  gesture ordering in `CanvasHostView` has shipped a bug before (the double-click that
//  lost to a resize handle), and this is the same class of decision.
//

import CoreGraphics
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("⌥ drag intent (065)")
struct HostDragIntentTests {

    @Test("no ⌥ is always a plain move, whatever else is available")
    func withoutOptionItIsAMove() {
        #expect(CanvasHostView.dragIntent(
            optionDown: false, hasDragOutPayload: true, canDuplicate: true) == .move)
        #expect(CanvasHostView.dragIntent(
            optionDown: false, hasDragOutPayload: false, canDuplicate: false) == .move)
    }

    @Test("⌥ on tiles that CAN leave the board drags out — the shipped meaning wins")
    func dragOutWinsWhereItApplies() {
        // Both are possible; drag-out is the older meaning and asset tiles have nowhere
        // else to go under ⌥. If this ever flips, board→collection drag silently breaks.
        #expect(CanvasHostView.dragIntent(
            optionDown: true, hasDragOutPayload: true, canDuplicate: true) == .dragOut)
    }

    @Test("⌥ on tiles with nothing to drag out duplicates — the fall-through")
    func elementTilesDuplicate() {
        // A frame or text box yields no drag-out payload, so this gesture used to be a
        // plain move. That is exactly the room 065 takes.
        #expect(CanvasHostView.dragIntent(
            optionDown: true, hasDragOutPayload: false, canDuplicate: true) == .duplicate)
    }

    @Test("with no duplicate handler, ⌥ stays exactly what it was")
    func withoutAHandlerNothingChanges() {
        #expect(CanvasHostView.dragIntent(
            optionDown: true, hasDragOutPayload: false, canDuplicate: false) == .move)
    }
}
