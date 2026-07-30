//
//  CollectionsGalleryView.swift
//  AtelierRefs
//
//  004-P2 / 009 · N4 — the app's Home overview. Two sections of fanned "stack"
//  cards (``FanCard``): the ROOT collections (Unsorted pinned first) and, below,
//  the Spaces. Tapping a card pushes its `CollectionView` / `SpaceView`; card
//  context menus cover rename / delete / new subfolder. New root collections /
//  spaces are created from the sidebar's section "+".
//
//  009 · N6 — a marquee (drag-rectangle) selects cards across both sections; the
//  selection is deletable via ⌫ / a contextual bar, through ONE confirmation.
//  Unsorted is never selectable (it can't be deleted). The marquee reuses the
//  pure ``marqueeRect``/``marqueeIndices`` geometry; card frames are captured with
//  `onGeometryChange` in a shared named coordinate space.
//

import AppKit
import AtelierCore
import SwiftUI

struct CollectionsGalleryView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel

    @State private var renameTarget: Collection?
    @State private var renameText = ""
    @State private var subfolderParent: Collection?
    @State private var subfolderName = ""
    @State private var spaceRenameTarget: Space?
    @State private var spaceRenameText = ""

    // Home-card multi-selection via the shared grid reducer (048 · work item B):
    // cmd-click toggles, shift-click ranges over `orderIDs`, marquee replaces, ⌘A
    // selects all. Home cards now select like the collection grid instead of the
    // old marquee-only `Set`. Held as plain `@State` (a `GridSelectionStore` is
    // only needed for the AppKit host's Combine subscription — pure SwiftUI
    // re-renders on the value change). Unsorted is never selectable.
    @State private var selection = GridSelection()
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var showBatchDelete = false
    /// The card currently under a folder-reparent drag (043), for the drop ring.
    @State private var reparentTargetID: UUID?
    @FocusState private var galleryFocused: Bool

    private static let gallerySpace = "galleryContent"

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        // 006 shell — the top-level Home overview. Search is a sidebar destination;
        // New Collection / New Space are the sidebar sections' "+".
        ScrollView {
            ZStack(alignment: .topLeading) {
                // The drag catcher sits BEHIND the cards, so a drag on empty grid
                // area starts a marquee while a tap on a card still navigates.
                marqueeCatcher
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    // Spaces are additive — hidden entirely until the user has one,
                    // so Home stays collection-focused for a fresh library.
                    if !model.spaces.isEmpty {
                        spacesSection
                    }
                    collectionsSection
                }
                .padding(Theme.Spacing.xl)
                marqueeOverlay
            }
            .coordinateSpace(.named(Self.gallerySpace))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($galleryFocused)
        .onDeleteCommand { requestBatchDelete() }
        .onExitCommand { clearSelection() }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            apply(.selectAll)
            return .handled
        }
        .overlay(alignment: .bottom) {
            if selection.isSelecting { selectionBar }
        }
        .task {
            await model.refreshFolders()
            await model.refreshCollectionCovers()
            await model.refreshStackPreviews()
            await model.refreshSpaces()
            await model.refreshSpaceStackPreviews()
        }
        // Rename collection.
        .nameEntryAlert(
            "Rename Collection",
            isPresented: renameBinding, text: $renameText, confirmLabel: "Rename",
            onConfirm: { name in
                if let target = renameTarget { model.renameFolder(id: target.id, to: name) }
                renameTarget = nil
            },
            onCancel: { renameTarget = nil })
        // New subfolder.
        .nameEntryAlert(
            "New Subfolder",
            isPresented: subfolderBinding, text: $subfolderName, confirmLabel: "Create",
            onConfirm: { name in
                if let parent = subfolderParent { model.createFolder(name: name, parent: parent.id) }
                subfolderParent = nil
            },
            onCancel: { subfolderParent = nil })
        // Rename space.
        .nameEntryAlert(
            "Rename Space",
            isPresented: spaceRenameBinding, text: $spaceRenameText, confirmLabel: "Rename",
            onConfirm: { name in
                if let target = spaceRenameTarget { model.renameSpace(id: target.id, to: name) }
                spaceRenameTarget = nil
            },
            onCancel: { spaceRenameTarget = nil })
        // Batch delete confirmation (one dialog for the whole marquee selection).
        .confirmationDialog(
            "Delete \(selection.ids.count) \(selection.ids.count == 1 ? "item" : "items")?",
            isPresented: $showBatchDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performBatchDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchDeleteBreakdown)
        }
    }

    // MARK: - Collections section

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeader("Collections", count: orderedRoots.count)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(orderedRoots) { collection in
                    let isUnsorted = collection.id == model.unsortedFolderID
                    Button {
                        plainCardClick(id: collection.id, unsorted: isUnsorted) {
                            nav.openCollection(collection.id)
                        }
                    } label: {
                        collectionCard(collection)
                    }
                    .buttonStyle(.plain)
                    .modifier(CardSelectionGestures(
                        selectable: !isUnsorted,
                        onCommand: { apply(.commandClick(collection.id)) },
                        onShift: { apply(.shiftClick(collection.id)) }))
                    .overlay { selectionRing(for: collection.id) }
                    .overlay { reparentRing(for: collection.id) }
                    .modifier(CardFrameReporter(id: collection.id, space: Self.gallerySpace) {
                        cardFrames[collection.id] = $0
                    })
                    .contextMenu { cardMenu(for: collection) }
                    .modifier(CollectionReparentDnD(
                        collectionID: collection.id,
                        enabled: collection.id != model.unsortedFolderID,
                        folders: model.folders,
                        unsortedID: model.unsortedFolderID,
                        targetID: $reparentTargetID,
                        onReparent: { model.moveFolder(id: $0, toParent: $1) }))
                }
            }
        }
    }

    @ViewBuilder
    private func collectionCard(_ collection: Collection) -> some View {
        let isUnsorted = collection.id == model.unsortedFolderID
        // The fanned "stack" preview (009 · N4) once loaded; the flat cover card is
        // the pre-load fallback.
        if let preview = model.stackPreviews[collection.id] {
            FanCard(
                title: collection.name,
                itemCount: preview.itemCount,
                seed: collection.id,
                recentBlobHashes: preview.recentBlobHashes,
                thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                accent: isUnsorted,
                placeholderSymbol: isUnsorted ? "tray" : "folder")
        } else {
            CoverCard(
                title: collection.name,
                subtitle: nil,
                coverHash: model.collectionCovers[collection.id],
                coverURL: coverURL(for: collection.id),
                placeholderSymbol: "folder",
                accent: isUnsorted)
        }
    }

    // MARK: - Spaces section

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeader("Spaces", count: model.spaces.count)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.spaces) { space in
                    Button {
                        plainCardClick(id: space.id, unsorted: false) {
                            nav.openSpace(space.id)
                        }
                    } label: {
                        spaceCard(space)
                    }
                    .buttonStyle(.plain)
                    .modifier(CardSelectionGestures(
                        selectable: true,
                        onCommand: { apply(.commandClick(space.id)) },
                        onShift: { apply(.shiftClick(space.id)) }))
                    .overlay { selectionRing(for: space.id) }
                    .modifier(CardFrameReporter(id: space.id, space: Self.gallerySpace) {
                        cardFrames[space.id] = $0
                    })
                    .contextMenu { spaceMenu(for: space) }
                }
            }
        }
    }

    @ViewBuilder
    private func spaceCard(_ space: Space) -> some View {
        if let preview = model.spaceStackPreviews[space.id] {
            FanCard(
                title: space.name,
                itemCount: preview.itemCount,
                seed: space.id,
                recentBlobHashes: preview.recentBlobHashes,
                thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                placeholderSymbol: "square.on.square.dashed")
        } else {
            CoverCard(
                title: space.name,
                subtitle: nil,
                coverHash: model.spaceCovers[space.id],
                coverURL: spaceCoverURL(for: space.id),
                placeholderSymbol: "square.on.square.dashed")
        }
    }

    // MARK: - Marquee (009 · N6)

    /// The transparent background layer that begins a marquee on an empty-area drag
    /// and clears the selection on an empty-area click.
    private var marqueeCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gallerySpace))
                    .onChanged { value in
                        galleryFocused = true
                        marqueeStart = value.startLocation
                        marqueeCurrent = value.location
                        updateMarqueeSelection()
                    }
                    .onEnded { _ in
                        marqueeStart = nil
                        marqueeCurrent = nil
                    })
            .onTapGesture { clearSelection() }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = marqueeRect(from: start, to: current)
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func selectionRing(for id: UUID) -> some View {
        if selection.ids.contains(id) {
            // Ring radius = the card's own `cover` radius, so the selection outline
            // hugs the card shape (the app-wide rule: rings match their surface).
            RoundedRectangle(cornerRadius: Theme.Radius.cover)
                .stroke(Color.accentColor, lineWidth: 3)
        }
    }

    /// The drop ring shown while a folder-reparent drag hovers this card (043) — a
    /// dashed accent border so it reads as "drop to nest here", distinct from the
    /// solid marquee-selection ring.
    @ViewBuilder
    private func reparentRing(for id: UUID) -> some View {
        if reparentTargetID == id {
            RoundedRectangle(cornerRadius: Theme.Radius.cover)
                .strokeBorder(
                    Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }

    /// The floating "N selected · Clear · Delete" bar, shown while a marquee
    /// selection is active.
    private var selectionBar: some View {
        HStack(spacing: 2) {
            Text("\(selection.ids.count) selected")
                .font(.callout.weight(.medium))
                .padding(.trailing, 10)
            SelectionBarButton("xmark", help: "Clear selection") { clearSelection() }
            SelectionBarButton("trash", help: "Delete \(selection.ids.count)",
                               role: .destructive) { requestBatchDelete() }
        }
        .selectionBarChrome()
    }

    /// The ids the marquee may select: every root collection EXCEPT Unsorted, plus
    /// every space. Recomputed each hit so a deleted card can't linger selected.
    private var selectableIDs: Set<UUID> {
        var ids = Set(orderedRoots.map(\.id))
        ids.remove(model.unsortedFolderID)
        ids.formUnion(model.spaces.map(\.id))
        return ids
    }

    /// The selectable cards in DISPLAY order — the reducer's `order` for ⇧-range
    /// and ⌘A. Roots first (Unsorted excluded — it can't be deleted or selected),
    /// then spaces, matching the on-screen top-to-bottom card order.
    private var orderIDs: [UUID] {
        orderedRoots.map(\.id).filter { $0 != model.unsortedFolderID }
            + model.spaces.map(\.id)
    }

    /// Apply a reducer action against the selectable order; run `navigate` when the
    /// reducer resolves to an "open" (a plain click on an idle card pushes its
    /// screen — the gallery's analog of the grid's open-detail effect, 048).
    private func apply(_ action: GridSelectionAction, navigate: (() -> Void)? = nil) {
        let (next, effect) = selection.applying(action, order: orderIDs)
        if next != selection { selection = next }
        if case .openDetail = effect { navigate?() }
    }

    /// A plain (no-modifier) card click: navigate when idle, toggle when selecting
    /// — Finder parity with the collection grid. Unsorted always navigates (it's
    /// never selectable). ⌘/⇧ clicks are owned by ``CardSelectionGestures`` because
    /// a SwiftUI `Button` doesn't fire reliably on a modified click.
    private func plainCardClick(id: UUID, unsorted: Bool, navigate: @escaping () -> Void) {
        let flags = NSEvent.modifierFlags
        guard !flags.contains(.shift), !flags.contains(.command) else { return }
        if unsorted { navigate(); return }
        apply(gridClickAction(imageID: id, shift: false, command: false), navigate: navigate)
    }

    private func updateMarqueeSelection() {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let rect = marqueeRect(from: start, to: current)
        let valid = selectableIDs
        let entries = cardFrames.filter { valid.contains($0.key) }
        let ids = Array(entries.keys)
        let frames = ids.map { entries[$0]! }
        let hits = Set(marqueeIndices(in: rect, frames: frames).map { ids[$0] })
        apply(.marquee(hits: hits, base: []))
    }

    private func clearSelection() {
        if selection.isSelecting { apply(.clear) }
    }

    private func requestBatchDelete() {
        guard selection.isSelecting else { return }
        showBatchDelete = true
    }

    private func performBatchDelete() {
        model.deleteCards(collectionIDs: selectedCollectionIDs, spaceIDs: selectedSpaceIDs)
        clearSelection()
    }

    private var selectedCollectionIDs: [UUID] {
        let valid = Set(orderedRoots.map(\.id)).subtracting([model.unsortedFolderID])
        return Array(selection.ids.filter { valid.contains($0) })
    }

    private var selectedSpaceIDs: [UUID] {
        let valid = Set(model.spaces.map(\.id))
        return Array(selection.ids.filter { valid.contains($0) })
    }

    private var batchDeleteBreakdown: String {
        let c = selectedCollectionIDs.count
        let s = selectedSpaceIDs.count
        var parts: [String] = []
        if c > 0 { parts.append("\(c) collection\(c == 1 ? "" : "s")") }
        if s > 0 { parts.append("\(s) space\(s == 1 ? "" : "s")") }
        return parts.isEmpty ? "This can’t be undone for collections." : parts.joined(separator: ", ")
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.inkPrimary)
            // The section count, styled like every other page's "N items" subtitle
            // (`.callout`, secondary ink) so counts read the same app-wide.
            Text("\(count)")
                .font(.callout)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
    }

    // MARK: - Ordering (Unsorted pinned first)

    private var orderedRoots: [Collection] {
        // The ONE definition of collection ordering (009 · 6B) — shared with the
        // Move/Add menus and the sidebar rows so they can never drift apart.
        CollectionTargets.galleryRoots(model.folders, unsortedID: model.unsortedFolderID)
    }

    private func coverURL(for id: UUID) -> URL? {
        guard let hash = model.collectionCovers[id] else { return nil }
        return model.thumbnailURL(forBlobHash: hash)
    }

    private func spaceCoverURL(for id: UUID) -> URL? {
        guard let hash = model.spaceCovers[id] else { return nil }
        return model.thumbnailURL(forBlobHash: hash)
    }

    // MARK: - Context menus

    @ViewBuilder
    private func cardMenu(for collection: Collection) -> some View {
        Button("New Subfolder…") {
            subfolderName = ""
            subfolderParent = collection
        }
        if collection.id != model.unsortedFolderID {
            Button("Rename…") {
                renameText = collection.name
                renameTarget = collection
            }
            CollectionMoveToMenu(
                folderID: collection.id, folders: model.folders,
                unsortedID: model.unsortedFolderID
            ) { model.moveFolder(id: collection.id, toParent: $0) }
            Divider()
            Button("Delete", role: .destructive) {
                model.deleteFolder(id: collection.id)
            }
        }
    }

    @ViewBuilder
    private func spaceMenu(for space: Space) -> some View {
        Button("Rename…") {
            spaceRenameText = space.name
            spaceRenameTarget = space
        }
        Divider()
        Button("Delete…", role: .destructive) {
            model.requestDeleteSpace(id: space.id, name: space.name)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var subfolderBinding: Binding<Bool> {
        Binding(get: { subfolderParent != nil }, set: { if !$0 { subfolderParent = nil } })
    }

    private var spaceRenameBinding: Binding<Bool> {
        Binding(get: { spaceRenameTarget != nil }, set: { if !$0 { spaceRenameTarget = nil } })
    }
}

/// The ⌘-click (toggle) and ⇧-click (range) selection gestures for a card (048).
/// A SwiftUI `Button` doesn't fire its action on a modified click, so these
/// modifier-aware tap gestures own the modifiers — the same pattern the grid and
/// search cells use. Attached only when `selectable` (never on Unsorted).
private struct CardSelectionGestures: ViewModifier {
    let selectable: Bool
    let onCommand: () -> Void
    let onShift: () -> Void

    func body(content: Content) -> some View {
        if selectable {
            content
                .simultaneousGesture(TapGesture().modifiers(.command).onEnded(onCommand))
                .simultaneousGesture(TapGesture().modifiers(.shift).onEnded(onShift))
        } else {
            content
        }
    }
}

/// Publishes a card's frame in the shared gallery coordinate space (009 · N6), so
/// the marquee can hit-test against every card without a per-cell GeometryReader
/// in the layout. Split into a modifier to keep the grid `ForEach` readable.
private struct CardFrameReporter: ViewModifier {
    let id: UUID
    let space: String
    let report: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(space))
        } action: {
            report($0)
        }
    }
}

