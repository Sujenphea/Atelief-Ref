//
//  PaletteView.swift
//  AtelierRefs
//
//  099 · P6 — the floating reference palette's window content (011 · Cluster D).
//
//  A compact always-on-top grid of ONE collection or saved search, to refer to
//  while you design in another app, plus a picker to swap what it shows. Its whole
//  interaction budget is: look, scroll, drag out, and change the subject.
//
//  **The grid is `MasonryGridHost`, in the read-only configuration P6 added to it**
//  (``GridInteraction/readOnly``). Not a second grid: this one already carries the
//  masonry solve, the layout cache, the thumbnail pipeline with its per-cell pixel
//  bucket, the prefetcher, the drag image and — the part the palette exists for —
//  the file-promise drag-out that puts an original file into Figma. A miniature
//  bespoke grid would be a fifth surface to keep in step with those, and would have
//  to re-earn drag-out from scratch.
//
//  **Density is the palette's own, not the global notch.** `GridViewPreferences` is
//  deliberately global — one muscle memory across every collection (011-B2) — but
//  it is a COLUMN COUNT, and a count chosen for a 1400pt window renders 30pt cells
//  in a 360pt one. So the palette pins two columns and does not offer ⌘±, which is
//  also the honest reading of "no keyboard verbs".
//
//  **Carousels are not grouped here either**, and that one is a correctness point
//  rather than a taste one: a collapsed post hides its other members behind a chip,
//  the chip is an interaction, and a read-only grid has no interactions — so
//  grouping would make some assets undraggable. Every image is its own tile.
//

