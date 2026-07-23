//
//  CollectionMoveToMenu.swift
//  AtelierRefs
//
//  043 — the shared "Move to ▸" submenu for reparenting a collection, used by
//  every collection context menu (the Home gallery cards, the sidebar tree rows,
//  and the collection screen's subfolder chips) so the target list + ordering are
//  computed in ONE place (``CollectionTargets/folderMoveTargets``). Selecting a
//  target calls back with the new parent id; "Top Level" calls back with `nil`
//  (un-nest). The invalid targets — self, descendants, current parent, Unsorted —
//  are already excluded by the target computation, so every listed option is a
//  legal move.
//

import AtelierCore
import SwiftUI

struct CollectionMoveToMenu: View {
    let folderID: UUID
    let folders: [Collection]
    let unsortedID: UUID
    /// `nil` new parent = move to top level.
    let onMove: (UUID?) -> Void

    private var hasParent: Bool {
        folders.first { $0.id == folderID }?.parentCollectionID != nil
    }

    var body: some View {
        Menu("Move to") {
            if hasParent {
                Button("Top Level") { onMove(nil) }
                Divider()
            }
            let targets = CollectionTargets.folderMoveTargets(
                for: folderID, folders: folders, unsortedID: unsortedID)
            if targets.isEmpty {
                Text("No available folders")
            } else {
                ForEach(targets) { target in
                    Button(target.name) { onMove(target.id) }
                }
            }
        }
    }
}
