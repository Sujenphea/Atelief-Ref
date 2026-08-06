//
//  HomeDeleteGateTests.swift
//  AtelierRefsTests
//
//  073 / 345 — **the last surface joins "⌫ removes from where you are looking, ⌘⌫
//  removes it from the app".** Home was the exception, and the worst one to have: a
//  bare ⌫ over a Home selection deleted whole collections and spaces. It could not be
//  fixed in place, because it was `.onDeleteCommand` — a SwiftUI hook that is handed
//  no modifiers at all, so there was no seam where ⌘ could be read.
//
//  What is pinned here is everything about that change that is a pure function:
//
//   • The decoder half — `galleryDeleteIntent` is a thin adapter onto the app-wide
//     `deleteIntent`, so the ⌥ / ⌃ exclusion and the ⌘ tier split are the SAME
//     decisions the grid, the board and the detail page make, not a fifth opinion.
//   • The boundary the whole SwiftUI route rests on: SwiftUI's `KeyEquivalent.delete`
//     is BACKSPACE (`U+0008`) while AppKit reports that same key as DEL (`U+007F`),
//     so `galleryCharacters` has to translate. This caught a real bug on its first
//     run — the adapter passed the raw character through and a live ⌫ decoded to
//     `nil`, silently doing nothing. Nothing else in the suite would have noticed.
//   • The target split — a Home selection can hold collections AND spaces at once,
//     and the two leave the library by different model verbs.
//   • The notice a bare ⌫ posts instead of deleting, and the fact that it deletes
//     nothing.
//
//  The dialog itself is `@State` inside `CollectionsGalleryView` and is manual, per
//  repo convention; what a test CAN say is that the ids a ⌘⌫ hands `deleteCards` are
//  the ids a bare ⌫ used to hand it, which is the whole claim of "same code path".
//

import AppKit
import AtelierCore
import AtelierIngestion
import Foundation
import SwiftUI
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Home: ⌫ deletes nothing, ⌘⌫ deletes (073 · 345)")
struct HomeDeleteGateTests {

    // MARK: - The decoder

    @Test("bare ⌫ / ⌦ on Home decode to remove — the tier that deletes nothing here")
    func bareIsTheRemoveTier() {
        #expect(galleryDeleteIntent(key: .delete, modifiers: []) == .remove)
        #expect(galleryDeleteIntent(key: .deleteForward, modifiers: []) == .remove)
    }

    @Test("⌘⌫ / ⌘⌦ decode to destroy")
    func commandIsTheDestroyTier() {
        #expect(galleryDeleteIntent(key: .delete, modifiers: .command) == .destroy)
        #expect(galleryDeleteIntent(key: .deleteForward, modifiers: .command) == .destroy)
    }

    /// The guard that keeps a word-delete out of the library, inherited whole from
    /// `deleteIntent`: ⌥⌫ is "delete the previous word" and ⌃⌫ is "delete to the start
    /// of the line". Neither is a verb this app owns, with or without ⌘ along.
    @Test("⌥⌫ and ⌃⌫ stage nothing — they are text-editing keys")
    func optionAndControlAreNotOurs() {
        for key in [KeyEquivalent.delete, .deleteForward] {
            #expect(galleryDeleteIntent(key: key, modifiers: .option) == nil)
            #expect(galleryDeleteIntent(key: key, modifiers: .control) == nil)
            #expect(galleryDeleteIntent(key: key, modifiers: [.command, .option]) == nil)
            #expect(galleryDeleteIntent(key: key, modifiers: [.command, .control]) == nil)
        }
    }

    /// There is no ranged delete on Home, so ⇧⌫ can only have meant ⌫.
    @Test("⇧ is tolerated on both tiers")
    func shiftIsTolerated() {
        #expect(galleryDeleteIntent(key: .delete, modifiers: .shift) == .remove)
        #expect(galleryDeleteIntent(key: .delete, modifiers: [.shift, .command]) == .destroy)
    }

    /// Home never claims a key that is not a Delete — the `.onKeyPress` set is narrow,
    /// but the decoder is the thing that would have to say no if it widened.
    @Test("a letter is not a delete, whatever the modifiers")
    func lettersAreNeverDeletes() {
        for modifiers in [EventModifiers(), .command, .shift, .option] {
            #expect(galleryDeleteIntent(key: "a", modifiers: modifiers) == nil)
            #expect(galleryDeleteIntent(key: .escape, modifiers: modifiers) == nil)
        }
    }

