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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        // 006 shell — the top-level Home overview. Search is a sidebar destination;
        // New Collection / New Space are the sidebar sections' "+".
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                collectionsSection
                // Spaces are additive — hidden entirely until the user has one, so
                // Home stays collection-focused for a fresh library.
                if !model.spaces.isEmpty {
                    spacesSection
                }
            }
            .padding(Theme.Spacing.xl)
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
