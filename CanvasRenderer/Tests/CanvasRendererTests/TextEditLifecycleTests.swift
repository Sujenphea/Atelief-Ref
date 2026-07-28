//
//  TextEditLifecycleTests.swift
//  CanvasRendererTests
//
//  2B · 054 §5.3 (R8) — the PURE inline-edit lifecycle logic. The `NSTextView`
//  first-responder / IME / blur lifecycle is live-only (verified by hand, see the
//  changelog), but the decisions it drives are isolated as pure functions and
//  exhaustively tested here: the commit/cancel/delete matrix (incl. delete-empty-
//  new-box), the "tile-left-viewport → commit" predicate, and the double-commit
//  guard. Commit → style + auto-size + one undo is already covered model-side by
//  `SpaceTextResizeTests` (2C).
//

import CoreGraphics
import Foundation
import Testing
@testable import CanvasRenderer

@Suite("Inline text-edit lifecycle (2B · 054 §5.3)")
struct TextEditLifecycleTests {

    // MARK: - inlineEditOutcome matrix (R8)

    @Test("not committed → cancel, whatever the text / new-ness")
    func notCommittedCancels() {
        #expect(canvasTextEditOutcome(text: "anything", isNewlyCreated: false, committed: false) == .cancelled)
        #expect(canvasTextEditOutcome(text: "", isNewlyCreated: true, committed: false) == .cancelled)
        #expect(canvasTextEditOutcome(text: "x", isNewlyCreated: true, committed: false) == .cancelled)
    }

    @Test("committed empty NEW box → deleteElement (no invisible orphan)")
    func emptyNewBoxDeletes() {
        #expect(canvasTextEditOutcome(text: "", isNewlyCreated: true, committed: true) == .deleted)
        // Whitespace/newlines only still read as empty for the delete-new rule.
        #expect(canvasTextEditOutcome(text: "   ", isNewlyCreated: true, committed: true) == .deleted)
        #expect(canvasTextEditOutcome(text: "\n\t ", isNewlyCreated: true, committed: true) == .deleted)
    }

    @Test("committed empty PRE-EXISTING box → persist(\"\") (explicit clear honoured)")
    func emptyExistingBoxPersistsEmpty() {
        #expect(canvasTextEditOutcome(text: "", isNewlyCreated: false, committed: true) == .committed(""))
        #expect(canvasTextEditOutcome(text: "   ", isNewlyCreated: false, committed: true) == .committed(""))
    }

    @Test("committed non-empty → persist(text), new or not")
    func nonEmptyPersists() {
        #expect(canvasTextEditOutcome(text: "Hello", isNewlyCreated: true, committed: true) == .committed("Hello"))
        #expect(canvasTextEditOutcome(text: "Hello", isNewlyCreated: false, committed: true) == .committed("Hello"))
        // The raw string is persisted verbatim (surrounding text preserved).
        #expect(canvasTextEditOutcome(text: " padded ", isNewlyCreated: false, committed: true)
            == .committed(" padded "))
    }

    // MARK: - viewport-exit → commit (§5.4)

    private let viewport = CGSize(width: 800, height: 600)

    @Test("a tile that scrolled out of a laid-out canvas commits; a visible one does not")
    func viewportExitCommits() {
        #expect(canvasInlineEditShouldCommitOnViewportExit(
            isVisible: false, viewportSize: viewport, hasPositioned: true) == true)
        #expect(canvasInlineEditShouldCommitOnViewportExit(
            isVisible: true, viewportSize: viewport, hasPositioned: true) == false)
    }

    @Test("an editor that has never positioned never commits — it hasn't started yet")
    func firstLayoutNeverCommits() {
        // The regression: mounting an editor used to self-commit, because "no screen
        // frame" was read as "the tile left the viewport" when in truth the canvas had
        // not been laid out and NOTHING was visible yet.
        #expect(canvasInlineEditShouldCommitOnViewportExit(
            isVisible: false, viewportSize: .zero, hasPositioned: false) == false)
        // Both guards are independent: either one alone holds the commit back.
        #expect(canvasInlineEditShouldCommitOnViewportExit(
            isVisible: false, viewportSize: viewport, hasPositioned: false) == false)
        #expect(canvasInlineEditShouldCommitOnViewportExit(
            isVisible: false, viewportSize: .zero, hasPositioned: true) == false)
    }

    @Test("a degenerate viewport is never treated as the tile having left")
    func degenerateViewportHoldsStill() {
        for size in [CGSize.zero,
                     CGSize(width: 0, height: 600),
                     CGSize(width: 800, height: 0)] {
            #expect(canvasInlineEditShouldCommitOnViewportExit(
                isVisible: false, viewportSize: size, hasPositioned: true) == false)
        }
    }

    // MARK: - double-commit guard (§5.3)

    @Test("the commit guard fires exactly once; later finishes are ignored")
    func commitGuardIsOneShot() {
        var guardState = CanvasCommitGuard()
        #expect(guardState.finished == false)
        #expect(guardState.begin() == true)  // first finish wins…
        #expect(guardState.finished == true)
        #expect(guardState.begin() == false) // …blur / Esc / undo re-entry is a no-op
        #expect(guardState.begin() == false)
    }
}
