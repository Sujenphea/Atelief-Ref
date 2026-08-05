//
//  KeyMapTests.swift
//  AtelierRefsTests
//
//  024 · K1 — **the collision test is the reason `KeyMap` exists.** Everything else
//  the table buys (a shortcuts sheet that cannot go stale, menu titles that read from
//  one place) is downstream of one assertion: no two bindings that can fire in the
//  same moment may claim the same chord.
//
//  The second half is the contract test. A table kept beside the decoders can drift
//  from them, so every row that names a pure decoder is walked back through it —
//  `.collection` rows through `gridKeyCommand`, `.detail` rows through
//  `detailStepDelta`, `.space` tool rows through `CanvasHostView.toolShortcut`, and
//  every delete row through `deleteIntent`. Same shape as the repo's other "same
//  input in → same answer out" contract tests (`SpaceDeleteKeyTests`,
//  `SelectionCellDeltaTests`).
//

import AppKit
import CanvasRenderer
import Foundation
import SwiftUI
import Testing
@testable import AtelierRefs

@Suite("Key map: one table, no two bindings on one chord (024 K1)")
struct KeyMapTests {

    // MARK: - The collision test

    /// **The point of the whole exercise.** Two rows collide when they share a chord
    /// AND their scopes overlap — the same scope, or either of them `.global`, since a
    /// menu key equivalent is live on top of every surface.
    ///
    /// ⌘D is deliberately NOT a collision: *Favorite* is `.collection` and *Duplicate*
    /// is `.space`, and only one of those surfaces has the keyboard at a time. That is
    /// the decision the shortcuts sheet renders with a scope heading over each.
    @Test("no two bound shortcuts share a chord where both are live")
    func noCollisions() {
        let collisions = KeyMap.collisions(in: KeyMap.all)
        #expect(
            collisions.isEmpty,
            Comment(rawValue: "\(collisions.count) colliding chord(s):\n"
                + collisions.map(\.description).joined(separator: "\n")))
    }

    /// The planned `M` / `A` rows ([024] K3) checked against everything already bound,
    /// so K3 learns from a failing build — not by hand — if a later phase takes one of
    /// them first. `X` on the grid and `V`/`F`/`T` on the canvas are the near misses
    /// this is watching.
    @Test("the planned M / A rows are still free")
    func plannedRowsAreFree() {
        let collisions = KeyMap.collisions(in: KeyMap.all + KeyMap.planned)
        #expect(
            collisions.isEmpty,
            Comment(rawValue: "\(collisions.count) colliding chord(s):\n"
                + collisions.map(\.description).joined(separator: "\n")))
    }

    /// The collision detector has to actually detect. Two rows in one scope on one
    /// chord is the case that must fail — a test asserting "no collisions" over a
    /// function that always returns `[]` would pass forever.
    @Test("the detector finds a same-scope duplicate")
    func detectorCatchesSameScope() {
        let a = Shortcut([.character("q")], [.command], "One", scope: .space, source: "test")
        let b = Shortcut([.character("q")], [.command], "Two", scope: .space, source: "test")
        #expect(KeyMap.collisions(in: [a, b]).count == 1)
    }

    /// …and a `.global` row shadowing a surface row, which is the subtler half of the
    /// rule: a menu key equivalent is matched before the event reaches the first
    /// responder, so it wins over anything the surface wanted to do with that chord.
    @Test("the detector finds a global row shadowing a surface row")
    func detectorCatchesGlobalShadow() {
        let menu = Shortcut([.character("q")], [.command], "Menu", scope: .global, source: "test")
        let board = Shortcut([.character("q")], [.command], "Board", scope: .space, source: "test")
        #expect(KeyMap.collisions(in: [menu, board]).count == 1)
        // …and leaves two different surfaces alone, which is what lets ⌘D mean two
        // things.
        let grid = Shortcut([.character("q")], [.command], "Grid", scope: .collection, source: "test")
        #expect(KeyMap.collisions(in: [board, grid]).isEmpty)
    }

    /// Alternate keys are separate chords: ⌘= and ⌘+ are one ROW but two ways to press
    /// it, and a collision on either has to be found.
    @Test("a collision on one alternate key of a multi-key row is found")
    func detectorReadsEveryAlternate() {
        let zoom = Shortcut(
            [.character("="), .character("+")], [.command], "Bigger",
            scope: .space, source: "test")
        let other = Shortcut([.character("+")], [.command], "Other", scope: .space, source: "test")
        #expect(KeyMap.collisions(in: [zoom, other]).count == 1)
    }

    // MARK: - Shape of the table

    /// Planned rows must never leak into `all`. A row that claims a binding the app
    /// does not have is a lie the collision test cannot catch — it is exactly as
    /// "free of collisions" as a true row — so the separation is enforced here.
    @Test("no planned row is in the bound table")
    func plannedRowsAreNotBound() {
        for shortcut in KeyMap.all {
            #expect(shortcut.status == .bound, "\(shortcut.caption) — \(shortcut.title)")
        }
        for shortcut in KeyMap.planned {
            #expect(shortcut.status != .bound, "\(shortcut.caption) — \(shortcut.title)")
        }
    }

    /// Every row says where it lives and what it does, because the table is also the
    /// map the next person reads before adding a binding.
    @Test("every row carries a title and a source")
    func rowsAreDescribed() {
        for shortcut in KeyMap.all + KeyMap.planned {
            #expect(!shortcut.title.isEmpty)
            #expect(!shortcut.source.isEmpty)
            #expect(!shortcut.keys.isEmpty)
        }
    }

    /// The sheet renders one section per populated scope. An empty section would be a
    /// heading over nothing, so `populatedScopes` must never offer one.
    @Test("populatedScopes lists exactly the scopes with rows, in declaration order")
    func populatedScopesAreOrderedAndNonEmpty() {
        for scope in KeyMap.populatedScopes {
            #expect(!KeyMap.shortcuts(in: scope).isEmpty)
        }
        let order = ShortcutScope.allCases.filter(KeyMap.populatedScopes.contains)
        #expect(order == KeyMap.populatedScopes)
    }

    // MARK: - Captions

    /// The key caps the sheet draws. Modifier glyphs in the order macOS draws them.
    @Test("chords caption as macOS writes them")
    func chordCaptions() {
        #expect(Chord(key: .character("d"), modifiers: .command).caption == "⌘D")
        #expect(Chord(key: .character("z"), modifiers: [.command, .shift]).caption == "⇧⌘Z")
        #expect(Chord(key: .character("["), modifiers: [.command, .shift]).caption == "⇧⌘[")
        #expect(Chord(key: .escape, modifiers: []).caption == "esc")
        #expect(Chord(key: .delete, modifiers: []).caption == "⌫")
        #expect(Chord(key: .delete, modifiers: .command).caption == "⌘⌫")
        #expect(Chord(key: .upArrow, modifiers: .shift).caption == "⇧↑")
        #expect(
            ShortcutModifiers([.control, .option, .shift, .command]).caption == "⌃⌥⇧⌘")
    }

    /// A row with alternates reads as both, so the sheet never silently drops one.
    @Test("a multi-key row captions every alternate")
    func rowCaption() {
        let zoom = Shortcut(
            [.character("="), .character("+")], [.command], "Bigger tiles",
            scope: .collection, source: "test")
        #expect(zoom.caption == "⌘= / ⌘+")
    }

    // MARK: - Where you are

    /// The sheet opens on the section for the surface you were on. Item detail wins
    /// over the sidebar selection: the overlay is raised FROM a collection, so reading
    /// `sidebarSelection` alone would always answer `.collection` behind it.
    @Test("the open-on scope follows the route state")
    func currentScopeFollowsNav() {
        let id = UUID()
        #expect(KeyMap.scope(forSidebar: .home, isShowingItemDetail: false) == .gallery)
        #expect(KeyMap.scope(forSidebar: .collection(id), isShowingItemDetail: false) == .collection)
        #expect(KeyMap.scope(forSidebar: .space(id), isShowingItemDetail: false) == .space)
        #expect(KeyMap.scope(forSidebar: .capture, isShowingItemDetail: false) == .global)
        // The overlay wins from anywhere it can be raised.
        #expect(KeyMap.scope(forSidebar: .collection(id), isShowingItemDetail: true) == .detail)
        #expect(KeyMap.scope(forSidebar: .home, isShowingItemDetail: true) == .detail)
    }

    /// Whatever the route state says, the sheet must have a section to open on.
    @Test("every scope the sheet can open on has rows to show")
    func everyOpenOnScopeIsPopulated() {
        let id = UUID()
        let reachable: [SidebarItem] = [.home, .capture, .collection(id), .space(id)]
        for item in reachable {
            for detail in [false, true] {
                let scope = KeyMap.scope(forSidebar: item, isShowingItemDetail: detail)
                #expect(KeyMap.populatedScopes.contains(scope), "\(scope) has no rows")
            }
        }
    }
}