import AppKit
import AtelierCore
import Combine
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var palette: PaletteModel
    @ObservedObject private var smart: SavedSearchesSidebarModel

    /// The palette's own feed — the app's THIRD ``CollectionReadModel`` (the main
    /// window's, the smart-collection pane's, this). It is pointed at a collection
    /// feed or a saved-search feed as the destination changes; nothing about it is
    /// palette-specific.
    @StateObject private var contents: CollectionReadModel
    /// Its selection store. The palette never selects anything — but the read model
    /// prunes whatever store it is handed on every load, and handing it the main
    /// window's would let the palette's reloads clear the grid's selection behind
    /// the user's back. So it gets a private one that stays empty.
    @StateObject private var selectionStore: GridSelectionStore

    @Environment(\.displayScale) private var displayScale

    /// The live grid width — carried only so the thumbnail bucket and the layout
    /// have a real number on first paint.
    @State private var gridWidth: CGFloat = 1

    init(model: IngestionModel, palette: PaletteModel) {
        _model = ObservedObject(wrappedValue: model)
        _palette = ObservedObject(wrappedValue: palette)
        _smart = ObservedObject(wrappedValue: model.smartCollections)
        let store = GridSelectionStore()
        _selectionStore = StateObject(wrappedValue: store)
        _contents = StateObject(wrappedValue: CollectionReadModel(selectionStore: store))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Colors.hairline)
            content
        }
        .frame(minWidth: PaletteLayout.minimumWidth, minHeight: PaletteLayout.minimumHeight)
        .background(Theme.Colors.panel)
        .task { adopt(palette.destination) }
        .onChange(of: palette.destination) { _, next in adopt(next) }
        // Bind the per-library memory here as well as in the shell (099 · P6).
        // `activate` re-reads a stored token and is idempotent, and the palette can
        // be raised by ⇧⌘P while the shell is closed — which is exactly when this
        // window would otherwise open with no memory at all. The shell's copy is
        // still needed for the other direction: "Open in Palette" has to be able to
        // PERSIST a destination before this window has ever been built.
        .onReceive(model.$openLibraryID.compactMap { $0 }) { libraryID in
            palette.activate(libraryID: libraryID)
        }
        // A destination that has been deleted elsewhere stops being the palette's
        // subject rather than becoming a permanent error card.
        .onChange(of: model.folders) { _, folders in
            palette.reconcile(folders: folders, savedSearches: smart.searches)
            // The library may have opened AFTER this window did — a palette raised
            // during bootstrap has no `services` to build a feed from, and nothing
            // else would ever ask again. `folders` publishing is the signal that it
            // is open; the `nil` guard keeps this from re-loading on every write.
            if contents.loadedCollectionID == nil { adopt(palette.destination) }
        }
        .onChange(of: smart.searches) { _, searches in
            palette.reconcile(folders: model.folders, savedSearches: searches)
        }
    }

    // MARK: - Chrome

    /// The one control the palette has: what it is showing, and a press to change
    /// it. The title IS the button — a separate chevron would be a second target
    /// for one verb in a window this narrow.
    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                palette.isPickingDestination.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                    Text(title)
                        .font(Theme.Typography.row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                }
                .foregroundStyle(Theme.Colors.inkPrimary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.paletteDestinationButton)
            .help("Choose the collection or smart collection this palette shows")
            .popover(isPresented: $palette.isPickingDestination, arrowEdge: .bottom) {
                PaletteDestinationPicker(
                    model: palette.picker,
                    candidates: {
                        PaletteDestinations.candidates(
                            folders: model.folders,
                            unsortedID: model.unsortedFolderID,
                            spaces: model.spaces,
                            savedSearches: smart.searches)
                    },
                    onSelect: { palette.choose($0) },
                    onDismiss: { palette.isPickingDestination = false })
            }

            Spacer(minLength: Theme.Spacing.xs)

            if palette.destination != nil {
                Text(countLabel)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .redacted(reason: hasLoaded ? [] : .placeholder)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if palette.destination == nil {
            empty(
                "Nothing chosen",
                "Pick a collection or a smart collection to keep beside your work.")
        } else if !hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = contents.lastError {
            empty("Can't show this", error)
        } else if contents.items.isEmpty {
            empty("Empty", "There is nothing in here to refer to yet.")
        } else {
            grid
        }
    }

    private var grid: some View {
        MasonryGridHost(configuration: gridConfiguration)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(gridWidth - width) > 0.5 { gridWidth = width }
            }
    }

    private func empty(_ title: String, _ message: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkPrimary)
            Text(message)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.paletteEmptyState)
    }

    // MARK: - What it is showing

    /// Whether the read model's rows are THIS destination's yet — the same identity
    /// check every other pane makes, so a swap shows a spinner rather than the
    /// previous collection's tiles.
    private var hasLoaded: Bool {
        guard let id = PaletteDestinations.feedID(of: palette.destination ?? .home) else {
            return false
        }
        return contents.loadedCollectionID == id
    }

    private var title: String {
        switch palette.destination {
        case .collection(let id):
            model.folders.first { $0.id == id }?.name ?? "Collection"
        case .savedSearch(let id):
            smart.search(id: id)?.name ?? "Smart Collection"
        default:
            "Choose…"
        }
    }

    private var symbol: String {
        switch palette.destination {
        case .collection(let id):
            id == model.unsortedFolderID ? "tray" : "folder"
        case .savedSearch:
            "line.3.horizontal.decrease.circle"
        default:
            "square.grid.2x2"
        }
    }

    private var countLabel: String {
        let n = contents.items.count
        return n == 1 ? "1 item" : "\(n) items"
    }

    /// Point the read model at `destination` and load it.
    ///
    /// The feed is REBUILT rather than parameterised, `SmartCollectionView`'s rule:
    /// which read runs is a fact about the destination, and a feed that resolved it
    /// per call would have to be told about a swap anyway.
    private func adopt(_ destination: SidebarItem?) {
        guard let services = model.services else { return }
        guard let destination, let id = PaletteDestinations.feedID(of: destination) else {
            return
        }
        switch destination {
        case .savedSearch:
            contents.feed = .savedSearch(services)
        default:
            contents.feed = .collection(services, sort: { model.sortMode(for: $0) })
        }
        // 099 · P6: every image its own tile — see the file header.
        if contents.groupCarousels { contents.groupCarousels = false }
        // The palette follows the library's change stream like every other feed, so
        // a capture, a delete or a move made in the main window shows up here without
        // the palette knowing what happened. `follow` replaces its subscription, so
        // re-adopting on a swap does not stack them.
        contents.follow(model.libraryChanged)
        contents.load(id)
    }

    // MARK: - The host configuration

    private var gridConfiguration: GridHostConfiguration {
        GridHostConfiguration(
            items: contents.displayItems,
            itemsVersion: contents.itemsVersion,
            postGroups: contents.postGroups,
            density: PaletteLayout.density,
            spacing: Theme.Spacing.xs,
            topInset: Theme.Spacing.xs,
            collectionID: contents.loadedCollectionID ?? AssetDragPayload.nilSourceID,
            displayScale: displayScale,
            thumbnailURL: { model.thumbnailURL(for: $0) },
            blobURL: { model.blobURL(for: $0) },
            selectionStore: selectionStore,
            // Every verb below is unreachable: `.readOnly` gates the three routes
            // that could reach one (the click, the menu, the keyboard). They are
            // written as no-ops rather than left out because the type requires them
            // — and a no-op that CAN be called is what the flags exist to prevent.
            onOpenDetail: { _ in },
            onRequestRemove: {},
            onRequestDelete: {},
            onCopy: {},
            onQuickLook: {},
            onZoomIn: {},
            onZoomOut: {},
            // The one thing the palette CAN do. The source comes from the palette's
            // own read model, so a drag out of it is stamped with what the PALETTE
            // is showing — not with the main window's collection.
            dragPayload: { contents.dragPayload(forCellItemID: $0) },
            dragImage: { _ in nil },
            // Not a reorder target and not a drop target: `canReorder: false` is
            // what `gridDraggingOperation` reads to refuse a hovering drag outright.
            canReorder: false,
            onReorderCommit: { _, _ in false },
            actionTargets: { contents.actionTargets(forCellItemID: $0) },
            destinationTree: [],
            destinationUnsortedID: model.unsortedFolderID,
            onMoveToCollection: { _, _ in },
            onCopyToCollection: { _, _ in },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { _ in },
            interaction: .readOnly)
    }
}

