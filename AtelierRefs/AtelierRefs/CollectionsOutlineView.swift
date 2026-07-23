//
//  CollectionsOutlineView.swift
//  AtelierRefs
//
//  043 · Phase C2 — the sidebar Collections tree, rebuilt on AppKit
//  `NSOutlineView` for reliable LIVE drag: drop a folder ONTO a row to nest it, or
//  BETWEEN rows to reorder (persisted `sort_index`, 043 · 2B). It mirrors the
//  `MasonryGridHost` pattern (an `NSViewRepresentable` + a coordinator that owns
//  the data source / delegate / drag) and delegates every drop decision to the
//  pure, unit-tested `CollectionTargets.routeOutlineDrop(...)` (043 · 12A) — the
//  view here is thin glue.
//
//  Embedding: the outline view carries NO enclosing `NSScrollView` (it lives
//  inside the sidebar's SwiftUI `ScrollView`); its content height is reported back
//  through `height` so the SwiftUI wrapper can size it. Disclosure is native
//  (left triangle + indentation), matching Finder / Notes sidebars.
//

import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// A tree item. Reference type with `id`-based equality so `NSOutlineView`
/// preserves expansion across reloads even though nodes are rebuilt each time.
final class CollectionNode: NSObject {
    let id: UUID
    let name: String
    let isUnsorted: Bool
    let children: [CollectionNode]

    init(id: UUID, name: String, isUnsorted: Bool, children: [CollectionNode]) {
        self.id = id
        self.name = name
        self.isUnsorted = isUnsorted
        self.children = children
    }

    override func isEqual(_ object: Any?) -> Bool { (object as? CollectionNode)?.id == id }
    override var hash: Int { id.hashValue }

    /// Build the root→leaf node tree from the flat folder list, Unsorted pinned
    /// first among the roots, each sibling group in manual order.
    static func tree(from folders: [Collection], unsortedID: UUID) -> [CollectionNode] {
        let byParent = Dictionary(grouping: folders, by: { $0.parentCollectionID })
        func nodes(under parent: UUID?) -> [CollectionNode] {
            (byParent[parent] ?? [])
                .sorted(by: CollectionTargets.byManualOrder)
                .map { CollectionNode(
                    id: $0.id, name: $0.name, isUnsorted: $0.id == unsortedID,
                    children: nodes(under: $0.id)) }
        }
        var roots = nodes(under: nil)
        if let i = roots.firstIndex(where: { $0.isUnsorted }), i != 0 {
            roots.insert(roots.remove(at: i), at: 0)
        }
        return roots
    }
}

struct CollectionsOutlineView: NSViewRepresentable {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    /// The measured content height, pushed back so the SwiftUI wrapper can size
    /// this non-scrolling view inside the sidebar's own ScrollView.
    @Binding var height: CGFloat
    /// Row context-menu actions that need SwiftUI text-entry alerts (create /
    /// rename); move + delete are applied directly on the model by the coordinator.
    let onNewSubfolder: (UUID) -> Void
    let onRename: (UUID) -> Void

    func makeCoordinator() -> CollectionsOutlineCoordinator {
        CollectionsOutlineCoordinator(
            model: model, nav: nav,
            onNewSubfolder: onNewSubfolder, onRename: onRename
        ) { [$height] h in
            // Defer the SwiftUI state write out of the AppKit layout pass.
            DispatchQueue.main.async { if $height.wrappedValue != h { $height.wrappedValue = h } }
        }
    }

    func makeNSView(context: Context) -> NSOutlineView {
        context.coordinator.makeOutlineView()
    }

    func updateNSView(_ nsView: NSOutlineView, context: Context) {
        context.coordinator.update(
            folders: model.folders, unsortedID: model.unsortedFolderID,
            selection: nav.sidebarSelection)
    }
}

final class CollectionsOutlineCoordinator: NSObject, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSMenuDelegate {

    private let model: IngestionModel
    private let nav: NavModel
    private let onNewSubfolder: (UUID) -> Void
    private let onRename: (UUID) -> Void
    private let reportHeight: (CGFloat) -> Void

    private let outlineView = NSOutlineView()
    private static let rowHeight: CGFloat = 26
    private static let columnID = NSUserInterfaceItemIdentifier("name")

    /// The current node tree + the snapshot it was built from — rebuilt only when
    /// the folders actually change (043 · 13A memoization).
    private var roots: [CollectionNode] = []
    private var snapshot: [FolderSnapshot] = []
    /// `true` while WE are programmatically syncing selection, so the resulting
    /// delegate callback doesn't echo back into `nav`.
    private var isSyncingSelection = false
    /// The dragged folder's descendant set, computed ONCE at drag start so
    /// `validateDrop` (fired per mouse-move) never rebuilds it (043 · 14A).
    private var dragDescendants: Set<UUID> = []
    private var draggedID: UUID?

