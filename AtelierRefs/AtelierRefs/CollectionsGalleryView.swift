//
//  CollectionsGalleryView.swift
//  AtelierRefs
//
//  004-P2 — the app's home screen: a gallery of the ROOT collections as cover
//  cards (the persistent folder tree is gone; drilling in reuses subfolder chips
//  + grid). The protected "Unsorted" folder is pinned as the first card (004 Q2).
//  Card context menus cover rename / delete / new subfolder; a toolbar "+" makes
//  a new root collection. Tapping a card pushes its `CollectionView`.
//

import AtelierCore
import SwiftUI

struct CollectionsGalleryView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel

    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var renameTarget: Collection?
    @State private var renameText = ""
    @State private var subfolderParent: Collection?
    @State private var subfolderName = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        // 006 shell — the top-level Home overview. The old `.searchable` field +
        // "New Collection" toolbar button are gone: Search is a sidebar destination
        // and New Collection is the sidebar's Collections "+".
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(orderedRoots) { collection in
                    Button {
                        nav.openCollection(collection.id)
                    } label: {
                        CoverCard(
                            title: collection.name,
                            subtitle: nil,
                            coverHash: model.collectionCovers[collection.id],
                            coverURL: coverURL(for: collection.id),
                            placeholderSymbol: "folder",
                            accent: collection.id == model.unsortedFolderID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { cardMenu(for: collection) }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .task {
            await model.refreshFolders()
            await model.refreshCollectionCovers()
        }
        // New root collection.
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName
                newCollectionName = ""
                model.createFolder(name: name, parent: nil)
            }
            .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
        // Rename.
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
    }

    // MARK: - Ordering (Unsorted pinned first)

    private var orderedRoots: [Collection] {
        // The ONE definition of collection ordering (009 · 6B) — shared with the
        // Move/Add menus and the drop rail so the three can never drift apart.
        CollectionTargets.galleryRoots(model.folders, unsortedID: model.unsortedFolderID)
    }

    private func coverURL(for id: UUID) -> URL? {
        guard let hash = model.collectionCovers[id] else { return nil }
        return model.thumbnailURL(forBlobHash: hash)
    }

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

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var subfolderBinding: Binding<Bool> {
        Binding(get: { subfolderParent != nil }, set: { if !$0 { subfolderParent = nil } })
    }
}