// MARK: - Contract: the table against the decoders

@Suite("Key map contract: every row resolves through the decoder it names (024 K1)")
struct KeyMapContractTests {

    /// Rows that name ``ShortcutDecoder/grid`` must resolve through `gridKeyCommand`.
    /// The grid is the surface with the most bindings and the one most likely to gain
    /// another, so this is the row of the contract that earns its keep.
    @Test("every .grid row resolves through gridKeyCommand")
    func gridRowsResolve() {
        for shortcut in rows(for: .grid) {
            for chord in shortcut.chords {
                #expect(
                    gridKeyCommand(
                        characters: chord.key.characters,
                        modifiers: chord.modifiers.eventFlags) != nil,
                    Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is in "
                        + "the table but gridKeyCommand does not decode it"))
            }
        }
    }

    /// …and it decodes them as the row SAYS, not merely to something. A table that
    /// said "⌘A — Select all" while the decoder answered `.zoomIn` would pass a
    /// non-`nil` check and still be wrong on the page.
    @Test("the grid rows decode to the command their title names")
    func gridRowsDecodeToTheNamedCommand() {
        func decoded(_ key: ShortcutKey, _ mods: ShortcutModifiers) -> GridKeyCommand? {
            gridKeyCommand(characters: key.characters, modifiers: mods.eventFlags)
        }
        #expect(decoded(.upArrow, []) == .arrow(.up, extend: false))
        #expect(decoded(.downArrow, .shift) == .arrow(.down, extend: true))
        #expect(decoded(.returnKey, []) == .openLead)
        #expect(decoded(.escape, []) == .escape)
        #expect(decoded(.space, []) == .quickLook)
        #expect(decoded(.character("x"), []) == .toggleLead)
        #expect(decoded(.character("a"), .command) == .selectAll)
        #expect(decoded(.character("="), .command) == .zoomIn)
        #expect(decoded(.character("+"), .command) == .zoomIn)
        #expect(decoded(.character("-"), .command) == .zoomOut)
    }

    /// `.detailStep` rows step the pager, and the direction has to match the title —
    /// ← is "Previous", → is "Next".
    @Test("every .detailStep row resolves through detailStepDelta, in the right direction")
    func detailRowsResolve() {
        for shortcut in rows(for: .detailStep) {
            for chord in shortcut.chords {
                let delta = detailStepDelta(
                    characters: chord.key.characters, modifiers: chord.modifiers.eventFlags)
                #expect(delta != nil, "\(chord.caption) — “\(shortcut.title)” does not decode")
                if chord.key == .leftArrow { #expect(delta == -1) }
                if chord.key == .rightArrow { #expect(delta == 1) }
            }
        }
    }

    /// `.canvasTool` rows are the board's bare letters. Reaching the decoder needs the
    /// CanvasRenderer package's public surface — see `toolShortcut`'s note on why it
    /// is public.
    @Test("every .canvasTool row resolves through CanvasHostView.toolShortcut")
    func canvasToolRowsResolve() {
        let expected: [ShortcutKey: CanvasTool] = [
            .character("v"): .select, .character("f"): .frame, .character("t"): .text,
        ]
        let toolRows = rows(for: .canvasTool)
        #expect(toolRows.count == expected.count)
        for shortcut in toolRows {
            for chord in shortcut.chords {
                let tool = CanvasHostView.toolShortcut(
                    characters: chord.key.characters, modifiers: chord.modifiers.eventFlags)
                #expect(
                    tool != nil,
                    Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is in "
                        + "the table but toolShortcut does not decode it"))
                #expect(tool == expected[chord.key])
            }
        }
    }

    /// `.delete` rows are the two-tier rule (`ef5201d`): a bare ⌫ / ⌦ removes from the
    /// container in view, ⌘⌫ deletes from the library. Four surfaces read one decoder,
    /// so the table has to agree with it on which is which.
    @Test("every .delete row resolves through deleteIntent, to the tier its scope implies")
    func deleteRowsResolve() {
        let deleteRows = rows(for: .delete)
        // One per surface that routes a bare ⌫ through this decoder — grid, detail
        // page, board, and (since [345]) Home — plus the single ⌘⌫ menu row. Home
        // used to be absent: its ⌫ was SwiftUI's `.onDeleteCommand`, which never sees
        // a modifier, which is why it was the one surface that broke the rule.
        #expect(!deleteRows.isEmpty)
        #expect(deleteRows.contains { $0.scope == .gallery })
        for shortcut in deleteRows {
            for chord in shortcut.chords {
                let intent = deleteIntent(
                    characters: chord.key.characters, modifiers: chord.modifiers.eventFlags)
                #expect(
                    intent != nil,
                    "\(chord.caption) — “\(shortcut.title)” does not decode")
                #expect(
                    intent == (chord.modifiers.contains(.command) ? .destroy : .remove),
                    "\(chord.caption) — “\(shortcut.title)” decodes to the wrong tier")
            }
        }
    }

    /// Home reads its keys through SwiftUI, not `NSEvent`, so its `.delete` row is
    /// walked back through the adapter it actually routes to ([345]). The row would
    /// pass `deleteRowsResolve` above on `deleteIntent` alone while the gallery was
    /// wired to something else entirely; this is the assertion that ties the table to
    /// the code Home really runs.
    @MainActor
    @Test("the .gallery delete row resolves through galleryDeleteIntent, to the same tier")
    func galleryRowResolvesThroughItsAdapter() {
        let equivalents: [ShortcutKey: KeyEquivalent] = [
            .delete: .delete, .forwardDelete: .deleteForward,
        ]
        let galleryRows = KeyMap.shortcuts(in: .gallery).filter { $0.decoder == .delete }
        #expect(!galleryRows.isEmpty)
        for shortcut in galleryRows {
            for chord in shortcut.chords {
                guard let key = equivalents[chord.key] else {
                    Issue.record(Comment(
                        rawValue: "\(chord.caption) — “\(shortcut.title)” names a key "
                            + "galleryDeleteIntent has no KeyEquivalent for"))
                    continue
                }
                let modifiers = eventModifiers(chord.modifiers)
                let intent = galleryDeleteIntent(key: key, modifiers: modifiers)
                // The adapter and the app-wide decoder must never disagree.
                #expect(
                    intent == deleteIntent(
                        characters: chord.key.characters, modifiers: chord.modifiers.eventFlags),
                    Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” decodes "
                        + "differently through SwiftUI than through AppKit"))
                // And Home's row is the bare one: ⌘⌫ is Edit ▸ Delete, a `.global` row.
                #expect(intent == .remove, "\(chord.caption) — “\(shortcut.title)”")
            }
        }
    }

    /// The table's modifier set in SwiftUI's vocabulary, for the row above.
    private func eventModifiers(_ modifiers: ShortcutModifiers) -> EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.control) { out.insert(.control) }
        if modifiers.contains(.option) { out.insert(.option) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.command) { out.insert(.command) }
        return out
    }

    /// The table must not quietly claim a decoder owns a row it has never heard of —
    /// which is what would happen if someone moved a row between scopes and left the
    /// `decoder` field behind. Every `.none` row is checked the other way: none of the
    /// four decoders may claim it, because if one did, the row is misfiled.
    @Test("no .none row is secretly owned by the grid or the canvas decoder")
    func undecodedRowsAreGenuinelyUndecoded() {
        for shortcut in KeyMap.all where shortcut.decoder == .none {
            for chord in shortcut.chords {
                let chars = chord.key.characters
                let flags = chord.modifiers.eventFlags
                // ⌘-combos the grid DOES own (⌘A / ⌘±) are filed as `.grid`; anything
                // else filed `.none` must be invisible to it.
                if shortcut.scope == .collection {
                    #expect(
                        gridKeyCommand(characters: chars, modifiers: flags) == nil,
                        Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is "
                            + "filed .none but gridKeyCommand decodes it"))
                }
                if shortcut.scope == .space {
                    #expect(
                        CanvasHostView.toolShortcut(characters: chars, modifiers: flags) == nil,
                        Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is "
                            + "filed .none but toolShortcut decodes it"))
                }
            }
        }
    }

    /// Bare `M` and `A` are free in both decoders — the fact [024] K3 is about to
    /// build on, pinned so it cannot rot between now and then. And the modifier guard
    /// that makes them safe to take: both decoders require BARE modifiers, so ⌘A stays
    /// Select All and ⌘M is nobody's.
    @Test("M and A are free on the grid and the canvas, and ⌘-combos are unaffected")
    func plannedKeysAreFreeInTheDecoders() {
        for key in ["m", "a", "M", "A"] {
            #expect(CanvasHostView.toolShortcut(characters: key, modifiers: []) == nil)
        }
        #expect(gridKeyCommand(characters: "m", modifiers: []) == nil)
        #expect(gridKeyCommand(characters: "M", modifiers: []) == nil)
        // `a` bare is already nil in the grid — only ⌘A means anything there.
        #expect(gridKeyCommand(characters: "a", modifiers: []) == nil)
        #expect(gridKeyCommand(characters: "a", modifiers: [.command]) == .selectAll)
        // The bare-modifier guard, from both sides.
        #expect(CanvasHostView.toolShortcut(characters: "v", modifiers: [.command]) == nil)
        #expect(gridKeyCommand(characters: "x", modifiers: [.command]) == nil)
    }

    private func rows(for decoder: ShortcutDecoder) -> [Shortcut] {
        KeyMap.all.filter { $0.decoder == decoder }
    }
}