// MARK: - The picker

/// The palette's destination picker: **P5's ranking and P5's row**, in a popover.
///
/// It is not the ⌘K panel and must not be: ⌘K moves YOU and has to open over every
/// surface from a key, which is why it is a child `NSPanel` with its own responder
/// discipline. This one changes what ONE window is showing and is raised by a button
/// that is right there, which is exactly the case a popover is for (and the case
/// `SwitcherPanel`'s header rules out for ⌘K — "a popover needs an anchor view, and
/// ⌘K has none"). What the two share is everything that decides an ANSWER:
/// ``SwitcherRanking``, ``SwitcherModel`` and ``SwitcherRow``.
struct PaletteDestinationPicker: View {
    @ObservedObject var model: SwitcherModel
    let candidates: () -> [SwitcherCandidate]
    let onSelect: (SidebarItem) -> Void
    let onDismiss: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if model.results.isEmpty {
                Text("No collection matches “\(model.query)”")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.md)
            } else {
                Divider().overlay(Theme.Colors.hairline)
                list
            }
        }
        .frame(width: PaletteLayout.pickerWidth)
        .onAppear {
            // No recents: the palette's memory is the ONE destination it last showed
            // (`PaletteModel.activate`), not a list of them. Passing ⌘K's MRU would
            // rank the palette's picker by where the user has NAVIGATED, which is a
            // different question from what they keep beside their work.
            model.open(candidates: candidates(), recents: [])
            Task { @MainActor in fieldFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.inkSecondary)
            TextField("Show…", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .focused($fieldFocused)
                .accessibilityIdentifier(AccessibilityID.paletteField)
                .onSubmit(commit)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.results) { match in
                        SwitcherRow(
                            candidate: match.candidate,
                            isHighlighted: match.destination == model.highlighted,
                            onHover: { model.highlight(match.destination) },
                            action: { onSelect(match.destination) },
                            identifier: AccessibilityID.paletteRow(match.candidate.title))
                            .id(match.destination)
                    }
                }
                .padding(Theme.Spacing.xs)
            }
            .frame(height: PaletteLayout.pickerListHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.highlighted) { _, destination in
                guard let destination else { return }
                proxy.scrollTo(destination, anchor: .center)
            }
        }
    }

    /// `.handled` even at a stop — ``SwitcherPanel``'s rule, and for its reason: an
    /// ↑ that reached the field editor would jump the caret instead of the cursor.
    private func move(_ delta: Int) -> KeyPress.Result {
        model.move(delta)
        return .handled
    }

    private func commit() {
        guard let target = model.commitTarget else { return }
        onSelect(target)
    }
}

// MARK: - Geometry

/// The palette's fixed numbers. A `*Layout` enum rather than literals at the call
/// site, per ``Theme``'s header and ``SwitcherLayout``'s precedent.
nonisolated enum PaletteLayout {
    /// The window's default size — a tall, narrow strip, because that is the shape
    /// that fits down the side of a screen whose middle belongs to another app.
    static let defaultWidth: CGFloat = 360
    static let defaultHeight: CGFloat = 620
    /// Small enough to be a strip, large enough that two columns still read.
    static let minimumWidth: CGFloat = 240
    static let minimumHeight: CGFloat = 240
    /// Two columns, fixed. See the file header for why this is not the global notch.
    static let density = GridDensity(columns: 2)
    /// The picker popover's width and list height. Narrower and shorter than ⌘K's:
    /// it hangs off a button in a 360pt window rather than floating over a shell.
    static let pickerWidth: CGFloat = 320
    static let pickerListHeight: CGFloat = 240
}