/// Makes a collection card a folder-reparent drag SOURCE and drop TARGET (043):
/// drag a card onto another to nest it under that one. Disabled (`enabled == false`)
/// for the protected Unsorted card — it can't be moved, and folders aren't filed
/// under it. A drop is refused when it would form a cycle (dropping a folder onto
/// itself or one of its own descendants); `IngestionModel.moveFolder` guards the
/// same case server-side, so an escaped invalid drop is still safe.
private struct CollectionReparentDnD: ViewModifier {
    let collectionID: UUID
    let enabled: Bool
    let folders: [Collection]
    let unsortedID: UUID
    @Binding var targetID: UUID?
    /// `(dragged, newParent)`.
    let onReparent: (UUID, UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(CollectionDragPayload(collectionID: collectionID))
                .dropDestination(for: CollectionDragPayload.self) { payloads, _ in
                    defer { if targetID == collectionID { targetID = nil } }
                    // Gated by the shared predicate (043 · 5A) — the same rule the
                    // sidebar uses, so the two surfaces can't diverge.
                    guard let dragged = payloads.first?.collectionID,
                          CollectionTargets.canReparent(
                            dragged, into: collectionID,
                            folders: folders, unsortedID: unsortedID)
                    else { return false }
                    onReparent(dragged, collectionID)
                    return true
                } isTargeted: { over in
                    if over { targetID = collectionID }
                    else if targetID == collectionID { targetID = nil }
                }
        } else {
            content
        }
    }
}
