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

    // Marquee selection (009 · N6).
    @State private var selectedCardIDs: Set<UUID> = []
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var showBatchDelete = false
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
                    collectionsSection
                    // Spaces are additive — hidden entirely until the user has one,
                    // so Home stays collection-focused for a fresh library.
                    if !model.spaces.isEmpty {
                        spacesSection
                    }
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
        .overlay(alignment: .bottom) {
            if !selectedCardIDs.isEmpty { selectionBar }
        }
        .task {
            await model.refreshFolders()
            await model.refreshCollectionCovers()
            await model.refreshStackPreviews()
            await model.refreshSpaces()
            await model.refreshSpaceStackPreviews()
        }
        // Rename collection.
        .alert("Rename Collection", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.renameFolder(id: target.id, to: renameText) }
                renameTarget = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        // New subfolder.
        .alert("New Subfolder", isPresented: subfolderBinding) {
            TextField("Name", text: $subfolderName)
            Button("Create") {
                if let parent = subfolderParent {
                    model.createFolder(name: subfolderName, parent: parent.id)
                }
                subfolderName = ""
                subfolderParent = nil
            }
            .disabled(subfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { subfolderName = ""; subfolderParent = nil }
        }
        // Rename space.
        .alert("Rename Space", isPresented: spaceRenameBinding) {
            TextField("Name", text: $spaceRenameText)
            Button("Rename") {
                if let target = spaceRenameTarget { model.renameSpace(id: target.id, to: spaceRenameText) }
                spaceRenameTarget = nil
            }
            .disabled(spaceRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { spaceRenameTarget = nil }
        }
        // Batch delete confirmation (one dialog for the whole marquee selection).
        .confirmationDialog(
            "Delete \(selectedCardIDs.count) \(selectedCardIDs.count == 1 ? "item" : "items")?",
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
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Collections")
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(orderedRoots) { collection in
                    Button {
                        nav.openCollection(collection.id)
                    } label: {
                        collectionCard(collection)
                    }
                    .buttonStyle(.plain)
                    .overlay { selectionRing(for: collection.id) }
                    .modifier(CardFrameReporter(id: collection.id, space: Self.gallerySpace) {
                        cardFrames[collection.id] = $0
                    })
                    .contextMenu { cardMenu(for: collection) }
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
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Spaces")
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.spaces) { space in
                    Button {
                        nav.openSpace(space.id)
                    } label: {
                        spaceCard(space)
                    }
                    .buttonStyle(.plain)
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
        if selectedCardIDs.contains(id) {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor, lineWidth: 3)
        }
    }

    /// The floating "N selected · Clear · Delete" bar, shown while a marquee
    /// selection is active.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedCardIDs.count) selected")
                .font(.callout.weight(.medium))
            Button("Clear") { clearSelection() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { requestBatchDelete() } label: {
                Label("Delete \(selectedCardIDs.count)", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 16)
    }

    /// The ids the marquee may select: every root collection EXCEPT Unsorted, plus
    /// every space. Recomputed each hit so a deleted card can't linger selected.
    private var selectableIDs: Set<UUID> {
        var ids = Set(orderedRoots.map(\.id))
        ids.remove(model.unsortedFolderID)
        ids.formUnion(model.spaces.map(\.id))
        return ids
    }

    private func updateMarqueeSelection() {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let rect = marqueeRect(from: start, to: current)
        let valid = selectableIDs
        let entries = cardFrames.filter { valid.contains($0.key) }
        let ids = Array(entries.keys)
        let frames = ids.map { entries[$0]! }
        selectedCardIDs = Set(marqueeIndices(in: rect, frames: frames).map { ids[$0] })
    }

    private func clearSelection() {
        if !selectedCardIDs.isEmpty { selectedCardIDs = [] }
    }

    private func requestBatchDelete() {
        guard !selectedCardIDs.isEmpty else { return }
        showBatchDelete = true
    }

    private func performBatchDelete() {
        model.deleteCards(collectionIDs: selectedCollectionIDs, spaceIDs: selectedSpaceIDs)
        clearSelection()
    }

    private var selectedCollectionIDs: [UUID] {
        let valid = Set(orderedRoots.map(\.id)).subtracting([model.unsortedFolderID])
        return Array(selectedCardIDs.filter { valid.contains($0) })
    }

    private var selectedSpaceIDs: [UUID] {
        let valid = Set(model.spaces.map(\.id))
        return Array(selectedCardIDs.filter { valid.contains($0) })
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
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
