//
//  SpacesOutlineView.swift
//  AtelierRefs
//
//  043 (spaces) — the sidebar Spaces list, rebuilt on AppKit `NSOutlineView` to
//  match the Collections tree: LIVE drag to reorder (persisted `sort_index`),
//  inline draft creation (214), and asset drops ONTO a row (add-to-space). It is
//  the FLAT sibling of ``CollectionsOutlineView`` — spaces don't nest, so there is
//  no disclosure, no descendants, and no cycle logic; a drop is only ever a
//  same-list reorder, routed by the pure ``SpaceTargets/routeOutlineDrop``.
//
//  It shares every AppKit primitive with the collections tree
//  (`SidebarOutlineView` / `SidebarRowView` / `SidebarCell` / `SidebarDraftCell`,
//  see `SidebarOutlineKit.swift`) and the same embedding contract: NO enclosing
//  `NSScrollView` — the content height is reported through `height` so the SwiftUI
//  wrapper can size it inside the sidebar's own `ScrollView`.
//

import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// A flat space row. Reference type with `id`-based equality so `NSOutlineView`
/// preserves state across reloads even though nodes are rebuilt each time.
final class SpaceNode: NSObject {
    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    override func isEqual(_ object: Any?) -> Bool { (object as? SpaceNode)?.id == id }
    override var hash: Int { id.hashValue }

    /// The flat node list from the space inventory, in manual order.
    static func list(from spaces: [Space]) -> [SpaceNode] {
        SpaceTargets.ordered(spaces).map { SpaceNode(id: $0.id, name: $0.name) }
    }
}

/// A one-shot request to begin an inline space draft (214), the flat analog of
/// ``CollectionDraftRequest``. A fresh `token` each time so `updateNSView` re-entry
/// doesn't restart the draft.
struct SpaceDraftRequest: Equatable {
    let token: UUID
    init() { self.token = UUID() }
}

struct SpacesOutlineView: NSViewRepresentable {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    /// The measured content height, pushed back so the SwiftUI wrapper can size
    /// this non-scrolling view inside the sidebar's own ScrollView.
    @Binding var height: CGFloat
    /// A pending inline "new space" draft (214); the coordinator begins it when the
    /// token changes.
    let draftRequest: SpaceDraftRequest?
    /// Rename uses a SwiftUI text-entry alert (like collections); the coordinator
    /// applies move + surfaces delete directly on the model.
    let onRename: (UUID) -> Void

    func makeCoordinator() -> SpacesOutlineCoordinator {
        SpacesOutlineCoordinator(model: model, nav: nav, onRename: onRename) { [$height] h in
            if $height.wrappedValue != h { $height.wrappedValue = h }
        }
    }

    func makeNSView(context: Context) -> NSOutlineView {
        context.coordinator.makeOutlineView()
    }

    func updateNSView(_ nsView: NSOutlineView, context: Context) {
        context.coordinator.update(spaces: model.spaces, selection: nav.sidebarSelection)
        context.coordinator.handleDraftRequest(draftRequest)
    }
}

final class SpacesOutlineCoordinator: NSObject, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSMenuDelegate {

    private let model: IngestionModel
    private let nav: NavModel
    private let onRename: (UUID) -> Void
    private let reportHeight: (CGFloat) -> Void

    private let outlineView = SidebarOutlineView()
    private static let rowHeight: CGFloat = 32
    private static let columnID = NSUserInterfaceItemIdentifier("name")
    private static let draftColumnID = NSUserInterfaceItemIdentifier("draft")

    /// An in-flight inline-creation session (214), `nil` when idle. Mirrors the
    /// collection coordinator's `DraftState` minus the parent (spaces are flat).
    private struct DraftState {
        var text: String = ""
        var committedName: String?
    }
    private var draft: DraftState?
    /// The single sentinel row for the active draft, tracked by id-equality across
    /// reloads. Never lives in `nodes`; appended by `children(of:)` on demand.
    private let draftNode = SpaceNode(id: UUID(), name: "")
    private var lastDraftToken: UUID?
    private var draftCleanupWork: DispatchWorkItem?

    private func isDraftNode(_ item: Any?) -> Bool { (item as? SpaceNode) === draftNode }

    /// The current node list + the snapshot it was built from — rebuilt only when
    /// the spaces actually change (memoization, mirroring the collection tree).
    private var nodes: [SpaceNode] = []
    private var snapshot: [SpaceSnapshot] = []
    /// `true` while WE are programmatically syncing selection, so the resulting
    /// delegate callback doesn't echo back into `nav`.
    private var isSyncingSelection = false
    /// The dragged space id for the session (fast-path over the pasteboard).
    private var draggedID: UUID?

    /// A cheap value-type fingerprint of a space for change detection.
    private struct SpaceSnapshot: Equatable {
        let id: UUID; let name: String; let sortIndex: Int
    }

