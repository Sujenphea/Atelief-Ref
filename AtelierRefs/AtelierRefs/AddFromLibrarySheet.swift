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
    @Environment(\.displayScale) private var displayScale
    @State private var pickedCollectionID: UUID?
    @State private var items: [CollectionItemDetail] = []
    /// Picked assets keyed by asset id, ACCUMULATED across collection switches so
    /// changing the picker no longer silently discards a cross-collection selection.
    @State private var picked: [UUID: Asset] = [:]
    @State private var isLoading = false

    /// The widest a cell here can draw — the `columns` maximum below. Kept next
    /// to it so the thumbnail bucket can't drift from the layout that sets it.
    private static let maxCellSide: CGFloat = 120
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: maxCellSide), spacing: 8)]

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
            if !items.isEmpty {
                Button(allSelectedHere ? "Deselect All" : "Select All") {
                    toggleSelectAllHere()
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
    }

    /// Whether every item in the CURRENT collection is already picked.
    private var allSelectedHere: Bool {
        !items.isEmpty && items.allSatisfy { picked[$0.asset.id] != nil }
    }

    /// Select (or clear) all items in the current collection, leaving picks from
    /// other collections intact.
    private func toggleSelectAllHere() {
        if allSelectedHere {
            for detail in items { picked[detail.asset.id] = nil }
        } else {
            for detail in items { picked[detail.asset.id] = detail.asset }
        }
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
                            toggle(detail.asset)
                        } label: {
                            // The columns are `.adaptive(minimum: 96, maximum: 120)`,
                            // so 120 pt is the widest a cell here ever draws →
                            // 240 px at 2× → the 256 bucket (036 §4 C3).
                            AssetContentThumbnail(
                                asset: detail.asset,
                                url: model.thumbnailURL(for: detail),
                                isSelected: picked[detail.asset.id] != nil,
                                bucket: thumbnailPixelBucket(
                                    pointLongSide: Self.maxCellSide, scale: displayScale))
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
            Text(picked.isEmpty ? "Select items to add" : "\(picked.count) selected")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                onAdd(Array(picked.values))
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty)
        }
        .padding(12)
    }

    private var sortedFolders: [Collection] {
        model.folders.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    private func toggle(_ asset: Asset) {
        if picked[asset.id] != nil { picked[asset.id] = nil } else { picked[asset.id] = asset }
    }

    private func loadItems() async {
        guard let id = pickedCollectionID else { items = []; return }
        isLoading = true
        // NB: `picked` is intentionally NOT cleared here — picks accumulate across
        // collection switches (the previous behaviour discarded them silently).
        do {
            items = try await model.items(in: id)
        } catch {
            items = []
        }
        isLoading = false
    }
}
