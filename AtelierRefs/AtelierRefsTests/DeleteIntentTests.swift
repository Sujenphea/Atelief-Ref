//
//  DeleteIntentTests.swift
//  AtelierRefsTests
//
//  022 · D1 — the pure decoder behind **⌫ removes, ⌘⌫ destroys**, pinned here in
//  the shape `SelectionCellDeltaTests` pins `gridKeyCommand` / `detailStepDelta`:
//  characters + modifier flags in, an intent (or `nil`) out, no `NSEvent` and no
//  window anywhere.
//
//  The matrix is the whole point. Four surfaces will read this one function, so a
//  disagreement between them can only ever be a wiring bug, never a difference of
//  opinion about what ⌘⌫ means — and the ⌥ / ⌃ rows are the ones that keep a
//  word-delete inside a Name or Note field from deleting the user's pictures.
//

import AppKit
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Delete keys: ⌫ removes, ⌘⌫ destroys (022 D1)")
struct DeleteIntentTests {

    /// Backspace (DEL) and Forward-Delete, the two keys that mean "delete".
    private static let backspace = "\u{7f}"
    private static let forwardDelete = String(UnicodeScalar(NSDeleteFunctionKey)!)
    private static let deleteKeys = [backspace, forwardDelete]

    @Test("bare ⌫ / ⌦ remove")
    func bareRemoves() {
        for key in Self.deleteKeys {
            #expect(deleteIntent(characters: key, modifiers: []) == .remove)
        }
    }

    @Test("⌘⌫ / ⌘⌦ destroy")
    func commandDestroys() {
        for key in Self.deleteKeys {
            #expect(deleteIntent(characters: key, modifiers: [.command]) == .destroy)
        }
    }

    /// The guard that matters: ⌥⌫ deletes a word and ⌃⌫ deletes to the start of
    /// the line. Both are text-field editing, and neither may reach a verb that
    /// touches the library.
    @Test("⌥ and ⌃ disqualify entirely — a word-delete is neither verb")
    func optionAndControlFallThrough() {
        for key in Self.deleteKeys {
            #expect(deleteIntent(characters: key, modifiers: [.option]) == nil)
            #expect(deleteIntent(characters: key, modifiers: [.control]) == nil)
            // Not even with ⌘ along for the ride.
            #expect(deleteIntent(characters: key, modifiers: [.command, .option]) == nil)
            #expect(deleteIntent(characters: key, modifiers: [.command, .control]) == nil)
        }
    }

    /// There is no ranged delete, so ⇧⌫ can only have meant ⌫. And ⌦ IS fn-⌫ on a
    /// keyboard without a Forward-Delete key — AppKit sets `.function` on every
    /// function-key character, so rejecting it would break ⌦ on most Macs.
    @Test("⇧ and fn are tolerated on both keys")
    func shiftAndFunctionAreTolerated() {
        for key in Self.deleteKeys {
            #expect(deleteIntent(characters: key, modifiers: [.shift]) == .remove)
            #expect(deleteIntent(characters: key, modifiers: [.function]) == .remove)
            #expect(deleteIntent(characters: key, modifiers: [.shift, .command]) == .destroy)
            #expect(deleteIntent(characters: key, modifiers: [.function, .command]) == .destroy)
        }
    }

    @Test("every other key is nobody's delete")
    func otherKeysFallThrough() {
        #expect(deleteIntent(characters: "x", modifiers: []) == nil)
        #expect(deleteIntent(characters: "", modifiers: []) == nil)
        #expect(deleteIntent(characters: "\r", modifiers: []) == nil)
        #expect(deleteIntent(characters: "\u{1b}", modifiers: []) == nil)
        #expect(deleteIntent(characters: " ", modifiers: [.command]) == nil)
        #expect(
            deleteIntent(
                characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifiers: []) == nil)
    }

    /// The decoder and the grid's existing key predicate must agree on WHICH keys
    /// are delete keys — they share `gridIsDeleteKey`, and this is the assertion
    /// that keeps them sharing it.
    @Test("the decoder claims exactly the keys gridIsDeleteKey claims")
    func agreesWithTheGridPredicate() {
        for key in Self.deleteKeys + ["x", "", "\r", " "] {
            #expect(
                (deleteIntent(characters: key, modifiers: []) != nil)
                    == gridIsDeleteKey(characters: key))
        }
    }
}
