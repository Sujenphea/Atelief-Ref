//
//  AddFromLibrarySheet.swift
//  AtelierRefs
//
//  005-E2 — the in-space "Add from Library" picker: choose a collection, then
//  multi-select its items to flow into the open space. Loads the chosen
//  collection's items on demand (WITHOUT disturbing the main selected-folder
//  state) and returns the picked assets to the caller, which flows them in.
//

import AtelierCore
import SwiftUI

struct AddFromLibrarySheet: View {
    @ObservedObject var model: IngestionModel
    /// Called with the chosen assets when the user confirms.
    let onAdd: ([Asset]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickedCollectionID: UUID?
    @State private var items: [CollectionItemDetail] = []
    @State private var selected: Set<UUID> = []   // asset ids
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .task {
            await model.refreshFolders()
            if pickedCollectionID == nil {
                pickedCollectionID = model.unsortedFolderID
            }
        }
        .task(id: pickedCollectionID) { await loadItems() }
    }

    private var picker: some View {
        HStack {
            Text("Add from").font(.headline)
            Picker("", selection: $pickedCollectionID) {
                ForEach(sortedFolders) { folder in
                    Text(folder.name).tag(Optional(folder.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder private var grid: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text("No items in this collection.")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items, id: \.item.id) { detail in
                        Button {
                            toggle(detail.asset.id)
                        } label: {
                            AssetContentThumbnail(
                                asset: detail.asset,
                                url: model.thumbnailURL(for: detail),
                                isSelected: selected.contains(detail.asset.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(selected.isEmpty ? "Select items to add" : "\(selected.count) selected")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                let chosen = items
                    .filter { selected.contains($0.asset.id) }
                    .map(\.asset)
                onAdd(chosen)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .padding(12)
    }

    private var sortedFolders: [Collection] {
        model.folders.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    private func toggle(_ assetID: UUID) {
        if selected.contains(assetID) { selected.remove(assetID) } else { selected.insert(assetID) }
    }

    private func loadItems() async {
        guard let id = pickedCollectionID else { items = []; return }
        isLoading = true
        selected = []
        do {
            items = try await model.items(in: id)
        } catch {
            items = []
        }
        isLoading = false
    }
}