    /// A cheap value-type fingerprint of a folder for change detection.
    private struct FolderSnapshot: Equatable {
        let id: UUID; let name: String; let parent: UUID?; let sortIndex: Int
    }

    init(
        model: IngestionModel, nav: NavModel,
        onNewSubfolder: @escaping (UUID) -> Void, onRename: @escaping (UUID) -> Void,
        reportHeight: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.nav = nav
        self.onNewSubfolder = onNewSubfolder
        self.onRename = onRename
        self.reportHeight = reportHeight
        super.init()
    }

    // MARK: - View construction

    func makeOutlineView() -> NSOutlineView {
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = Self.rowHeight
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autosaveExpandedItems = false
        outlineView.registerForDraggedTypes(
            [CollectionDragPayload.pasteboardType, AssetDragPayload.pasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        // Content-sized: the sidebar's SwiftUI ScrollView scrolls, not this view;
        // the SwiftUI wrapper frames it to the reported content height.
        return outlineView
    }

    // MARK: - Row context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? CollectionNode else { return }
        let id = node.id
        menu.addItem(BlockMenuItem(title: "New Subfolder…") { [weak self] in self?.onNewSubfolder(id) })
        guard !node.isUnsorted else { return }   // Unsorted: create-only
        menu.addItem(BlockMenuItem(title: "Rename…") { [weak self] in self?.onRename(id) })
        menu.addItem(moveToItem(for: id))
        menu.addItem(.separator())
        let delete = BlockMenuItem(title: "Delete") { [weak self] in self?.model.deleteFolder(id: id) }
        menu.addItem(delete)
    }

    private func moveToItem(for id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if model.folders.first(where: { $0.id == id })?.parentCollectionID != nil {
            submenu.addItem(BlockMenuItem(title: "Top Level") { [weak self] in
                self?.model.moveFolder(id: id, toParent: nil)
            })
            submenu.addItem(.separator())
        }
        let targets = CollectionTargets.folderMoveTargets(
            for: id, folders: model.folders, unsortedID: model.unsortedFolderID)
        if targets.isEmpty {
            let none = NSMenuItem(title: "No available folders", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for target in targets {
                submenu.addItem(BlockMenuItem(title: target.name) { [weak self] in
                    self?.model.moveFolder(id: id, toParent: target.id)
                })
            }
        }
        item.submenu = submenu
        return item
    }

    // MARK: - Update (memoized)

    func update(folders: [Collection], unsortedID: UUID, selection: SidebarItem) {
        let next = folders
            .map { FolderSnapshot(id: $0.id, name: $0.name, parent: $0.parentCollectionID, sortIndex: $0.sortIndex) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        if next != snapshot {
            snapshot = next
            roots = CollectionNode.tree(from: folders, unsortedID: unsortedID)
            outlineView.reloadData()
            // Newly-created folders' parents should reveal them; expand every node
            // that has children on first build is too aggressive, so leave prior
            // expansion (preserved by id-equality) and only ensure roots are shown.
        }
        syncSelection(to: selection)
        reportMeasuredHeight()
    }

    private func syncSelection(to selection: SidebarItem) {
        guard case let .collection(id) = selection else {
            if outlineView.selectedRow != -1 {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }
        guard let node = findNode(id, in: roots) else { return }
        // Reveal ancestors so the row exists, then select it.
        expandAncestors(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
    }

    private func reportMeasuredHeight() {
        // Uniform row height → exact content height without per-row measurement.
        reportHeight(CGFloat(outlineView.numberOfRows) * Self.rowHeight)
    }

    // MARK: - Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any?) -> Bool {
        !((item as? CollectionNode)?.children.isEmpty ?? true)
    }

    private func children(of item: Any?) -> [CollectionNode] {
        (item as? CollectionNode)?.children ?? roots
    }

    // MARK: - Delegate (cells + selection)

    func outlineView(_ ov: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CollectionNode else { return nil }
        let id = Self.columnID
        let cell = ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: id)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSImage(
            systemSymbolName: node.isUnsorted ? "tray" : "folder", accessibilityDescription: nil)
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 13)
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? CollectionNode
        else { return }
        nav.selectSidebar(.collection(node.id))
    }

    func outlineViewItemDidExpand(_ notification: Notification) { reportMeasuredHeight() }
    func outlineViewItemDidCollapse(_ notification: Notification) { reportMeasuredHeight() }

    // MARK: - Drag source

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? CollectionNode, !node.isUnsorted else { return nil }
        return CollectionDragPayload(collectionID: node.id).makePasteboardItem()
    }

    func outlineView(
        _ ov: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        // 043 · 14A — snapshot the dragged folder's descendants ONCE for the whole
        // session so per-move validation is a set lookup, not a tree walk.
        guard let node = draggedItems.first as? CollectionNode else { return }
        draggedID = node.id
        dragDescendants = CollectionTargets.descendantIDs(of: node.id, in: model.folders)
    }

    func outlineView(
        _ ov: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedID = nil
        dragDescendants = []
    }

    // MARK: - Drop

    func outlineView(
        _ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pb = info.draggingPasteboard
        // Folder reparent / reorder (our own drag).
        if pb.data(forType: CollectionDragPayload.pasteboardType) != nil {
            return route(item: item, index: index) == nil ? [] : .move
        }
        // Asset move/copy (a grid drag onto a collection — 009 · N3): only valid
        // dropped ONTO a collection row, so retarget the whole row.
        if pb.data(forType: AssetDragPayload.pasteboardType) != nil {
            guard let node = item as? CollectionNode else { return [] }
            ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return optionDown ? .copy : .move
        }
        return []
    }

    func outlineView(
        _ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard
        if pb.data(forType: CollectionDragPayload.pasteboardType) != nil {
            guard let (dragged, drop) = route(item: item, index: index) else { return false }
            model.applyCollectionDrop(drop, dragged: dragged)
            return true
        }
        if let data = pb.data(forType: AssetDragPayload.pasteboardType),
           let payload = AssetDragPayload.decode(from: data),
           let node = item as? CollectionNode {
            return applyAssetDrop(payload, onto: node.id)
        }
        return false
    }

    /// The ⌥-at-drop-time read (009 · N3): a plain drop MOVES assets into a
    /// collection, ⌥ COPIES.
    private var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }

