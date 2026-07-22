//
//  SidebarView.swift
//  AtelierRefs
//
//  006 — the split-view shell's left sidebar (Figma nodes 1:3 expanded / 5:92
//  collapsed). Two states, driven by ``NavModel/sidebarCollapsed``:
//   • Expanded (273pt): traffic-light space, the Home/Search/Capture/Settings nav,
//     the Spaces section, the Collections tree, and a footer (sort + trash).
//   • Collapsed (60pt = the traffic-light footprint): the toggle at top, sort +
//     trash at the bottom — the same rail the item-detail view reuses.
//
//  Selection drives the detail panel via ``NavModel/sidebarSelection``; the tree /
//  spaces are read from the shared ``IngestionModel`` (the one ordering source is
//  `CollectionTargets.galleryRoots`, Unsorted pinned).
//

import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel

    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var showNewSpace = false
    @State private var newSpaceName = ""
    @State private var spacesExpanded = true
    @State private var collectionsExpanded = true
    /// The sidebar row currently under an asset drag (space or collection id), for
    /// the drop highlight. One id at a time — a drag hovers a single row.
    @State private var dropTargetID: UUID?

    /// The ⌥ (copy) read at drop time, shared with the collection drop rail
    /// (009 · N3): a plain drop MOVES into a collection, ⌥ COPIES.
    private static let modifierReader: ModifierReading = LiveModifierReader()

    /// The traffic lights overlay the top-left; inset content below them.
    private let trafficLightInset: CGFloat = 40

    var body: some View {
        Group {
            if nav.sidebarCollapsed { rail } else { full }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Redundant with bootstrap's own `refreshSpaces` (which owns the load —
        // this can run first and no-op while `services` is still nil); kept so a
        // re-mounted sidebar refreshes.
        .task { await model.refreshSpaces() }
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
        // New space.
        .alert("New Space", isPresented: $showNewSpace) {
            TextField("Name", text: $newSpaceName)
            Button("Create") {
                let name = newSpaceName
                newSpaceName = ""
                Task { if let id = await model.createSpace(name: name) { nav.openSpace(id) } }
            }
            .disabled(newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newSpaceName = "" }
        }
    }

    // MARK: - Expanded (273pt)

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Traffic-light space + the collapse toggle, trailing.
            HStack {
                Spacer()
                collapseToggle
            }
            .frame(height: trafficLightInset, alignment: .center)
            .padding(.horizontal, Theme.Spacing.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    navSection
                    spacesSection
                    collectionsSection
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
            }

            footer
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(width: 273)
    }

    private var navSection: some View {
        // Search is no longer a row here — it lives as the panel's top search field.
        VStack(alignment: .leading, spacing: 6) {
            navRow(.home, "Home", "house")
            navRow(.capture, "Capture", "puzzlepiece.extension")
            navRow(.settings, "Settings", "gearshape")
        }
    }

    private func navRow(_ item: SidebarItem, _ title: String, _ symbol: String) -> some View {
        Button {
            nav.selectSidebar(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(title).font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .background(rowHighlight(selected: nav.sidebarSelection == item))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Spaces

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader("Spaces", expanded: $spacesExpanded) { showNewSpace = true }
            if spacesExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if model.spaces.isEmpty {
                        if model.spacesLoaded { spacesEmptyRow } else { spacesLoadingRows }
                    } else {
                        ForEach(model.spaces) { space in
                            treeRow(
                                title: space.name,
                                selected: nav.sidebarSelection == .space(space.id),
                                dropID: space.id,
                                select: { nav.openSpace(space.id) },
                                onDrop: { handleSpaceDrop($0, into: space.id) })
                                .contextMenu {
                                    Button("Delete…", role: .destructive) {
                                        model.requestDeleteSpace(id: space.id, name: space.name)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    /// Skeleton rows while the first `refreshSpaces` is in flight.
    private var spacesLoadingRows: some View {
        ForEach(0..<2, id: \.self) { _ in
            Text("Loading space")
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .redacted(reason: .placeholder)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
        }
    }

    private var spacesEmptyRow: some View {
        Text("No spaces yet")
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader("Collections", expanded: $collectionsExpanded) {
                showNewCollection = true
            }
            if collectionsExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(roots) { collection in
                        treeRow(
                            title: collection.name,
                            selected: nav.sidebarSelection == .collection(collection.id),
                            dropID: collection.id,
                            select: { nav.selectSidebar(.collection(collection.id)) },
                            onDrop: { handleCollectionDrop($0, into: collection.id) })
                            .contextMenu { collectionMenu(collection) }
                    }
                }
            }
        }
    }

    private var roots: [Collection] {
        CollectionTargets.galleryRoots(model.folders, unsortedID: model.unsortedFolderID)
    }

    @ViewBuilder
    private func collectionMenu(_ collection: Collection) -> some View {
        if collection.id != model.unsortedFolderID {
            Button("Delete", role: .destructive) { model.deleteFolder(id: collection.id) }
        }
    }

    // MARK: - Shared rows

    private func sectionHeader(
        _ title: String, expanded: Binding<Bool>, add: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(Theme.Motion.snappy) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(Theme.Typography.navItem)
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.Colors.inkPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// A space / collection row. When `dropID` and `onDrop` are supplied the row is
    /// also an asset drop target: a drag over it highlights the row and the drop
    /// moves/copies (collections) or adds (spaces) the dragged assets. `.onDrop`
    /// (not `.dropDestination`) so the AppKit grid drag is recognised — see
    /// ``CollectionDropRail``.
    private func treeRow(
        title: String, selected: Bool, dropID: UUID? = nil,
        select: @escaping () -> Void,
        onDrop: ((AssetDragPayload) -> Bool)? = nil
    ) -> some View {
        let targeted = dropID != nil && dropTargetID == dropID
        return Button(action: select) {
            Text(title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
                .background(rowHighlight(selected: selected, targeted: targeted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RowDropModifier(dropID: dropID, dropTargetID: $dropTargetID, onDrop: onDrop))
    }

    private func rowHighlight(selected: Bool, targeted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(targeted ? Theme.Colors.selection : (selected ? Theme.Colors.selection : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        targeted ? Color.accentColor
                            : (selected ? Theme.Colors.hairlineStrong : .clear),
                        lineWidth: targeted ? 1.5 : 1))
    }

    // MARK: - Drop routing

    /// Move (⌥ = copy) the dragged assets into `collectionID`. Mirrors the collection
    /// screen's rail drop (009 · N3): the same ``routeDrop`` decision so `from == to`
    /// / empty are refused in ONE place. `moveToCollection` reads the source from the
    /// model's `selectedFolderID`, which is the grid the drag came from.
    private func handleCollectionDrop(_ payload: AssetDragPayload, into collectionID: UUID) -> Bool {
        switch routeDrop(
            payload, onto: .collection(collectionID),
            optionDown: Self.modifierReader.isOptionDown) {
        case let .move(assetIDs, _, to):
            model.moveToCollection(assetIDs: assetIDs, to: to)
            return true
        case let .copy(assetIDs, to):
            model.copyToCollection(assetIDs: assetIDs, to: to)
            return true
        case .reject, .reorder:
            return false
        }
    }

    /// ADD the dragged assets to `spaceID` (a space is a placement board — always
    /// additive, never a move). An empty payload is refused.
    private func handleSpaceDrop(_ payload: AssetDragPayload, into spaceID: UUID) -> Bool {
        guard !payload.assetIDs.isEmpty else { return false }
        model.addAssetsToSpace(assetIDs: payload.assetIDs, to: spaceID)
        return true
    }

    // MARK: - Footer / rail controls

    private var footer: some View {
        HStack(spacing: Theme.Spacing.lg) {
            sortMenu
            trashButton
            Spacer()
        }
    }

    private var collapseToggle: some View {
        Button {
            withAnimation(Theme.Motion.snappy) { nav.sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .buttonStyle(.plain)
        .help("Collapse sidebar")
    }

    /// Sort acts on the active collection (the one the panel is showing).
    private var sortMenu: some View {
        Menu {
            sortButton(.manual, "Manual")
            sortButton(.newest, "Newest")
            sortButton(.mostViewed, "Most Viewed")
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort the current collection")
    }

    private func sortButton(_ mode: SortMode, _ title: String) -> some View {
        let id = model.selectedFolderID
        let active = model.sortMode(for: id) == mode
        return Button {
            model.setSortMode(mode, for: id)
        } label: {
            if active { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var trashButton: some View {
        Button {
            model.requestDeleteSelected()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .buttonStyle(.plain)
        .help("Delete the selected items")
    }

    // MARK: - Collapsed rail (60pt)

    private var rail: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                collapseToggle
            }
            .frame(height: trafficLightInset, alignment: .center)
            .padding(.horizontal, Theme.Spacing.md)

            Spacer()

            VStack(alignment: .trailing, spacing: Theme.Spacing.lg) {
                sortMenu
                trashButton
            }
            .padding(.trailing, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(width: 60)
    }
}

/// Attaches an asset-drop target to a sidebar row ONLY when it has a `dropID` +
/// `onDrop` — nav rows (Home/Capture/Settings) opt out by passing neither, so a
/// drag over them is a plain no-op. Kept as a modifier (not an inline `if`) so a
/// row's identity is stable whether or not it accepts drops. `.onDrop` (not
/// `.dropDestination`) recognises the AppKit grid drag — see ``CollectionDropRail``.
private struct RowDropModifier: ViewModifier {
    let dropID: UUID?
    @Binding var dropTargetID: UUID?
    let onDrop: ((AssetDragPayload) -> Bool)?

    func body(content: Content) -> some View {
        if let dropID, let onDrop {
            content.onDrop(of: [.assetIDs], isTargeted: Binding(
                get: { dropTargetID == dropID },
                set: { over in
                    if over { dropTargetID = dropID }
                    else if dropTargetID == dropID { dropTargetID = nil }
                })) { providers in
                AssetDragPayload.fromDrop(providers) { payload in
                    _ = onDrop(payload)
                    if dropTargetID == dropID { dropTargetID = nil }
                }
            }
        } else {
            content
        }
    }
}
