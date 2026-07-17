//
//  SpacesListView.swift
//  AtelierRefs
//
//  005-E2 — the list of spaces as cover cards (reusing the gallery card
//  pattern). A toolbar "+" creates a space (and opens it); card context menus
//  cover rename / delete. Tapping a card pushes its `SpaceView`.
//

import AtelierCore
import SwiftUI

struct SpacesListView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel

    @State private var showNewSpace = false
    @State private var newSpaceName = ""
    @State private var renameTarget: Space?
    @State private var renameText = ""
    /// Whether the first `refreshSpaces` has completed. Until it has, an empty
    /// `model.spaces` means "not loaded yet", NOT "no spaces" — so we show a
    /// skeleton instead of flashing the "No spaces yet" empty state to users who
    /// actually have spaces (034 P2 loading-flash).
    @State private var didLoad = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            if model.spaces.isEmpty {
                if didLoad { emptyState } else { loadingState }
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.spaces) { space in
                        Button {
                            nav.openSpace(space.id)
                        } label: {
                            CoverCard(
                                title: space.name,
                                subtitle: nil,
                                coverHash: model.spaceCovers[space.id],
                                coverURL: coverURL(for: space.id),
                                placeholderSymbol: "square.on.square.dashed")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") {
                                renameText = space.name
                                renameTarget = space
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                model.requestDeleteSpace(id: space.id, name: space.name)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Spaces")
        .toolbar {
            ToolbarItem {
                Button { showNewSpace = true } label: {
                    Label("New Space", systemImage: "plus.square.dashed")
                }
            }
        }
        .task { await model.refreshSpaces(); didLoad = true }
        .alert("New Space", isPresented: $showNewSpace) {
            TextField("Name", text: $newSpaceName)
            Button("Create") {
                let name = newSpaceName
                newSpaceName = ""
                Task {
                    if let id = await model.createSpace(name: name) { nav.openSpace(id) }
                }
            }
            .disabled(newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newSpaceName = "" }
        }
        .alert("Rename Space", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.renameSpace(id: target.id, to: renameText) }
                renameTarget = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    /// Skeleton placeholder shown before the first load resolves — redacted cover
    /// cards, so a user with spaces sees "content loading" rather than a false
    /// "No spaces yet".
    private var loadingState: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in
                CoverCard(
                    title: "Space",
                    subtitle: nil,
                    coverHash: nil,
                    coverURL: nil,
                    placeholderSymbol: "square.on.square.dashed")
            }
        }
        .padding(16)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading spaces")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No spaces yet", systemImage: "square.on.square.dashed")
        } description: {
            Text("Create a space to freely arrange references from any collection.")
        } actions: {
            Button("New Space") { showNewSpace = true }
        }
        .padding(.top, 60)
    }

    private func coverURL(for id: UUID) -> URL? {
        guard let hash = model.spaceCovers[id] else { return nil }
        return model.thumbnailURL(forBlobHash: hash)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
}
