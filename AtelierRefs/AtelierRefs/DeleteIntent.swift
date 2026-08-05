//
//  DeleteIntent.swift
//  AtelierRefs
//
//  022 · D1 — the one place that decides what a Delete key press MEANS:
//  **⌫ removes the item from where you are looking, ⌘⌫ removes it from the app.**
//
//  The repo's other pure key decoders sit beside their single consumer —
//  `gridKeyCommand` in `MasonryGridHost`, `detailStepDelta` in `ItemDetailView`,
//  `toolShortcut` on `CanvasHostView`. This one has four (grid, space canvas,
//  detail page, Edit menu), so it gets a file of its own rather than a home inside
//  one of the surfaces it serves: "the pair means the same thing everywhere" has
//  to be a property of the CODE, not of four remembered conventions, and a decoder
//  living in the grid would quietly make the grid the authority on what ⌘⌫ means
//  on a board. Pure and SwiftUI-free, in the shape the three existing decoders
//  established, so the whole matrix is pinned by tests without an `NSEvent`.
//
//  Nothing consumes this yet — D1 lands the decision ahead of the surface wiring
//  (D2–D5) so the behaviour change arrives as one visible change rather than four.
//

import AppKit

/// What a Delete key press asked for (022 · D1).
nonisolated enum DeleteIntent: Equatable {
    /// ⌫ — drop the item from the container in view (a membership / a placement).
    /// Undoable, no dialog.
    case remove
    /// ⌘⌫ — delete from the library. Stages the shared confirmation.
    case destroy
}

/// Map a key (its `charactersIgnoringModifiers` + `modifiers`) to a
/// ``DeleteIntent``, or `nil` when the press is not a delete this app owns
/// (022 · D1). The `gridKeyCommand(characters:modifiers:)` shape, and it reuses
/// ``gridIsDeleteKey(characters:)`` for the key test so the two can never disagree
/// about what counts as a Delete key.
///
/// - Bare ⌫ (DEL, `0x7f`) or ⌦ (`NSDeleteFunctionKey`) → ``DeleteIntent/remove``.
/// - The same keys under ⌘ → ``DeleteIntent/destroy``.
/// - **⌥ or ⌃ disqualify entirely.** ⌥⌫ and ⌃⌫ are word/line deletes inside a text
///   field; a surface that treated either as "remove" or "destroy" would eat a
///   correction to a name or a note and act on the selection instead. There is no
///   third verb to give them, so they fall through to the system.
/// - ⇧ is tolerated on both — there is no ranged delete, so ⇧⌫ can only have meant
///   ⌫.
/// - `.function` is tolerated too, and must be: on a keyboard with no ⌦ key, ⌦ IS
///   fn-⌫, and AppKit sets `.function` on every function-key character anyway — so
///   rejecting it (as `toolShortcut` does for letters) would reject forward-delete
///   on most Macs.
func deleteIntent(characters: String, modifiers: NSEvent.ModifierFlags) -> DeleteIntent? {
    guard gridIsDeleteKey(characters: characters),
          !modifiers.contains(.option), !modifiers.contains(.control)
    else { return nil }
    return modifiers.contains(.command) ? .destroy : .remove
}
