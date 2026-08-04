//
//  SidebarView.swift
//  AtelierRefs
//
//  006 — the split-view shell's left sidebar (Figma nodes 1:3 expanded / 5:92
//  collapsed). Two states, driven by ``NavModel/sidebarCollapsed``:
//   • Expanded (273pt): traffic-light space, the Home / Capture nav plus a Settings
//     gear that OPENS the ⌘, window (settings is not a destination — see
//     ``SidebarItem``), the Spaces section, the Collections tree, and a footer
//     (sort + trash).
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

    /// Opens the `Settings` scene (⌘,) — the app's only settings surface.
    @Environment(\.openSettings) private var openSettings

    /// Rename a collection from the tree row's context menu (043).
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    /// The in-flight inline "new collection / subfolder" request handed to the
    /// AppKit outline view (214). A fresh token each time re-triggers the draft.
    @State private var collectionDraftRequest: CollectionDraftRequest?
    /// The in-flight inline "new space" request handed to the AppKit spaces outline
    /// view (214) — the flat analog of `collectionDraftRequest`.
    @State private var spaceDraftRequest: SpaceDraftRequest?
    /// Rename a space from its outline-row context menu (043 · spaces).
    @State private var spaceRenameTargetID: UUID?
    @State private var spaceRenameText = ""
    @State private var spacesExpanded = true
    @State private var collectionsExpanded = true
    /// The AppKit outline trees' measured content heights (043 · Phase C), so each
    /// non-scrolling outline view can be framed inside the sidebar's own ScrollView.
    @State private var outlineHeight: CGFloat = 0
    @State private var spaceOutlineHeight: CGFloat = 0

    /// The traffic lights overlay the top-left; inset content below them.
    private let trafficLightInset: CGFloat = 40

    var body: some View {
        Group {
            if nav.sidebarCollapsed { rail } else { full }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The collapse toggle is hoisted OUT of both `rail` and `full` into ONE
        // persistent overlay pinned to the shared 60pt icon column (width 60, centered
        // → x-center 30 in BOTH states). A single view instance that never swaps or
        // shifts, so toggling collapsed⇆expanded can't wiggle its x offset.
        .overlay(alignment: .topLeading) {
            railIcon { collapseToggle }
                .frame(width: 60, height: trafficLightInset)
        }
        // Redundant with bootstrap's own `refreshSpaces` (which owns the load —
        // this can run first and no-op while `services` is still nil); kept so a
        // re-mounted sidebar refreshes.
        .task { await model.refreshSpaces() }
        // Rename a collection (inline creation replaced the create alerts — 214).
        .nameEntryAlert(
            "Rename Collection",
            isPresented: renameBinding, text: $renameText, confirmLabel: "Rename",
            onConfirm: { name in
                if let id = renameTargetID { model.renameFolder(id: id, to: name) }
                renameTargetID = nil
            },
            onCancel: { renameTargetID = nil })
        // Rename a space (its outline-row menu — 043 · spaces), mirroring the
        // collection rename alert above.
        .nameEntryAlert(
            "Rename Space",
            isPresented: spaceRenameBinding, text: $spaceRenameText, confirmLabel: "Rename",
            onConfirm: { name in
                if let id = spaceRenameTargetID { model.renameSpace(id: id, to: name) }
                spaceRenameTargetID = nil
            },
            onCancel: { spaceRenameTargetID = nil })
        // Route a draft request (a "+" button or ⌘N) into the right inline row (214):
        // both collections and spaces now hand a fresh token to their AppKit outline
        // view. Consuming clears `nav.sidebarDraft` back to nil.
        .onChange(of: nav.sidebarDraft) { _, draft in
            guard let draft else { return }
            switch draft {
            case .collection(let parent):
                collectionsExpanded = true
                collectionDraftRequest = CollectionDraftRequest(parent: parent)
            case .space:
                spacesExpanded = true
                spaceDraftRequest = SpaceDraftRequest()
            }
            nav.sidebarDraft = nil
        }
    }

    // MARK: - Expanded (273pt)

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reserve the traffic-light band; the collapse toggle itself is drawn by the
            // shared overlay in `body` (hoisted so its x can't wiggle on toggle).
            Color.clear.frame(height: trafficLightInset)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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
        .frame(width: 250)
    }

    private var navSection: some View {
        // Search is no longer a row here — it lives as the panel's top search field.
        VStack(alignment: .leading, spacing: 6) {
            navRow(.home, "Home", "house")
            navRow(.capture, "Capture", "puzzlepiece.extension")
            #if DEBUG
            // The token specimen pane. A real row rather than a launch argument (the
            // `Debug/GridBakeoff*` precedent) because the point of the gallery is to
            // show tokens in the app's OWN panel — a separate `NSWindow` would render
            // them against chrome that isn't the one they have to match.
            navRow(.theme, "Theme", "paintpalette")
            #endif
            settingsRow
        }
    }

    private func navRow(_ item: SidebarItem, _ title: String, _ symbol: String) -> some View {
        rowButton(title, symbol, selected: nav.sidebarSelection == item) {
            nav.selectSidebar(item)
        }
    }

    /// Settings is not a sidebar DESTINATION — this opens the standard macOS
    /// Settings window (⌘,), the app's single settings surface. The row keeps its
    /// place because that is where people look for it; only the door changed, so
    /// it never draws a selected state (the panel behind it doesn't move).
    private var settingsRow: some View {
        rowButton("Settings", "gearshape", selected: false) { openSettings() }
            .help("Open Settings (⌘,)")
    }

    /// The nav rows' shared chrome — icon, title, and selection fill. Both the
    /// destination rows and the Settings row draw through this so a styling change
    /// can't reach one and miss the other.
    private func rowButton(
        _ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(title).font(Theme.Typography.row)
                Spacer()
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .background(rowHighlight(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover sits BEHIND the row's own selection fill (padding 0 → same rect), so it
        // only reads on non-selected rows; the opaque `selection` fill covers it when active.
        .hoverHighlight(cornerRadius: Theme.Radius.chip, fill: Theme.Colors.hoverRow, padding: 0)
    }

    // MARK: - Spaces

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Spaces", expanded: $spacesExpanded) { nav.sidebarDraft = .space }
            if spacesExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    // The AppKit NSOutlineView list (043 · spaces): live drag reorder
                    // + inline draft (214) + asset drops onto rows, sharing every
                    // primitive with the Collections tree. Non-scrolling — framed to
                    // its reported content height inside the sidebar's ScrollView.
                    // Row context menu (Rename / Delete) lives in the coordinator.
                    SpacesOutlineView(
                        model: model, nav: nav, height: $spaceOutlineHeight,
                        draftRequest: spaceDraftRequest,
                        onRename: { id in
                            spaceRenameText = model.spaces.first { $0.id == id }?.name ?? ""
                            spaceRenameTargetID = id
                        })
                        .frame(height: max(spaceOutlineHeight, 1))
                        .padding(.trailing, -8)
                    // Empty / loading state lives in SwiftUI — shown only when there
                    // are no spaces AND the outline reports no rows (so an open draft,
                    // which gives the outline a row's worth of height, hides it).
                    if model.spaces.isEmpty && spaceOutlineHeight < 1 {
                        if model.spacesLoaded { spacesEmptyRow } else { spacesLoadingRows }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Collections", expanded: $collectionsExpanded) {
                nav.sidebarDraft = .collection(parent: nil)
            }
            if collectionsExpanded {
                // The AppKit NSOutlineView tree (043 · Phase C): native disclosure
                // + live drag reorder/nest, plus asset drops onto rows. Non-scrolling
                // — framed to its reported content height so it sits inside the
                // sidebar's own ScrollView. Row context menu (New Subfolder / Rename
                // / Move to / Delete) lives in the coordinator; "New Subfolder" begins
                // an inline draft there (214), Rename still uses the alert below.
                CollectionsOutlineView(
                    model: model, nav: nav, height: $outlineHeight,
                    draftRequest: collectionDraftRequest,
                    onRename: { id in
                        renameText = model.folders.first { $0.id == id }?.name ?? ""
                        renameTargetID = id
                    })
                    .frame(height: max(outlineHeight, 1))
                    // Extend 8pt into the sidebar's right padding so the rows /
                    // selection reach closer to the edge.
                    .padding(.trailing, -8)
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } })
    }

    private var spaceRenameBinding: Binding<Bool> {
        Binding(get: { spaceRenameTargetID != nil }, set: { if !$0 { spaceRenameTargetID = nil } })
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
            .buttonStyle(HoverButtonStyle(cornerRadius: Theme.Radius.chip, padding: 6))
            Spacer()
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: Theme.Radius.chip, padding: 6))
        }
    }

    /// The nav rows' active-row fill (Home / Capture / Settings). Space and
    /// collection rows draw their own selection inside their AppKit outline views.
    private func rowHighlight(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .fill(selected ? Theme.Colors.selection : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
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
        .buttonStyle(HoverButtonStyle(padding: 5))
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
        // `.button` + `.plain`, NOT `.borderlessButton`: that style carries chrome of
        // its own, which measured 34pt wide against the trash button's 25.5 for the
        // same 14pt glyph and 5pt hover pad — so the sort glyph sat off the rail's
        // axis and its hover fill was wider than every sibling's. `.button` leaves
        // only the genuine glyph-width difference. (`CollectionsField` and the detail
        // page's overflow menu hit the identical trap.)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(padding: 5)
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
        .buttonStyle(HoverButtonStyle(padding: 5))
        .help("Delete the selected items")
    }

    // MARK: - Collapsed rail (60pt)

    private var rail: some View {
        // Every control shares ONE centered column so the toggle, sort, and trash
        // line up on the same vertical axis regardless of each glyph's intrinsic
        // width (the sort `Menu` in particular carries its own chrome). Each is
        // pinned to a fixed square so their centers coincide.
        VStack(spacing: 0) {
            // Reserve the traffic-light band; the collapse toggle itself is drawn by the
            // shared overlay in `body` (hoisted so its x can't wiggle on toggle).
            Color.clear.frame(height: trafficLightInset)

            Spacer()

            VStack(spacing: Theme.Spacing.lg) {
                railIcon { sortMenu }
                railIcon { trashButton }
            }
            .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(width: 60)
    }

    /// A rail control centered in a fixed square, so all rail glyphs share one
    /// vertical axis.
    private func railIcon<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 28, height: 28)
    }
}
