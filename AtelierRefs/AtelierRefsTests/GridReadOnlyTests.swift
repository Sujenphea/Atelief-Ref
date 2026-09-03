//
//  GridReadOnlyTests.swift
//  AtelierRefsTests
//
//  099 · P6 — ``GridInteraction``: the three verbs a grid host can be denied, and
//  the one it never can.
//
//  **What is asserted here and what is not.** The coordinator's AppKit routing is
//  not exercisable headlessly — `MasonryGridHostTests`' header says why, and it has
//  said so since 036 — so what these tests drive is every seam that does NOT need a
//  laid-out `NSCollectionView` in a window: the value itself, the configuration's
//  default, the four coordinator entry points that are reachable without a solved
//  layout, and the pure circle rule. What that leaves unproven is named in the
//  changelog rather than implied away.
//

import AppKit
import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("A read-only grid (099 · P6)", .timeLimit(.minutes(1)))
struct GridReadOnlyTests {

    // MARK: - Fixtures

    /// A configuration with every required field filled and NOTHING optional set,
    /// so `interaction` reads whatever the struct's default is.
    private func configuration(
        interaction: GridInteraction? = nil,
        selectionStore: GridSelectionStore = GridSelectionStore(),
        onRequestRemove: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {}
    ) -> GridHostConfiguration {
        var config = GridHostConfiguration(
            items: [],
            itemsVersion: 0,
            density: GridDensity.default,
            spacing: 4,
            topInset: 0,
            collectionID: UUID(),
            displayScale: 2,
            thumbnailURL: { _ in nil },
            blobURL: { _ in nil },
            selectionStore: selectionStore,
            onOpenDetail: { _ in },
            onRequestRemove: onRequestRemove,
            onRequestDelete: {},
            onCopy: onCopy,
            onQuickLook: {},
            onZoomIn: {},
            onZoomOut: {},
            dragPayload: { _ in nil },
            dragImage: { _ in nil },
            canReorder: false,
            onReorderCommit: { _, _ in false },
            actionTargets: { _ in [] },
            destinationTree: [],
            destinationUnsortedID: Collection.unsortedID,
            onMoveToCollection: { _, _ in },
            onCopyToCollection: { _, _ in },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { _ in })
        if let interaction { config.interaction = interaction }
        return config
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: - The value

    /// **Nothing existing changed**, which is the claim the default makes: every grid
    /// built before P6 passes no `interaction` at all.
    @Test("a configuration that says nothing is fully interactive")
    func fullIsTheDefault() {
        #expect(configuration().interaction == .full)
        #expect(GridInteraction() == .full)
        #expect(GridInteraction.full.allowsSelection)
        #expect(GridInteraction.full.allowsContextMenu)
        #expect(GridInteraction.full.allowsKeyboard)
    }

    /// A `Mirror` rather than three `#expect`s, and that is the point: the day a
    /// fourth flag is added, `readOnly` has to answer for it or this fails. A
    /// hand-listed version would silently pass with the new flag left on.
    @Test("read-only denies every flag there is, including one added later")
    func readOnlyDeniesEveryFlag() {
        let flags = Mirror(reflecting: GridInteraction.readOnly).children
            .compactMap { $0.value as? Bool }
        #expect(flags.count == 3, "GridInteraction gained a flag — does readOnly deny it?")
        #expect(flags.allSatisfy { $0 == false })
    }

    /// Drag-out is deliberately NOT a flag: a palette that could not be dragged out
    /// of would have no purpose. Asserted as the absence of a way to switch it off —
    /// no flag mentions dragging, so nothing can.
    @Test("there is no flag that could turn drag-out off")
    func dragOutIsNotOneOfTheFlags() {
        let names = Mirror(reflecting: GridInteraction.readOnly).children
            .compactMap(\.label)
            .map { $0.lowercased() }
        #expect(names.sorted() == ["allowscontextmenu", "allowskeyboard", "allowsselection"])
        #expect(!names.contains { $0.contains("drag") })
    }

    // MARK: - The coordinator's reachable seams

    /// ⌫ arrives by a THIRD route — `deleteBackward:` off the responder chain, not
    /// `keyDown` and not `performKeyEquivalent` — so it is guarded separately and
    /// asserted separately.
    @Test("the bare-Delete responder method does nothing on a read-only grid")
    func deleteResponderIsInertWhenReadOnly() {
        var removed = 0
        let full = MasonryGridCoordinator(
            configuration: configuration(onRequestRemove: { removed += 1 }))
        full.gridDeleteCommand()
        #expect(removed == 1)

        let readOnly = MasonryGridCoordinator(
            configuration: configuration(
                interaction: .readOnly, onRequestRemove: { removed += 1 }))
        readOnly.gridDeleteCommand()
        #expect(removed == 1, "a read-only grid ran the remove verb")
    }

    @Test("Edit ▸ Copy does nothing on a read-only grid")
    func copyResponderIsInertWhenReadOnly() {
        var copies = 0
        let full = MasonryGridCoordinator(configuration: configuration(onCopy: { copies += 1 }))
        full.gridCopyCommand()
        #expect(copies == 1)

        let readOnly = MasonryGridCoordinator(
            configuration: configuration(interaction: .readOnly, onCopy: { copies += 1 }))
        readOnly.gridCopyCommand()
        #expect(copies == 1)
    }

    /// `keyDown` returns FALSE rather than swallowing, so the event carries on up the
    /// responder chain — which is what leaves the palette window's own keys and every
    /// menu equivalent working over a read-only grid.
    @Test("a read-only grid handles no key, and does not swallow it either")
    func keyDownFallsThroughWhenReadOnly() {
        let store = GridSelectionStore()
        let full = MasonryGridCoordinator(configuration: configuration(selectionStore: store))
        // `x` is the grid's one bare-letter binding (toggle the cursor item).
        #expect(full.gridKeyDown(keyEvent("x")))

        let readOnly = MasonryGridCoordinator(
            configuration: configuration(interaction: .readOnly, selectionStore: store))
        #expect(!readOnly.gridKeyDown(keyEvent("x")))
    }

    /// `performKeyEquivalent` walks the VIEW hierarchy rather than the responder
    /// chain, so a read-only grid that answered here would claim ⌘-chords for a
    /// window whose keyboard it does not own.
    @Test("a read-only grid claims no ⌘-chord")
    func performKeyEquivalentFallsThroughWhenReadOnly() {
        let store = GridSelectionStore()
        let full = MasonryGridCoordinator(configuration: configuration(selectionStore: store))
        #expect(full.gridPerformKeyEquivalent(keyEvent("a", modifiers: .command)))

        let readOnly = MasonryGridCoordinator(
            configuration: configuration(interaction: .readOnly, selectionStore: store))
        #expect(!readOnly.gridPerformKeyEquivalent(keyEvent("a", modifiers: .command)))
    }

    /// `nil` is the same answer a right-click on a gap already gives, so there is no
    /// third state to draw.
    @Test("a read-only grid builds no context menu")
    func noContextMenuWhenReadOnly() {
        let readOnly = MasonryGridCoordinator(
            configuration: configuration(interaction: .readOnly))
        #expect(readOnly.gridMenu(for: rightClick()) == nil)
    }

    /// Also what greys out Edit ▸ Copy (`validateUserInterfaceItem`): a read-only
    /// grid reports no selection even if something contrived put one in the store.
    @Test("a read-only grid reports no selection, whatever the store holds")
    func hasSelectionIsFalseWhenReadOnly() {
        let store = GridSelectionStore()
        _ = store.apply(.tapCircle(UUID()))
        #expect(!store.selection.ids.isEmpty, "the fixture did not select anything")

        let full = MasonryGridCoordinator(configuration: configuration(selectionStore: store))
        #expect(full.gridHasSelection)

        let readOnly = MasonryGridCoordinator(
            configuration: configuration(interaction: .readOnly, selectionStore: store))
        #expect(!readOnly.gridHasSelection)
    }

    // MARK: - The cell's enter-selection circle

    /// The circle is an INVITATION. On a read-only grid it would appear on hover for
    /// a gesture that does nothing, which is worse than no circle at all — so
    /// `allowsSelection` gates the other two inputs rather than joining them.
    @Test("the enter-selection circle never shows on a read-only cell")
    func theCircleIsGatedByAllowsSelection() {
        var state = CellSelectionState()
        #expect(!state.showsSelectionCircle(hovered: false))
        #expect(state.showsSelectionCircle(hovered: true))
        state.isSelecting = true
        #expect(state.showsSelectionCircle(hovered: false))

        state.allowsSelection = false
        #expect(!state.showsSelectionCircle(hovered: false))
        #expect(!state.showsSelectionCircle(hovered: true))
    }

    /// The default is `true`, so every cell in every grid that existed before P6
    /// draws its circle exactly as it did.
    @Test("the inert cell state still allows selection")
    func inertCellStateAllowsSelection() {
        #expect(CellSelectionState.inert.allowsSelection)
    }
}
