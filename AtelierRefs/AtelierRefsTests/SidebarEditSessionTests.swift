//
//  SidebarEditSessionTests.swift
//  AtelierRefsTests
//
//  025 · S2 — the sidebar's inline edit session. The outline coordinators around it
//  are AppKit (compile-only + manual), but the DECISION they delegate to is a pure
//  value type, and it is where every rule that matters lives: what a finished
//  session writes, and — just as important — what it declines to write. A rename
//  that ends empty must not blank a folder, and a rename that ends on the name it
//  started with must not write at all, because `IngestionModel.renameFolder`
//  enqueues an undoable work item unconditionally: a no-op write there is a
//  spurious ⌘Z step the user has to press twice to get past.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("An inline sidebar edit resolves to create / rename / nothing")
struct SidebarEditSessionTests {

    // MARK: - Draft (214) — unchanged behaviour

    @Test("a draft commits as a create under its parent")
    func draftCommits() {
        let parent = UUID()
        let state = SidebarEditState(session: .draft(parent: parent))
        #expect(state.outcome(committing: "Textures") == .create(parent: parent, name: "Textures"))
    }

    @Test("a root draft commits with no parent")
    func rootDraftCommits() {
        let state = SidebarEditState(session: .draft(parent: nil))
        #expect(state.outcome(committing: "Refs") == .create(parent: nil, name: "Refs"))
    }

    @Test("a draft cancels — Escape, and an empty or whitespace-only name")
    func draftCancels() {
        let state = SidebarEditState(session: .draft(parent: nil))
        #expect(state.outcome(committing: nil) == .cancel)
        #expect(state.outcome(committing: "") == .cancel)
        #expect(state.outcome(committing: "   \n ") == .cancel)
    }

    @Test("a draft has no original name to be unchanged from")
    func draftIsNeverUnchanged() {
        let state = SidebarEditState(session: .draft(parent: nil))
        #expect(state.originalName.isEmpty)
        #expect(state.text.isEmpty)
        #expect(state.committedName == nil)
        // The empty string is a cancel by the empty rule, not by the unchanged rule.
        #expect(state.outcome(committing: "  ") == .cancel)
    }

    // MARK: - Rename (025 · S2)

    @Test("a rename commits as a rename of its own row")
    func renameCommits() {
        let id = UUID()
        let state = SidebarEditState(session: .rename(id: id), originalName: "Refs")
        #expect(state.outcome(committing: "References") == .rename(id: id, name: "References"))
    }

    @Test("a rename opens holding the name it is editing, so the field is pre-filled")
    func renameStartsFromTheCurrentName() {
        let id = UUID()
        let state = SidebarEditState(session: .rename(id: id), originalName: "Refs")
        #expect(state.text == "Refs")
        #expect(state.renameID == id)
        #expect(state.isRenaming(id))
        #expect(!state.isRenaming(UUID()))
    }

    @Test("a draft is not renaming anything")
    func draftIsNotARename() {
        let state = SidebarEditState(session: .draft(parent: UUID()))
        #expect(state.renameID == nil)
        #expect(!state.isRenaming(UUID()))
    }

    @Test("Escape cancels a rename — the label comes back, nothing is written")
    func renameCancels() {
        let state = SidebarEditState(session: .rename(id: UUID()), originalName: "Refs")
        #expect(state.outcome(committing: nil) == .cancel)
    }

    @Test("renaming to an empty or whitespace-only name cancels — never a blank folder")
    func renameToEmptyCancels() {
        let state = SidebarEditState(session: .rename(id: UUID()), originalName: "Refs")
        #expect(state.outcome(committing: "") == .cancel)
        #expect(state.outcome(committing: "    ") == .cancel)
        #expect(state.outcome(committing: "\t\n") == .cancel)
    }

    @Test("renaming to the SAME name writes nothing — no spurious undo entry")
    func unchangedRenameWritesNothing() {
        let state = SidebarEditState(session: .rename(id: UUID()), originalName: "Refs")
        #expect(state.outcome(committing: "Refs") == .cancel)
        // Whitespace the user never sees doesn't make it a change either — the field
        // is trimmed before the comparison, exactly as the cell trims before commit.
        #expect(state.outcome(committing: "  Refs  ") == .cancel)
    }

    @Test("surrounding whitespace is trimmed off a name that IS a change")
    func committedNamesAreTrimmed() {
        let id = UUID()
        let state = SidebarEditState(session: .rename(id: id), originalName: "Refs")
        #expect(state.outcome(committing: "  References  ") == .rename(id: id, name: "References"))
    }

    @Test("a rename that only changes case is a real change")
    func caseOnlyRenameIsAChange() {
        let id = UUID()
        let state = SidebarEditState(session: .rename(id: id), originalName: "refs")
        #expect(state.outcome(committing: "Refs") == .rename(id: id, name: "Refs"))
    }

    // MARK: - A model reload landing mid-edit

    @Test("a reload mid-rename restores the typed text and still commits it")
    func renameSurvivesAReloadMidEdit() {
        let id = UUID()
        var state = SidebarEditState(session: .rename(id: id), originalName: "Refs")
        state.text = "Referen"                       // half-typed when the refresh lands
        // The coordinator rebuilds the tree and re-focuses a fresh cell seeded from
        // `text` — the session itself is carried across untouched, so what it will
        // write, and what "unchanged" means, are both still right.
        let restored = state
        #expect(restored.text == "Referen")
        #expect(restored.originalName == "Refs")
        #expect(restored.outcome(committing: restored.text) == .rename(id: id, name: "Referen"))
    }

    @Test("a reload mid-rename that ends back on the original name still writes nothing")
    func reloadedRenameBackToOriginalWritesNothing() {
        let id = UUID()
        var state = SidebarEditState(session: .rename(id: id), originalName: "Refs")
        state.text = "Refs"                          // typed away and back again
        #expect(state.outcome(committing: state.text) == .cancel)
    }

    @Test("a reload mid-draft restores the typed text and still creates it")
    func draftSurvivesAReloadMidEdit() {
        let parent = UUID()
        var state = SidebarEditState(session: .draft(parent: parent))
        state.text = "Text"
        #expect(state.outcome(committing: state.text) == .create(parent: parent, name: "Text"))
    }

    @Test("a committed session is marked so its row stays a static label")
    func commitMarksTheRow() {
        var state = SidebarEditState(session: .rename(id: UUID()), originalName: "Refs")
        #expect(state.committedName == nil)          // idle rows are not placeholders
        state.committedName = "References"
        // The coordinator keys "draw a plain label, wait for the refresh" off this,
        // and clears it when the model's snapshot changes.
        #expect(state.committedName == "References")
    }

    // MARK: - Session identity

    @Test("sessions compare by what they edit")
    func sessionEquality() {
        let id = UUID()
        let parent = UUID()
        #expect(SidebarEditSession.rename(id: id) == .rename(id: id))
        #expect(SidebarEditSession.rename(id: id) != .rename(id: UUID()))
        #expect(SidebarEditSession.draft(parent: parent) == .draft(parent: parent))
        #expect(SidebarEditSession.draft(parent: nil) != .draft(parent: parent))
        #expect(SidebarEditSession.draft(parent: nil) != .rename(id: id))
    }
}
