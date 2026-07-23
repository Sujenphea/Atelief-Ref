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
            // Written synchronously from expand/collapse (a click event) so the
            // frame grows in the SAME pass the rows appear — no one-frame glitch.
            // The `update()` path defers this itself (it runs during a SwiftUI pass).
            if $height.wrappedValue != h { $height.wrappedValue = h }
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

    private let outlineView = SidebarOutlineView()
    private static let rowHeight: CGFloat = 32
    private static let columnID = NSUserInterfaceItemIdentifier("name")

    /// The current node tree + the snapshot it was built from — rebuilt only when
    /// the folders actually change (043 · 13A memoization).
    private var roots: [CollectionNode] = []
    private var snapshot: [FolderSnapshot] = []
    /// `true` while WE are programmatically syncing selection, so the resulting
    /// delegate callback doesn't echo back into `nav`.
    private var isSyncingSelection = false
    /// The last selection we reconciled — so we only force-reveal ancestors when
    /// the selection actually CHANGES, not on every reload. Without this, a user
    /// collapsing a folder whose descendant is selected would be re-expanded on the
    /// next update (the "fold when child is active doesn't work" bug).
    private var lastSyncedSelection: SidebarItem?
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
        // Zero intercell spacing so the reported content height (`rows * rowHeight`)
        // is EXACT — the default vertical spacing made the view under-report and
        // shift rows on expand.
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        // Native triangle hidden (SidebarOutlineView); the chevron is drawn on the
        // RIGHT in the cell. Children still indent by level for depth.
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        // A click anywhere on a parent row toggles its children (the whole row is
        // the show/hide target, not just the chevron). Selection/nav is handled
        // separately by `outlineViewSelectionDidChange`.
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
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
        // This runs inside a SwiftUI update pass, so defer the height write to avoid
        // "modifying state during view update" (the expand/collapse path writes it
        // synchronously instead).
        DispatchQueue.main.async { [weak self] in self?.reportMeasuredHeight() }
    }

    private func syncSelection(to selection: SidebarItem) {
        defer { lastSyncedSelection = selection }
        let changed = selection != lastSyncedSelection
        guard case let .collection(id) = selection else {
            if outlineView.selectedRow != -1 {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }
        guard let node = findNode(id, in: roots) else { return }
        // Only force-reveal a collapsed ancestor chain when the selection actually
        // CHANGED — otherwise a user collapsing this node's parent would be undone
        // on the next reload. An unchanged selection that's now hidden stays hidden.
        if changed { expandAncestors(of: node) }
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
        let cell = ov.makeView(withIdentifier: Self.columnID, owner: self) as? SidebarCell
            ?? SidebarCell(identifier: Self.columnID)
        cell.configure(
            name: node.name, expandable: !node.children.isEmpty,
            expanded: ov.isItemExpanded(node))
        return cell
    }

    /// Borderless, Theme-tinted selection (no focus ring / emphasized blue).
    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        return ov.makeView(withIdentifier: id, owner: self) as? SidebarRowView
            ?? { let v = SidebarRowView(); v.identifier = id; return v }()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? CollectionNode
        else { return }
        nav.selectSidebar(.collection(node.id))
    }

    func outlineViewItemDidExpand(_ notification: Notification) { reportMeasuredHeight() }
    func outlineViewItemDidCollapse(_ notification: Notification) { reportMeasuredHeight() }

    /// A click anywhere on a parent row toggles its children (leaves just select).
    /// The chevron glyph is refreshed directly so it never lags. Fires from a click
    /// event, so the synchronous height report is safe.
    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? CollectionNode,
              !node.children.isEmpty else { return }
        let willExpand = !outlineView.isItemExpanded(node)
        if willExpand { outlineView.expandItem(node) } else { outlineView.collapseItem(node) }
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?
            .setExpanded(willExpand)
        reportMeasuredHeight()
    }

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

/// The outline view with the native LEFT disclosure triangle suppressed — the cell
/// draws its own chevron on the right (043 · Phase C styling).
final class SidebarOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// NSOutlineView reserves a fixed leading gap for the (now-hidden) disclosure
    /// triangle. Strip that constant gap so the cell's own 14pt inset is the only
    /// leading padding, keeping ONLY the per-level indentation on top.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let indent = CGFloat(level(forRow: row)) * indentationPerLevel
        let gap = frame.origin.x - indent
        frame.origin.x -= gap
        frame.size.width += gap
        return frame
    }

    /// Without an enclosing scroll view the single column doesn't auto-fill; track
    /// the view width so rows (and their selection / click target) span the sidebar.
    override func layout() {
        super.layout()
        if let column = tableColumns.first, column.width != bounds.width {
            column.width = bounds.width
        }
    }
}

/// A row whose selection is a flat, borderless Theme fill (no focus ring, no
/// emphasized blue) — matches the SwiftUI sidebar's active-row look.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Left-flush (roots have 0 x offset, so the fill must start at 0 too, else
        // the name overhangs it); small right + vertical inset for the rounded look.
        let rect = NSRect(x: 0, y: 2, width: bounds.width - 4, height: bounds.height - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(hex: 0x3A3A40).setFill()                        // Theme.Colors.selection
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()      // Theme.Colors.hairlineStrong
        path.lineWidth = 1
        path.stroke()
    }
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A collection row cell: name text in the Theme row font, NO leading icon, and a
/// right-aligned chevron that expands/collapses (shown only for parents).
final class SidebarCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()   // indicator only — the row handles toggle

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 13)              // Theme.Typography.row, snug
        label.textColor = NSColor(hex: 0xF2F1EE)          // inkPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = NSColor(hex: 0x9A9A9E) // inkSecondary
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(chevron)
        textField = label
        NSLayoutConstraint.activate([
            // Roots sit at 14pt; children add the outline view's per-level indent.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, expandable: Bool, expanded: Bool) {
        label.stringValue = name
        chevron.isHidden = !expandable
        setExpanded(expanded)
    }

    /// Flip the chevron glyph to match the expansion state — called immediately on
    /// toggle so it never lags.
    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
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
