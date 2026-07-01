//
//  FolderTreeView.swift
//  AtelierRefs
//
//  Chunk 3 (folders) — the sidebar folder tree. Renders the nested folder
//  hierarchy with a selectable `List` + `OutlineGroup` over the `FolderNode`
//  tree, with a context menu per folder (New Subfolder / Rename / Move / Delete)
//  and a toolbar "New Folder" for a root. Rename / Delete / Move are disabled
//  for the protected Unsorted folder (the service also rejects them).
//

import AtelierCore
import SwiftUI

struct FolderTreeView: View {
    @ObservedObject var model: IngestionModel
    @State private var prompt: NamePrompt?

    /// Single-selection binding driving the model's selected folder + a
    /// contents reload on change.
    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedFolderID },
            set: { newValue in
                guard let newValue else { return }
                model.selectedFolderID = newValue
                model.loadContents(of: newValue)
            })
    }

    var body: some View {
        List(selection: selection) {
            OutlineGroup(model.folderTree, children: \.children) { node in
                folderRow(node)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    prompt = NamePrompt(kind: .newRoot, title: "New Folder")
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!model.isReady)
            }
        }
        .sheet(item: $prompt) { prompt in
            NameSheet(prompt: prompt) { name in
                switch prompt.kind {
                case .newRoot:
                    model.createFolder(name: name, parent: nil)
                case .newSubfolder(let parent):
                    model.createFolder(name: name, parent: parent)
                case .rename(let id):
                    model.renameFolder(id: id, to: name)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func folderRow(_ node: FolderNode) -> some View {
        let isProtected = node.id == model.unsortedFolderID
        Label(node.name, systemImage: isProtected ? "tray" : "folder")
            .tag(node.id)
            .contextMenu {
                Button("New Subfolder") {
                    prompt = NamePrompt(kind: .newSubfolder(parent: node.id), title: "New Subfolder")
                }
                Button("Rename") {
                    prompt = NamePrompt(kind: .rename(id: node.id), title: "Rename Folder", text: node.name)
                }
                .disabled(isProtected)

                moveMenu(for: node)
                    .disabled(isProtected)

                Divider()
                Button("Delete", role: .destructive) {
                    model.deleteFolder(id: node.id)
                }
                .disabled(isProtected)
            }
    }

    /// A "Move to…" submenu: every other folder as a new parent, plus "Top
    /// Level". The service rejects cycles / protected moves with an alert.
    @ViewBuilder
    private func moveMenu(for node: FolderNode) -> some View {
        Menu("Move to…") {
            Button("Top Level") {
                model.moveFolder(id: node.id, toParent: nil)
            }
            Divider()
            ForEach(model.folders.filter { $0.id != node.id }) { candidate in
                Button(candidate.name) {
                    model.moveFolder(id: node.id, toParent: candidate.id)
                }
            }
        }
    }
}

// MARK: - Name entry

/// Identifies a pending name-entry sheet (create root / create subfolder /
/// rename), carrying the sheet title + any prefilled text.
struct NamePrompt: Identifiable {
    enum Kind {
        case newRoot
        case newSubfolder(parent: UUID)
        case rename(id: UUID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var text: String = ""

    init(kind: Kind, title: String, text: String = "") {
        self.kind = kind
        self.title = title
        self.text = text
    }
}

/// A small modal sheet for entering a folder name.
private struct NameSheet: View {
    let prompt: NamePrompt
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(prompt: NamePrompt, onCommit: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onCommit = onCommit
        _name = State(initialValue: prompt.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title).font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
