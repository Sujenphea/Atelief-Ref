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

    /// The same check with the doc-reserved rows folded in, so a phase about to take a
    /// reserved chord learns from a failing build rather than by hand.
    ///
    /// `planned` is EMPTY as of [024] K3, which promoted the four `M` / `A` rows it
    /// held (three of them — the board's `M` was dropped). The test stays because the
    /// seam does: it is what the next reservation gets for free.
    @Test("the reserved rows are still free")
    func plannedRowsAreFree() {
        let collisions = KeyMap.collisions(in: KeyMap.all + KeyMap.planned)
        #expect(
            collisions.isEmpty,
            Comment(rawValue: "\(collisions.count) colliding chord(s):\n"
                + collisions.map(\.description).joined(separator: "\n")))
    }

    /// **The board has `A` and no `M`** ([024] K3, amending §C). A board is not a
    /// collection, so "move" there would have meant filing the assets AND dropping the
    /// placements — a different verb from the grid's under the same key. A row for it
    /// appearing here is the first sign someone re-added it.
    @Test("the board scope binds A and never M")
    func spaceScopeHasAddButNotMove() {
        let bare = KeyMap.shortcuts(in: .space).filter { $0.modifiers == [] }
        #expect(bare.contains { $0.keys == [.character("a")] })
        #expect(!bare.contains { $0.keys.contains(.character("m")) })
        // …and the grid has BOTH, which is the asymmetry being asserted.
        let grid = KeyMap.shortcuts(in: .collection).filter { $0.modifiers == [] }
        #expect(grid.contains { $0.keys == [.character("m")] })
        #expect(grid.contains { $0.keys == [.character("a")] })
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
        #expect(decoded(.character("m"), []) == .moveTo)
        #expect(decoded(.character("a"), []) == .addTo)
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

    /// `.canvasBoard` rows are the board's bare letters that are NOT tools ([024] K3).
    /// One row today — `A` — and the count is asserted, because the row that must not
    /// appear here is `M`: the doc recommended it and the decision was to drop it.
    @Test("every .canvasBoard row resolves through CanvasHostView.boardShortcut")
    func canvasBoardRowsResolve() {
        let boardRows = rows(for: .canvasBoard)
        #expect(boardRows.count == 1)
        for shortcut in boardRows {
            for chord in shortcut.chords {
                #expect(
                    CanvasHostView.boardShortcut(
                        characters: chord.key.characters,
                        modifiers: chord.modifiers.eventFlags) == .file,
                    Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is in "
                        + "the table but boardShortcut does not decode it"))
                // …and it is not secretly a tool, which is the whole reason the two
                // decoders are siblings rather than one enum.
                #expect(CanvasHostView.toolShortcut(
                    characters: chord.key.characters,
                    modifiers: chord.modifiers.eventFlags) == nil)
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
                    #expect(
                        CanvasHostView.boardShortcut(characters: chars, modifiers: flags) == nil,
                        Comment(rawValue: "\(chord.caption) — “\(shortcut.title)” is "
                            + "filed .none but boardShortcut decodes it"))
                }
            }
        }
    }

    /// The modifier guard that made `M` / `A` safe to take, asserted from both sides
    /// AFTER taking them ([024] K3). This used to assert they were still free; the
    /// half that survives promotion is the half that mattered — every bare-letter
    /// decoder requires bare modifiers, so ⌘A is still Select All and ⌘M is nobody's.
    ///
    /// The full `M` / `A` matrix lives in `MoveAddShortcutTests`; this is the piece the
    /// table itself depends on.
    @Test("taking M and A left the ⌘-combos alone")
    func bareLettersDoNotEatModifiedChords() {
        #expect(gridKeyCommand(characters: "a", modifiers: [.command]) == .selectAll)
        #expect(gridKeyCommand(characters: "m", modifiers: [.command]) == nil)
        #expect(CanvasHostView.boardShortcut(characters: "a", modifiers: [.command]) == nil)
        #expect(CanvasHostView.toolShortcut(characters: "v", modifiers: [.command]) == nil)
        #expect(gridKeyCommand(characters: "x", modifiers: [.command]) == nil)
    }

    // MARK: - 099 · P6 — the reference palette's chord

    /// ⇧⌘P is a `.global` row and it is the only claim on that chord.
    ///
    /// `noCollisions` already proves the second half over the whole table, so what
    /// this adds is the FIRST half: that the row exists, in the scope it has to be
    /// in. A menu key equivalent has to be `.global` here — it is matched before any
    /// first responder, and the palette must open from the item-detail overlay and
    /// from a Space board, both of which swallow bare keys.
    @Test("⇧⌘P opens the reference palette, and nothing else claims it")
    func shiftCommandPIsTheReferencePalette() throws {
        let chord = Chord(key: .character("p"), modifiers: [.command, .shift])
        let rows = KeyMap.all.filter { $0.chords.contains(chord) }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.scope == .global)
        #expect(row.title == "Show Reference Palette")
    }

    /// **⌘P is deliberately left alone.** It is Print everywhere on this platform and
    /// this app has no Print item to argue with it, so a user who reaches for it out
    /// of habit gets the system's answer rather than a palette appearing. The row
    /// above took the shifted chord for exactly this reason, and a later phase that
    /// wants ⌘P has to delete this assertion to get it.
    @Test("plain ⌘P is bound by nothing")
    func commandPIsFree() {
        let chord = Chord(key: .character("p"), modifiers: [.command])
        #expect(!KeyMap.all.contains { $0.chords.contains(chord) })
    }

    /// 099 · P10. The colour filter's popover is where the Any / All control lives,
    /// and until this row the popover had no keyboard route at all — a control
    /// reachable only by mouse is most of the way back to the "no UI" this phase
    /// closed. `.global` because the binding is a `ToolbarItem`'s own
    /// `keyboardShortcut` and a toolbar item hangs off the scene.
    @Test("⇧⌘C opens the color filter, and nothing else claims it")
    func shiftCommandCIsTheColorFilter() throws {
        let chord = Chord(key: .character("c"), modifiers: [.command, .shift])
        let rows = KeyMap.all.filter { $0.chords.contains(chord) }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.scope == .global)
        #expect(row.title == "Filter by color")
    }

    /// **The near miss the shift exists for.** Plain ⌘C is Copy, and it is bound
    /// per surface — a grid and a board — never globally. A `.global` colour row on
    /// the unshifted chord would be matched BEFORE both of them, which is the
    /// collision `noCollisions` would have reported and the reason P10 took the
    /// shifted chord instead of arguing with copy-paste.
    @Test("plain ⌘C stays Copy, on its surfaces and nowhere global")
    func commandCIsCopyAndStaysLocal() {
        let chord = Chord(key: .character("c"), modifiers: [.command])
        let rows = KeyMap.all.filter { $0.chords.contains(chord) }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.scope != .global })
        #expect(Set(rows.map(\.scope)) == [.collection, .space])
    }

    private func rows(for decoder: ShortcutDecoder) -> [Shortcut] {
        KeyMap.all.filter { $0.decoder == decoder }
    }
}
