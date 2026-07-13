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
        LibrarySearchable(model: model, collectionID: nil) {
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
                .padding(16)
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem {
                Button { showNewCollection = true } label: {
                    Label("New Collection", systemImage: "folder.badge.plus")
                }
            }
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
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
        // Rename.
        .alert("Rename Collection", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.renameFolder(id: target.id, to: renameText) }
                renameTarget = nil
            }
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
            Button("Cancel", role: .cancel) { subfolderName = ""; subfolderParent = nil }
        }
    }

    // MARK: - Ordering (Unsorted pinned first)

    private var orderedRoots: [Collection] {
        let roots = model.rootCollections
        let unsorted = roots.filter { $0.id == model.unsortedFolderID }
        let rest = roots
            .filter { $0.id != model.unsortedFolderID }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        return unsorted + rest
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