    init(
        model: IngestionModel, nav: NavModel,
        onRename: @escaping (UUID) -> Void,
        reportHeight: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.nav = nav
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
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0                 // flat — no nesting
        outlineView.autoresizesOutlineColumn = true
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.autosaveExpandedItems = false
        outlineView.registerForDraggedTypes(
            [SpaceDragPayload.pasteboardType, AssetDragPayload.pasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        return outlineView
    }

    // MARK: - Row context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SpaceNode,
              !isDraftNode(node) else { return }
        let id = node.id, name = node.name
        menu.addItem(SidebarBlockMenuItem(title: "Rename…") { [weak self] in self?.onRename(id) })
        menu.addItem(.separator())
        menu.addItem(SidebarBlockMenuItem(title: "Delete…") { [weak self] in
            self?.model.requestDeleteSpace(id: id, name: name)
        })
    }

    // MARK: - Update (memoized)

    func update(spaces: [Space], selection: SidebarItem) {
        let next = SpaceTargets.ordered(spaces)
            .map { SpaceSnapshot(id: $0.id, name: $0.name, sortIndex: $0.sortIndex) }
        if next != snapshot {
            snapshot = next
            // A committed draft's real space has now arrived — drop the placeholder
            // so the reload swaps it in place with no visual jump.
            if draft?.committedName != nil {
                draft = nil
                draftCleanupWork?.cancel()
                draftCleanupWork = nil
            }
            nodes = SpaceNode.list(from: spaces)
            if draft != nil {
                let text = draft!.text
                suspendDraftCell()
                outlineView.reloadData()
                focusDraftField(restoring: text)
            } else {
                outlineView.reloadData()
            }
        }
        syncSelection(to: selection)
        DispatchQueue.main.async { [weak self] in self?.reportMeasuredHeight() }
    }

    private func syncSelection(to selection: SidebarItem) {
        guard case let .space(id) = selection else {
            if outlineView.selectedRow != -1 {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }
        guard let node = nodes.first(where: { $0.id == id }) else {
            if outlineView.selectedRow != -1 {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
    }

    private func reportMeasuredHeight() {
        reportHeight(CGFloat(outlineView.numberOfRows) * Self.rowHeight)
    }

    // MARK: - Inline draft (214)

    func handleDraftRequest(_ request: SpaceDraftRequest?) {
        guard let request, request.token != lastDraftToken else { return }
        lastDraftToken = request.token
        DispatchQueue.main.async { [weak self] in self?.beginDraft() }
    }

    /// Open the inline draft row at the end of the list.
    func beginDraft() {
        if draft != nil { endDraft(commit: nil) }         // one session at a time
        draft = DraftState()
        outlineView.reloadData()                          // draft row materializes
        reportMeasuredHeight()
        focusDraftField(restoring: "")
    }

    /// Finish the active draft. `name != nil` commits (create + keep a static row
    /// until the refresh lands); `nil` cancels (remove the row immediately).
    private func endDraft(commit name: String?) {
        guard draft != nil else { return }
        if let name {
            draft?.committedName = name
            // Create + open, exactly as the SwiftUI draft did (createSpace is async;
            // its `refreshSpaces` drives the snapshot change that swaps the row in).
            Task { [weak self] in
                if let id = await self?.model.createSpace(name: name) { self?.nav.openSpace(id) }
            }
            outlineView.reloadData()                      // draft cell → static label
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.draft?.committedName != nil else { return }
                self.draft = nil
                self.outlineView.reloadData()
                self.reportMeasuredHeight()
            }
            draftCleanupWork?.cancel()
            draftCleanupWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        } else {
            draft = nil
            outlineView.reloadData()
            reportMeasuredHeight()
        }
        outlineView.window?.makeFirstResponder(outlineView)
    }

    private func suspendDraftCell() {
        let row = outlineView.row(forItem: draftNode)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarDraftCell else { return }
        cell.isSuspended = true
    }

    private func focusDraftField(restoring text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.draft != nil, self.draft?.committedName == nil else { return }
            let row = self.outlineView.row(forItem: self.draftNode)
            guard row >= 0,
                  let cell = self.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? SidebarDraftCell else { return }
            cell.field.stringValue = text
            self.outlineView.window?.makeFirstResponder(cell.field)
            if let editor = cell.field.currentEditor() as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
                editor.focusRingType = .none
            }
            cell.field.currentEditor()?.selectedRange = NSRange(location: text.count, length: 0)
        }
    }

    // MARK: - Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any?) -> Bool {
        false                                             // flat — no row nests
    }

    /// The flat node list, plus the sentinel draft row appended last when a draft
    /// is open. Only the root (`item == nil`) has children — spaces never nest.
    private func children(of item: Any?) -> [SpaceNode] {
        guard item == nil else { return [] }
        return draft != nil ? nodes + [draftNode] : nodes
    }

    // MARK: - Delegate (cells + selection)