    /// Route an asset drag dropped onto a collection row — the same `routeDrop`
    /// decision the SwiftUI sidebar rows used, so move/copy parity is structural.
    private func applyAssetDrop(_ payload: AssetDragPayload, onto collectionID: UUID) -> Bool {
        switch routeDrop(payload, onto: .collection(collectionID), optionDown: optionDown) {
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

    /// Resolve the current drop target into `(dragged, move)` via the pure router,
    /// or `nil` if it isn't a legal move. Reads the dragged id from the fast-path
    /// session cache when available, else off the pasteboard.
    private func route(item: Any?, index: Int) -> (UUID, CollectionDrop)? {
        guard let dragged = draggedID ?? pasteboardDraggedID() else { return nil }
        let parent = (item as? CollectionNode)?.id
        // `NSOutlineViewDropOnItemIndex` (-1) == dropped ON the row → nest.
        let childIndex: Int? = index == NSOutlineViewDropOnItemIndex ? nil : index
        let drop = CollectionTargets.routeOutlineDrop(
            dragged: dragged, into: parent, childIndex: childIndex,
            folders: model.folders, unsortedID: model.unsortedFolderID)
        guard case .move = drop else { return nil }
        return (dragged, drop)
    }

    private func pasteboardDraggedID() -> UUID? {
        guard let data = NSPasteboard(name: .drag).data(forType: CollectionDragPayload.pasteboardType)
        else { return nil }
        return CollectionDragPayload.decode(from: data)?.collectionID
    }

    // MARK: - Node lookup

    private func findNode(_ id: UUID, in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.id == id { return node }
            if let hit = findNode(id, in: node.children) { return hit }
        }
        return nil
    }

    private func expandAncestors(of node: CollectionNode) {
        // Walk the model to find the ancestor chain, expanding each so the row
        // materializes before selection.
        var chain: [UUID] = []
        var cursor = model.folders.first { $0.id == node.id }?.parentCollectionID
        var guardSet: Set<UUID> = []
        while let id = cursor, guardSet.insert(id).inserted {
            chain.append(id)
            cursor = model.folders.first { $0.id == id }?.parentCollectionID
        }
        for id in chain.reversed() {
            if let ancestor = findNode(id, in: roots) { outlineView.expandItem(ancestor) }
        }
    }
}

/// A closure-backed `NSMenuItem` (the outline row menu builds items dynamically;
/// target/action selectors would need one method per action). Mirrors the private
/// helper `MasonryGridHost` uses for the same reason.
private final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
