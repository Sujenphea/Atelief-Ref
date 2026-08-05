//
//  HostDeleteKeyTests.swift
//  CanvasRendererTests
//
//  022 · D3 — the two delete verbs on a board: **⌫ drops the placement, ⌘⌫ leaves
//  the library.**
//
//  `keyDown` used to test `keyCode == 51 || keyCode == 117` and never look at the
//  modifiers, so a ⌘⌫ was silently handled as a bare ⌫ — the modifier was not
//  rejected, it was simply not read — and the app was handed the same closure for
//  both, which is why "Delete" on a board removed a tile and left the picture. The
//  mapping is pure (``CanvasHostView/deleteIntent(characters:modifiers:)``) so the
//  matrix is pinned without an `NSEvent`; the dispatch tests then drive real events
//  through the host to prove the two callbacks are no longer synonyms.
//

import AppKit
import CoreGraphics
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Canvas delete keys")
struct HostDeleteKeyTests {
    private final class TextProvider: TileProvider, @unchecked Sendable {
        var tiles: [Tile] = [
            Tile(id: 0, x: 0, y: 0, w: 300, h: 40, z: 0),
            Tile(id: 1, x: 400, y: 0, w: 300, h: 300, z: 1),
        ]
        func content(for tile: Tile) -> TileContent {
            .text(TextStyle(string: "hello", fontSize: 16,
                            color: RGBAColor(red: 1, green: 1, blue: 1)))
        }
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// Backspace (DEL) and Forward-Delete — the two keys that mean "delete".
    private static let backspace = "\u{7f}"
    private static let forwardDelete = String(UnicodeScalar(NSDeleteFunctionKey)!)
    private static let deleteKeys = [backspace, forwardDelete]

    private func makeHost() -> CanvasHostView {
        let host = CanvasHostView(
            provider: TextProvider(), images: NoImages(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.framesContentWhenReady = false
        host.layout()
        return host
    }

    private func keyDown(_ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    // MARK: - The mapping

    @Test("bare ⌫ / ⌦ remove; under ⌘ they destroy")
    func mapping() {
        for key in Self.deleteKeys {
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: []) == .remove)
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: [.command]) == .destroy)
        }
    }

    /// ⌥⌫ deletes a word and ⌃⌫ deletes to the start of the line. Both are text-box
    /// editing, and neither may reach a verb that removes tiles or pictures.
    @Test("⌥ and ⌃ disqualify entirely")
    func optionAndControlFallThrough() {
        for key in Self.deleteKeys {
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: [.option]) == nil)
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: [.control]) == nil)
            #expect(
                CanvasHostView.deleteIntent(
                    characters: key, modifiers: [.command, .option]) == nil)
        }
    }

    /// There is no ranged delete, so ⇧⌫ can only have meant ⌫. And fn MUST be
    /// tolerated: on a keyboard with no ⌦ key, ⌦ *is* fn-⌫.
    @Test("⇧ and fn are tolerated on both keys")
    func shiftAndFunctionTolerated() {
        for key in Self.deleteKeys {
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: [.shift]) == .remove)
            #expect(CanvasHostView.deleteIntent(characters: key, modifiers: [.function]) == .remove)
            #expect(
                CanvasHostView.deleteIntent(
                    characters: key, modifiers: [.function, .command]) == .destroy)
        }
    }

    @Test("no other key is a delete")
    func otherKeysFallThrough() {
        #expect(CanvasHostView.deleteIntent(characters: "v", modifiers: []) == nil)
        #expect(CanvasHostView.deleteIntent(characters: nil, modifiers: []) == nil)
        #expect(CanvasHostView.deleteIntent(characters: "", modifiers: []) == nil)
    }

    // MARK: - Dispatch: the two callbacks stopped being synonyms

    @Test("⌫ calls onRemoveTiles and NOT onDeleteTiles")
    func bareDeleteRemovesPlacement() {
        let host = makeHost()
        var removed: [Set<Int>] = [], destroyed: [Set<Int>] = []
        host.onRemoveTiles = { removed.append($0) }
        host.onDeleteTiles = { destroyed.append($0) }
        host.selectedTileIDs = [0, 1]

        host.keyDown(with: keyDown(Self.backspace))
        #expect(removed == [[0, 1]])
        #expect(destroyed.isEmpty)
    }

    @Test("⌘⌫ calls onDeleteTiles and NOT onRemoveTiles — the modifier is READ now")
    func commandDeleteDestroys() {
        let host = makeHost()
        var removed: [Set<Int>] = [], destroyed: [Set<Int>] = []
        host.onRemoveTiles = { removed.append($0) }
        host.onDeleteTiles = { destroyed.append($0) }
        host.selectedTileIDs = [1]

        host.keyDown(with: keyDown(Self.backspace, [.command]))
        #expect(destroyed == [[1]])
        #expect(removed.isEmpty)
    }

    @Test("⌦ and ⌘⌦ route the same way as ⌫ and ⌘⌫")
    func forwardDeleteMatches() {
        let host = makeHost()
        var removed: [Set<Int>] = [], destroyed: [Set<Int>] = []
        host.onRemoveTiles = { removed.append($0) }
        host.onDeleteTiles = { destroyed.append($0) }
        host.selectedTileIDs = [0]

        host.keyDown(with: keyDown(Self.forwardDelete))
        host.keyDown(with: keyDown(Self.forwardDelete, [.command]))
        #expect(removed == [[0]])
        #expect(destroyed == [[0]])
    }

    @Test("⌥⌫ is neither verb — a word-delete never touches the board")
    func optionDeleteDoesNothing() {
        let host = makeHost()
        var fired = false
        host.onRemoveTiles = { _ in fired = true }
        host.onDeleteTiles = { _ in fired = true }
        host.selectedTileIDs = [0, 1]

        host.keyDown(with: keyDown(Self.backspace, [.option]))
        #expect(!fired)
    }

    @Test("an empty selection fires neither callback")
    func emptySelectionDoesNothing() {
        let host = makeHost()
        var fired = false
        host.onRemoveTiles = { _ in fired = true }
        host.onDeleteTiles = { _ in fired = true }

        host.keyDown(with: keyDown(Self.backspace))
        host.keyDown(with: keyDown(Self.backspace, [.command]))
        #expect(!fired)
    }

    /// An edit begun before the host had a window is still waiting for focus, and in
    /// that window the HOST is the responder — so a Backspace meant for the text
    /// would have taken the box away instead. The delete keys are inside the
    /// `editingTileID` gate now, where the tool keys already were.
    @Test("an open text edit swallows neither verb — the tile survives the keystroke")
    func openEditorBlocksBothVerbs() {
        let host = makeHost()
        var fired = false
        host.onRemoveTiles = { _ in fired = true }
        host.onDeleteTiles = { _ in fired = true }
        host.selectedTileIDs = [0]
        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        #expect(host.editingTileID == 0)

        host.keyDown(with: keyDown(Self.backspace))
        host.keyDown(with: keyDown(Self.backspace, [.command]))
        #expect(!fired)
    }
}