    /// **The trap this suite exists to catch, and did.** SwiftUI and AppKit disagree
    /// about Backspace: `KeyEquivalent.delete` is `U+0008`, while the same physical key
    /// read off an `NSEvent` is `U+007F` — the character `gridIsDeleteKey`, and so every
    /// delete decoder in the app, recognises. The first cut of `galleryDeleteIntent`
    /// passed the raw character through and a real ⌫ decoded to `nil`: the key did
    /// nothing at all, with no crash and no warning to say so.
    ///
    /// Both halves are asserted on purpose. The second is what makes `galleryCharacters`
    /// look necessary rather than superstitious to whoever reads it next, so nobody
    /// "simplifies" the substitution away.
    @Test("KeyEquivalent → NSEvent characters: Backspace is translated, ⌦ is not")
    func swiftUIDeleteKeysAreTranslatedToTheAppsDeleteKeys() {
        #expect(gridIsDeleteKey(characters: galleryCharacters(.delete)))
        #expect(gridIsDeleteKey(characters: galleryCharacters(.deleteForward)))
        #expect(galleryCharacters(.delete) == "\u{7f}")
        #expect(galleryCharacters(.deleteForward) == String(UnicodeScalar(NSDeleteFunctionKey)!))
        // …and why the translation is needed at all: SwiftUI's ⌫ is not AppKit's.
        #expect(KeyEquivalent.delete.character == "\u{8}")
        #expect(gridIsDeleteKey(characters: "\u{8}") == false)
        // A key that is not a delete passes through untouched.
        #expect(galleryCharacters("a") == "a")
        #expect(galleryCharacters(.escape) == "\u{1b}")
    }

