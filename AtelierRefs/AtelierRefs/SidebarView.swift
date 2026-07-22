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

struct SidebarView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel

    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var showNewSpace = false
    @State private var newSpaceName = ""
    @State private var spacesExpanded = true
    @State private var collectionsExpanded = true

    /// The traffic lights overlay the top-left; inset content below them.
    private let trafficLightInset: CGFloat = 40

    var body: some View {
        Group {
            if nav.sidebarCollapsed { rail } else { full }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 5)
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
                ForEach(model.spaces) { space in
                    treeRow(
                        title: space.name,
                        selected: nav.sidebarSelection == .space(space.id),
                        select: { nav.openSpace(space.id) })
                        .contextMenu {
                            Button("Delete…", role: .destructive) {
                                model.requestDeleteSpace(id: space.id, name: space.name)
                            }
                        }
                }
            }
        }
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
                            select: { nav.selectSidebar(.collection(collection.id)) })
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

    private func treeRow(
        title: String, selected: Bool, select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            Text(title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
                .background(rowHighlight(selected: selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowHighlight(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Theme.Colors.selection : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Theme.Colors.hairlineStrong : .clear, lineWidth: 1))
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
