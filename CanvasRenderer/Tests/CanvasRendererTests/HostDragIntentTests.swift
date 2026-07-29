//
//  HostDragIntentTests.swift
//  CanvasRendererTests
//
//  065 / 065b — what a modifier means for a tile drag.
//
//  065 put duplicate and drag-OUT on the SAME key (⌥) and split them by whether the
//  carried tiles could leave the board. That shipped, and it was wrong twice over: an
//  asset could not be duplicated by drag at all, and ⌥ meant one thing on a photo and
//  another on a text box — a modifier you cannot learn, because its meaning depends on
//  what you happen to have grabbed.
//
//  065b gives each gesture its own key: **⌥ duplicates, ⌘ drags out.** The precedence
//  lives in one pure function so it is pinned here rather than in the shape of an `if`
//  — gesture ordering in `CanvasHostView` has shipped a bug before (the double-click
//  that lost to a resize handle), and this is the same class of decision.
//

import CoreGraphics
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Tile drag intent (065b · ⌥ duplicates, ⌘ drags out)")
struct HostDragIntentTests {

    // MARK: - No modifier

    @Test("no modifier is always a plain move, whatever else is available")
    func withoutModifiersItIsAMove() {
        #expect(CanvasHostView.dragIntent(
            optionDown: false, commandDown: false,
            hasDragOutPayload: true, canDuplicate: true) == .move)
        #expect(CanvasHostView.dragIntent(
            optionDown: false, commandDown: false,
            hasDragOutPayload: false, canDuplicate: false) == .move)
    }

    // MARK: - ⌥ duplicates, uniformly

    @Test("⌥ duplicates every kind of tile — including ones that COULD drag out")
    func optionAlwaysDuplicates() {
        // The 065 regression this replaces: an asset yields a drag-out payload, and
        // under the old rule that made ⌥ on it a drag-out, so assets could not be
        // ⌥-duplicated. The payload is now irrelevant to what ⌥ means.
        #expect(CanvasHostView.dragIntent(
            optionDown: true, commandDown: false,
            hasDragOutPayload: true, canDuplicate: true) == .duplicate)
        #expect(CanvasHostView.dragIntent(
            optionDown: true, commandDown: false,
            hasDragOutPayload: false, canDuplicate: true) == .duplicate)
    }

    @Test("with no duplicate handler, ⌥ is a plain move")
    func withoutAHandlerOptionIsAMove() {
        #expect(CanvasHostView.dragIntent(
            optionDown: true, commandDown: false,
            hasDragOutPayload: false, canDuplicate: false) == .move)
    }

    // MARK: - ⌘ drags out, or does nothing

    @Test("⌘ drags out wherever there is something to carry")
    func commandDragsOut() {
        #expect(CanvasHostView.dragIntent(
            optionDown: false, commandDown: true,
            hasDragOutPayload: true, canDuplicate: true) == .dragOut)
    }

    @Test("⌘ on tiles nothing can accept does NOTHING — never a silent move")
    func commandWithoutPayloadIsInert() {
        // The whole point of the split. Falling through to a move would restore exactly
        // the ambiguity 065b removes: ⌘ would mean "leave the board" on an asset and
        // "move without snapping" on a frame.
        #expect(CanvasHostView.dragIntent(
            optionDown: false, commandDown: true,
            hasDragOutPayload: false, canDuplicate: true) == .none)
        #expect(CanvasHostView.dragIntent(
            optionDown: false, commandDown: true,
            hasDragOutPayload: false, canDuplicate: false) == .none)
    }

    // MARK: - Both held

    @Test("⌘ beats ⌥ — leaving the board is the one you have to mean")
    func commandBeatsOption() {
        // An unwanted duplicate is one ⌘Z away; an unwanted drag-out has crossed into
        // another board or collection.
        #expect(CanvasHostView.dragIntent(
            optionDown: true, commandDown: true,
            hasDragOutPayload: true, canDuplicate: true) == .dragOut)
    }

    @Test("⌘⌥ on a tile with no payload is inert, NOT a duplicate")
    func commandBeatsOptionEvenWithNothingToCarry() {
        // ⌘ decides the gesture before ⌥ is consulted, so holding both never quietly
        // degrades into the other meaning.
        #expect(CanvasHostView.dragIntent(
            optionDown: true, commandDown: true,
            hasDragOutPayload: false, canDuplicate: true) == .none)
    }
}