    /// The modifier bridge, both directions of every flag that can change a delete's
    /// meaning. `.capsLock` / `.numericPad` are dropped deliberately — no delete chord
    /// reads them, and mapping `.numericPad` onto `.numericPad` would make ⌦ on a full
    /// keyboard decode differently from ⌦ on a laptop.
    @Test("the SwiftUI → AppKit modifier bridge carries the four that matter")
    func modifierBridge() {
        #expect(galleryEventFlags([]) == [])
        #expect(galleryEventFlags(.command) == .command)
        #expect(galleryEventFlags(.option) == .option)
        #expect(galleryEventFlags(.control) == .control)
        #expect(galleryEventFlags(.shift) == .shift)
        #expect(galleryEventFlags([.command, .shift]) == [.command, .shift])
        #expect(galleryEventFlags([.command, .option, .control, .shift])
            == [.command, .option, .control, .shift])
        #expect(galleryEventFlags(.capsLock) == [])
    }

    // MARK: - What ⌘⌫ is aimed at

    private static let unsorted = UUID()

    @Test("a mixed selection splits into the two verbs that delete it")
    func mixedSelectionSplits() {
        let folderA = UUID(), folderB = UUID(), board = UUID()
        let targets = galleryDeleteTargets(
            selection: [folderA, board],
            roots: [Self.unsorted, folderA, folderB],
            unsortedID: Self.unsorted,
            spaces: [board])
        #expect(targets.collectionIDs == [folderA])
        #expect(targets.spaceIDs == [board])
        #expect(targets.count == 2)
        #expect(!targets.isEmpty)
    }

    /// ⌘A takes every card in both sections, so "collections and spaces at once" is
    /// not a corner case a user has to construct — it is one keystroke away.
    @Test("select-all is reachable as a mixed selection and every card is a target")
    func selectAllIsMixed() {
        let folderA = UUID(), folderB = UUID(), boardA = UUID(), boardB = UUID()
        let targets = galleryDeleteTargets(
            selection: [folderA, folderB, boardA, boardB],
            roots: [Self.unsorted, folderA, folderB],
            unsortedID: Self.unsorted,
            spaces: [boardA, boardB])
        #expect(targets.collectionIDs == [folderA, folderB])
        #expect(targets.spaceIDs == [boardA, boardB])
    }

    /// Unsorted is never selectable in the gallery, but the split guards it anyway —
    /// it is the fallback every removal re-homes into, and `deleteFolder` guards it a
    /// third time.
    @Test("Unsorted is never a target, even if its id is in the selection")
    func unsortedIsNeverATarget() {
        let folder = UUID()
        let targets = galleryDeleteTargets(
            selection: [Self.unsorted, folder],
            roots: [Self.unsorted, folder],
            unsortedID: Self.unsorted,
            spaces: [])
        #expect(targets.collectionIDs == [folder])
        #expect(targets.spaceIDs.isEmpty)
    }

    /// A card deleted elsewhere while it was selected leaves a stale id behind. It
    /// falls out rather than being handed to a delete verb.
    @Test("an id in neither section is dropped")
    func staleIDsFallOut() {
        let targets = galleryDeleteTargets(
            selection: [UUID()], roots: [Self.unsorted], unsortedID: Self.unsorted, spaces: [])
        #expect(targets.isEmpty)
        #expect(targets.count == 0)
    }

    /// Filtered from the sections rather than from the `Set`, so the ids arrive in the
    /// order the cards are on screen instead of hash order.
    @Test("targets come out in display order, not Set order")
    func targetsAreInDisplayOrder() {
        let ids = (0..<8).map { _ in UUID() }
        let targets = galleryDeleteTargets(
            selection: Set(ids), roots: [Self.unsorted] + ids.prefix(4),
            unsortedID: Self.unsorted, spaces: Array(ids.suffix(4)))
        #expect(targets.collectionIDs == Array(ids.prefix(4)))
        #expect(targets.spaceIDs == Array(ids.suffix(4)))
    }

    // MARK: - The model verbs

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "home-gate-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        await model.refreshSpaces()
        return (model, services)
    }

    /// The bare-⌫ half: nothing leaves the library, nothing is staged, and the notice
    /// names the key that would have. This is the whole behaviour change — before
    /// [345] this key ran `deleteCards`.
    @Test("a bare ⌫ on Home deletes nothing and names ⌘⌫")
    func bareDeleteExplainsItself() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Keep")
        let board = try await services.createSpace(name: "Keep Board")
        await model.refreshFolders()
        await model.refreshSpaces()

        model.explainHomeDeleteKey()
        await model.waitForWrites()

        #expect(try await services.listCollections().contains { $0.id == folder.id })
        #expect(try await services.listSpaces().contains { $0.id == board.id })
        #expect(model.lastNotice?.message.contains("⌘⌫") == true)
        // A verb that did nothing registers no undo step.
        #expect(!model.canUndo)
    }

    /// The ⌘⌫ half: the ids the split produces are the ids `deleteCards` acts on —
    /// the same call, over the same selection, that a bare ⌫ made before [345]. Only
    /// the key that reaches it changed.
    @Test("⌘⌫ over a mixed selection deletes exactly what the split named")
    func commandDeleteRemovesTheSplitTargets() async throws {
        let (model, services) = try await makeModel()
        let doomed = try await services.createCollection(name: "Doomed")
        let kept = try await services.createCollection(name: "Kept")
        let board = try await services.createSpace(name: "Doomed Board")
        await model.refreshFolders()
        await model.refreshSpaces()

        let targets = galleryDeleteTargets(
            selection: [doomed.id, board.id],
            roots: [model.unsortedFolderID, doomed.id, kept.id],
            unsortedID: model.unsortedFolderID,
            spaces: [board.id])
        model.deleteCards(collectionIDs: targets.collectionIDs, spaceIDs: targets.spaceIDs)
        await model.waitForWrites()

        #expect(try await services.listSpaces().isEmpty)
        try await eventually {
            try await services.listCollections().contains { $0.id == doomed.id } == false
        }
        // The unselected card and the protected root are untouched.
        #expect(try await services.listCollections().contains { $0.id == kept.id })
        #expect(try await services.listCollections().contains { $0.id == model.unsortedFolderID })
    }

    /// Folder deletes run on the fire-and-forget `perform` path, which `waitForWrites`
    /// does not await — the same poll `HomeCardDeleteTests` uses.
    private func eventually(
        timeoutMs: Int = 2000, _ condition: () async throws -> Bool
    ) async throws {
        var waited = 0
        while waited < timeoutMs {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
            waited += 25
        }
        #expect(try await condition())
    }
}