    func outlineView(_ ov: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SpaceNode else { return nil }
        if isDraftNode(node) {
            if let committed = draft?.committedName {
                let cell = ov.makeView(withIdentifier: Self.columnID, owner: self) as? SidebarCell
                    ?? SidebarCell(identifier: Self.columnID)
                cell.configure(name: committed, expandable: false, expanded: false)
                return cell
            }
            let cell = ov.makeView(withIdentifier: Self.draftColumnID, owner: self) as? SidebarDraftCell
                ?? SidebarDraftCell(identifier: Self.draftColumnID)
            cell.prepareForEditing()
            cell.placeholder = "New Space"
            cell.field.stringValue = draft?.text ?? ""
            cell.onTextChange = { [weak self] in self?.draft?.text = $0 }
            cell.onCommit = { [weak self] name in
                DispatchQueue.main.async { self?.endDraft(commit: name) }
            }
            cell.onCancel = { [weak self] in
                DispatchQueue.main.async { self?.endDraft(commit: nil) }
            }
            return cell
        }
        let cell = ov.makeView(withIdentifier: Self.columnID, owner: self) as? SidebarCell
            ?? SidebarCell(identifier: Self.columnID)
        cell.configure(name: node.name, expandable: false, expanded: false)
        return cell
    }

    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = ov.makeView(withIdentifier: id, owner: self) as? SidebarRowView
            ?? { let v = SidebarRowView(); v.identifier = id; return v }()
        view.forceSelected = isDraftNode(item)
        return view
    }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !isDraftNode(item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? SpaceNode,
              !isDraftNode(node)
        else { return }
        nav.openSpace(node.id)
    }

    /// A click selects (flat list — nothing to expand). Kept so the whole row is
    /// the hit target and selection routes through the delegate.
    @objc private func rowClicked() {}

    // MARK: - Drag source

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard draft == nil, let node = item as? SpaceNode, !isDraftNode(node) else { return nil }
        return SpaceDragPayload(spaceID: node.id).makePasteboardItem()
    }

    func outlineView(
        _ ov: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        draggedID = (draggedItems.first as? SpaceNode)?.id
    }

    func outlineView(
        _ ov: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedID = nil
    }

    // MARK: - Drop

    func outlineView(
        _ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard draft == nil else { return [] }
        let pb = info.draggingPasteboard
        // Space reorder (our own drag): normalize to a root-level between-rows slot
        // so the drop line is drawn where the space will land.
        if pb.data(forType: SpaceDragPayload.pasteboardType) != nil {
            let childIndex = normalizedRootIndex(item: item, index: index)
            ov.setDropItem(nil, dropChildIndex: childIndex)
            return route(childIndex: childIndex) == nil ? [] : .move
        }
        // Asset add (a grid drag onto a space row): only valid dropped ONTO a row,
        // so retarget the whole row. A space is additive — always `.copy`.
        if pb.data(forType: AssetDragPayload.pasteboardType) != nil {
            guard let node = item as? SpaceNode, !isDraftNode(node) else { return [] }
            ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(
        _ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard
        if pb.data(forType: SpaceDragPayload.pasteboardType) != nil {
            guard let (dragged, drop) = route(childIndex: index) else { return false }
            model.applySpaceDrop(drop, dragged: dragged)
            return true
        }
        if let data = pb.data(forType: AssetDragPayload.pasteboardType),
           let payload = AssetDragPayload.decode(from: data),
           let node = item as? SpaceNode, !isDraftNode(node) {
            guard !payload.assetIDs.isEmpty else { return false }
            model.addAssetsToSpace(assetIDs: payload.assetIDs, to: node.id)
            return true
        }
        return false
    }

    /// Convert an outline-view drop proposal into a root-level child index: an
    /// on-row drop lands AFTER that row; an empty-area drop (`-1`) appends.
    private func normalizedRootIndex(item: Any?, index: Int) -> Int {
        let ids = nodes.map(\.id)
        if let node = item as? SpaceNode, !isDraftNode(node) {
            let pos = ids.firstIndex(of: node.id) ?? ids.count
            return pos + 1
        }
        return index == NSOutlineViewDropOnItemIndex ? ids.count : index
    }

    /// Resolve the current drop into `(dragged, move)` via the pure router, or `nil`
    /// if it isn't a legal reorder.
    private func route(childIndex: Int) -> (UUID, SpaceDrop)? {
        guard let dragged = draggedID ?? pasteboardDraggedID() else { return nil }
        let drop = SpaceTargets.routeOutlineDrop(
            dragged: dragged, childIndex: childIndex, spaces: model.spaces)
        guard case .move = drop else { return nil }
        return (dragged, drop)
    }

    private func pasteboardDraggedID() -> UUID? {
        guard let data = NSPasteboard(name: .drag).data(forType: SpaceDragPayload.pasteboardType)
        else { return nil }
        return SpaceDragPayload.decode(from: data)?.spaceID
    }
}
