//
//  SpaceView.swift
//  AtelierRefs
//
//  005-E2 — one open space over the real renderer. Shows the space's asset rows
//  on the infinite canvas (`CanvasView`) driven by `SpaceContent`, or an empty
//  state. Assets enter the board by dragging them in from a collection.
//
//  The canvas host is built ONCE and never rebuilt. Every change — a drag, a
//  restyle, a delete, a reload — updates the `SpaceContent` the renderer already
//  holds and re-syncs through `renderRevision`, because a rebuild would reframe the
//  board and throw away the user's pan and zoom.
//

import AppKit
import AtelierArchive
import AtelierCore
import AtelierIngestion
import CanvasRenderer
import SwiftUI

/// The context-aware action bar's mode, derived purely from the selection count
/// (051 · 2A). Extracted + pure so the thresholds are unit-tested (051 · 12A) and
/// the rendering stays compile-only. Selection drives it, never the active tool
/// (051 · E-4).
nonisolated enum SpaceBarMode: Equatable {
    case idle   // nothing selected → create tools
    case single // one row → Edit + z-order
    case multi  // 2+ rows → align + distribute + z-order

    static func forSelection(count: Int) -> SpaceBarMode {
        switch count {
        case ..<1: .idle
        case 1: .single
        default: .multi
        }
    }
}

extension CanvasArrange.Operation {
    /// Whether the bar enables this op for a selection of `selectionCount`: align
    /// needs ≥2, distribute ≥3 — read straight off `minimumCount` so the threshold
    /// lives in ONE place (051 · 12A/E-3). Pure; unit-tested for the off-by-ones.
    func isEnabled(selectionCount: Int) -> Bool { selectionCount >= minimumCount }
}

struct SpaceView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @EnvironmentObject private var exportController: ExportController
    @StateObject private var space: SpaceModel
    /// Tags for the asset shown in the detail overlay (Space has no folder
    /// context, so it can't reuse `IngestionModel`'s selection-bound tags).
    @StateObject private var tagStore: AssetTagsStore
    /// The pane's search, published by ``LibrarySearchable`` (085 · C2) — where a
    /// clicked color swatch lands.
    @Environment(\.librarySearch) private var librarySearch
    @State private var quickLook = QuickLookController()
    @State private var tool: CanvasTool = .select
    @State private var showEditor = false
    /// The asset row shown in the full-window detail overlay, or `nil`.
    @State private var detailItem: SpaceItemDetail?
    /// The tile the canvas host is editing inline (2B · 054 §5), MIRRORED from
    /// `onEditingChanged`. Never written directly: the host owns the edit — it begins
    /// one inside its own `mouseDown` — so this only ever reports what is already true.
    /// It exists because the format bubble targets "the box being edited".
    @State private var editingTileID: Int?
    /// A pending "start editing this tile" request, and its monotonic token. Only the
    /// create-a-text-box path needs one: a double-click never comes through here,
    /// because the host has already begun the edit by the time the app hears about it.
    @State private var editRequest: CanvasTextEditRequest?
    @State private var editToken = 0
    /// The live on-screen frame the floating format chrome anchors on (062) —
    /// republished imperatively from the same geometry notifications the editor
    /// listens to, so a pan / zoom / move / resize never re-evaluates this body.
    @StateObject private var chromeAnchor = SpaceTextChromeAnchor()
    /// Whether each of the format chrome's panels is open. Owned HERE, not by the
    /// chrome, because they decide whether the chrome stays mounted: a click that
    /// lands inside a panel (the font panel's search field) can blur the editor and
    /// commit — so a chrome that showed only while editing would unmount the control
    /// mid-click.
    @State private var showAlignPanel = false
    @State private var showFontPanel = false
    @State private var showSizePanel = false
    @State private var showColorPanel = false
    /// Which of the action bar's three collapsed groups is open (069), and the exact
    /// gap's last value, kept across opens so setting the same gap on several
    /// selections doesn't mean retyping it (066).
    ///
    /// One optional rather than three booleans: the groups are mutually exclusive by
    /// construction, and a popover binding that can only hold one value can't leave
    /// two panels racing over the same corner of the canvas.
    @State private var openGroup: SpaceBarGroup?
    @State private var gapValue: Double = 24
    /// The "Add to…" picker `A` raised, or `nil` (024 · K3). Holds the assets it will
    /// file, captured at the press — see ``DestinationRequest``.
    @State private var destinationRequest: DestinationRequest?
    /// Whether this board has already been framed to fit. Owned here rather than by the
    /// canvas host so it is a fact about the BOARD, not about a view instance — the
    /// camera is the user's from the first frame onward.
    @State private var didFrameBoard = false

    init(model: IngestionModel, nav: NavModel, spaceID: UUID, services: AppServices, store: MediaStore) {
        self.model = model
        self.nav = nav
        _space = StateObject(wrappedValue: SpaceModel(spaceID: spaceID, services: services, store: store))
        _tagStore = StateObject(wrappedValue: AssetTagsStore(services: services))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                canvas
            }
            // Full-window detail page for a double-clicked asset tile. Guarding on
            // the row keeps it self-dismissing if the space reloads it away.
            if let detailItem, detailItem.asset != nil {
                spaceDetailOverlay(for: detailItem)
                    .transition(.opacity)
            }
        }
        // Write the last camera before this board goes away (018 · Cluster C). The
        // view's identity is keyed to the space id (`AppShellView.spaceDestination`),
        // so this fires on a space-switch as well as on navigating away — the two
        // moments the 0.4s debounce would otherwise swallow the final gesture of the
        // session. A no-op when nothing is pending, and it publishes nothing, so it
        // is safe inside the view-removal update `onDisappear` runs in.
        .onDisappear { space.flushCameraPersist() }
        // Enumerate the system's font families now, on a background thread (064). A
        // board is the only place a font picker is reachable from, and the first picker
        // to open used to pay ~384 ms for this on the main thread — as part of the click
        // that opened it. Idempotent, so re-opening a board costs nothing.
        .task { FontFamilyCatalog.shared.warm() }
        // The space name lives in the in-content header only (parity with Collection);
        // the native window-toolbar title is dropped so the name isn't shown twice.
        // Undo/redo and z-order live in the floating bottom action bar (`actionBar`,
        // over the canvas) rather than the native window toolbar.
        // Surface space-level write failures on the shared app alert.
        .onChange(of: space.lastError) { _, message in
            if let message { model.lastError = message; space.lastError = nil }
        }
        // Tag edits from the detail overlay surface on the same alert.
        .onChange(of: tagStore.lastError) { _, message in
            if let message { model.lastError = message; tagStore.lastError = nil }
        }
        // A ⌘⌫ destroy started HERE (022 · D3) deletes the asset, and `space_item`
        // CASCADEs on `asset_id` — so the row is gone from the database while this
        // board is still drawing its tile. Reload on the model's contents bump, which
        // is the signal every asset write raises (the search grid re-runs its query on
        // the same one). A delete from elsewhere lands the same way, which is a fix in
        // its own right: a board left open behind a collection used to keep the tile.
        .onChange(of: model.contentsVersion) { _, _ in
            Task { await space.load() }
        }
        // Edit ▸ Remove / Delete, as a BOARD means them (022 · D5). Published from
        // here so the menu titles name the placement rather than a collection, and so
        // ⌘⌫ from the menu destroys what is selected on the canvas — not whatever the
        // collection grid was last left holding.
        .focusedSceneValue(\.deleteVerbs, DeleteVerbs(
            removeTitle: "Remove from Board",
            canRemove: true,
            remove: {
                let content = space.content()
                space.removeTiles(tileIDs: space.selectedTileIDs(in: content), in: content)
            },
            destroy: {
                let content = space.content()
                let assetIDs = space.selectedTileIDs(in: content)
                    .compactMap { content.detail(forTileID: $0)?.asset?.id }
                model.requestDelete(assetIDs: assetIDs)
            }))
        // Edit ▸ Copy as Text (⌥⌘C, 465) — the board's words: its text boxes, and
        // the media-less assets among the selection, in z-order. `canCopy` reads
        // `items` (cheap, and words need no geometry); the copy itself reads
        // `placedItems`, whose z is the LIVE stacking a drag may have moved.
        .focusedSceneValue(\.copyAsText, CopyAsTextVerb(
            canCopy: space.selectedRows(from: space.items).contains { detail in
                if let asset = detail.asset { return AssetExport.mayHaveText(asset) }
                return detail.item.kind == .text
                    && (detail.item.style.flatMap { ElementStyle(jsonString: $0)?.text }?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            },
            copy: {
                let rows = space.selectedRows(from: space.placedItems)
                    .sorted { $0.item.z < $1.item.z }
                guard let words = Self.copiedText(
                    rows, blobURL: { model.blobURL(forAsset: $0) }) else { return }
                CopyText.write(only: words, to: .general)
            }))
        // Expose the board's export to the File-menu command (052 · B3): default
        // config (PDF, single page) for the same selection-or-whole-board rows.
        .focusedSceneValue(\.exportMoodboard, ExportMoodboardAction {
            guard !space.items.isEmpty else { return }
            let mapping = MoodboardExport.map(
                details: MoodboardExport.rows(items: space.placedItems, selected: space.selectedItemIDs),
                imageURL: { model.previewImageURL(forAsset: $0) })
            exportController.requestExport(
                mapping: mapping, config: ExportConfig(), suggestedName: space.name)
        })
    }

    /// The title row — name + count, matching the Collection screen's header (222)
    /// line for line: the same `sectionTitle`, the same secondary `.callout` count,
    /// the same 10pt gap, at the same 24pt content margin, with no rule beneath it.
    /// Moving between a collection and a board doesn't shift the title.
    ///
    /// The tools left first (051 · 8A, into the context-aware `actionBar`); this drops
    /// the rest. The "drag to place" hint is gone — permanent chrome teaching a gesture
    /// you learn once — and the moodboard export moved down into `actionBar`, the way
    /// the Collection's contact-sheet export lives in its floating bar rather than its
    /// header. What's left is purely display, so the row is non-interactive on both
    /// screens.
    private var header: some View {
        HStack(spacing: 10) {
            Text(space.name)
                .font(Theme.Typography.sectionTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            // Redacted until the board's first read resolves, so it can't flash
            // "0 items" at a board that has some (the Collection header's reason,
            // reached differently: `space` is nil rather than another board's).
            Text("\(space.items.count) items")
                .font(Theme.Typography.body).foregroundStyle(.secondary)
                .redacted(reason: space.space == nil ? .placeholder : [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    /// Select / Frame / Text, in the `.idle` sub-bar. A create tool rubber-bands a
    /// new element, then the canvas flips back to Select (see `onCreateElement`).
    /// The V/F/T shortcuts live on the canvas container (see `canvas`), NOT here —
    /// they must keep firing when a selection swaps these out of the bar (051 · E-2).
    ///
    /// Three ``SelectionBarModeButton`` glyphs at the bar's own `spacing: 2`, so the
    /// tools are the same 30×28 taps as every other button in the row. This was a
    /// `.pickerStyle(.segmented)` `Picker` — a stock AppKit bezel with an accent-blue
    /// live segment, sitting in a monochrome capsule of flat glyphs, in an app whose
    /// palette has no accent at all. The help text moved onto the individual tools with
    /// it: one tooltip reading "Select (V), Frame (F), or Text (T)" was all a single
    /// control could say.
    private var toolPicker: some View {
        HStack(spacing: 2) {
            toolButton(.select, symbol: "cursorarrow", help: "Select (V)")
            toolButton(.frame, symbol: "rectangle.dashed", help: "Frame (F)")
            toolButton(.text, symbol: "textformat", help: "Text (T)")
        }
        .animation(Theme.Motion.gentle, value: tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool")
    }

    private func toolButton(
        _ value: CanvasTool, symbol: String, help: String
    ) -> some View {
        SelectionBarModeButton(symbol, help: help, isOn: tool == value) { tool = value }
    }

    // V / F / T switch tools without reaching for the picker (design-tool muscle
    // memory). They used to be zero-size hidden buttons carrying unmodified
    // `keyboardShortcut`s, on the assumption that a focused text field would take
    // plain keys first. It doesn't: a key equivalent is dispatched BEFORE `keyDown`
    // reaches the first responder and knows nothing about an AppKit text view inside
    // an `NSViewRepresentable`, so every `t`, `f` and `v` typed into a text box was
    // swallowed and switched the tool — after which the canvas was in create mode and
    // a double-click made a new box instead of editing the one under the cursor. The
    // canvas now handles them in `keyDown` (`onSelectTool`), where its own focus is
    // the gate. See `.change-log/269`.

    /// The `.single` bar's Edit glyph (051 · 8A — folded down from the header).
    /// Shows only when the lone selected row is a freeform element; opens its
    /// inspector popover. A selected asset has no style to edit, so it's absent.
    @ViewBuilder private var editButton: some View {
        if let element = space.selectedElement {
            SelectionBarButton("slider.horizontal.3", help: "Edit style") { showEditor = true }
                // `.top`, like every other popover hung off this bar: downward is
                // clipped by the floating capsule (see `groupButton`). This one was
                // the last `.bottom` left.
                .popover(isPresented: $showEditor, arrowEdge: .top) {
                    ElementInspector(
                        kind: element.item.kind,
                        initialStyle: space.style(forItemID: element.item.id),
                        onCommit: { style in space.updateStyle(itemID: element.item.id, style: style) },
                        onDelete: { space.removeItem(element.item.id) })
                    .id(element.item.id)
                }
        }
    }

    @ViewBuilder private var canvas: some View {
        let content = space.content()
        ZStack {
            CanvasView(
                provider: content, images: content,
                selectedTileIDs: space.selectedTileIDs(in: content),
                syncToken: space.renderRevision,
                tool: tool,
                editRequest: editRequest,
                onActivateTile: { tileID in
                    if let url = content.videoURL(forTileID: tileID) {
                        quickLook.present(url: url)
                    } else if let detail = content.detail(forTileID: tileID),
                              detail.item.kind == .asset, detail.asset != nil {
                        // Double-click an image asset → open its detail page.
                        openAssetDetail(detail)
                    } else if let detail = content.detail(forTileID: tileID),
                              detail.item.kind == .text {
                        // A TEXT element is already being edited by the time this
                        // fires — the host begins it inside `mouseDown`, with no round
                        // trip through here. Just keep the shared selection in step.
                        space.select(tileID: tileID, in: content)
                    } else {
                        // Double-click a FRAME element → open its style popover
                        // (frames have no inline path, 054 §5.2).
                        space.select(tileID: tileID, in: content)
                        showEditor = true
                    }
                },
                onSelectTiles: { tileIDs in
                    space.select(tileIDs: tileIDs, in: content)
                },
                // V / F / T, reported by the canvas because only the canvas knows
                // whether a text box has the keyboard.
                onSelectTool: { tool = $0 },
                // `A` — file the selected tiles' ASSETS into a collection, placements
                // untouched (024 · K3). Reported by the canvas for the same reason the
                // tool keys are: its own focus is the gate that keeps a bare letter out
                // of an open text box.
                //
                // **`M` is not bound here, deliberately.** [024] §C recommended M on
                // every surface with a selection, but a board is not a collection, so
                // "move" would have had to mean "file the assets AND drop the
                // placements" — a destructive-adjacent composite wearing the same key
                // as the grid's plain reparent. `A` is the verb a board actually has.
                //
                // Elements (frames, text) carry no asset and are skipped, exactly as
                // ⌘⌫ skips them; a selection of nothing but elements files nothing.
                onFileTiles: { tileIDs in
                    let assetIDs = tileIDs
                        .compactMap { content.detail(forTileID: $0) }
                        .sorted { $0.item.z < $1.item.z }
                        .compactMap { $0.asset?.id }
                    guard !assetIDs.isEmpty else { return }
                    destinationRequest = DestinationRequest(verb: .add, assetIDs: assetIDs)
                },
                // ⌫ — drop the PLACEMENT. A board owns placements, not memberships
                // (019 · C1), so this is "remove from where you are looking" here.
                onRemoveTiles: { tileIDs in
                    space.removeTiles(tileIDs: tileIDs, in: content)
                },
                // ⌘⌫ — leave the LIBRARY (022 · D3). These two were handed the same
                // closure body, with a comment saying so: a board had no path to
                // `deleteAssetsRecoverable` at all, and its context menu offered two
                // labels for one behaviour. It stages the SHARED confirmation, so the
                // one destructive implementation stays the only one.
                //
                // Element tiles (frame / text) carry no asset and are skipped — an
                // element exists only as a placement, so ⌫ is already the whole verb
                // for one. A selection of nothing but elements stages nothing.
                // Archive (023 · A3) — the tile vanishes from the board and comes
                // back, in the same place, when the asset is unarchived: the
                // placement row is untouched, only the read hides it. Elements
                // carry no asset and are skipped, exactly as ⌘⌫ skips them.
                onArchiveTiles: { tileIDs in
                    let assetIDs = tileIDs
                        .compactMap { content.detail(forTileID: $0) }
                        .sorted { $0.item.z < $1.item.z }
                        .compactMap { $0.asset?.id }
                    guard !assetIDs.isEmpty else { return }
                    Task { await model.toggleArchived(assetIDs: assetIDs) }
                },
                onDeleteTiles: { tileIDs in
                    let assetIDs = tileIDs
                        .compactMap { content.detail(forTileID: $0) }
                        .sorted { $0.item.z < $1.item.z }
                        .compactMap { $0.asset?.id }
                    model.requestDelete(assetIDs: assetIDs)
                },
                onCopyTiles: { tileIDs in
                    // ⌘C writes THREE representations of the same selection (065,
                    // 464), so the destination decides what a copy meant rather than
                    // the source:
                    //
                    //  - the asset one (052 · B1) — z-ordered, elements skipped — which
                    //    is what a collection or another app can use;
                    //  - the board one, which keeps every row INCLUDING frames and text
                    //    boxes, with their relative layout, for pasting onto a board;
                    //  - the WORDS (464), for an app that takes nothing else.
                    //
                    // Before this, ⌘C on a text box put nothing on the pasteboard at
                    // all, because the asset representation is the only one there was.
                    let details = tileIDs
                        .compactMap { content.detail(forTileID: $0) }
                        .sorted { $0.item.z < $1.item.z }
                    let assets = details.compactMap { detail in
                        detail.asset.map { (asset: $0, source: detail.source) }
                    }
                    // Order is load-bearing: `copyToPasteboard` CLEARS the pasteboard
                    // before writing, so the board representation has to go on after
                    // it. The WORDS need no third call — they are handed to that same
                    // write, which is the only way they can land in ONE string item
                    // rather than duplicating the asset text it would derive itself.
                    //
                    // A board owns PLACEMENTS, not memberships (019 · C1), so the asset
                    // representation's private payload carries the nil-source sentinel:
                    // pasting it into a collection is always an add, never a
                    // same-collection no-op.
                    //
                    // A selection of only text boxes used to skip this call and clear
                    // by hand, because it would have reported "0 copied" at the user
                    // for a copy that in fact succeeded. `alsoCopied` is what makes the
                    // call sayable in that case: the elements are counted, so the
                    // report is true whether or not any asset came with them (464).
                    model.copyToPasteboard(
                        assets: assets, sourceCollectionID: AssetDragPayload.nilSourceID,
                        alsoCopied: details.count - assets.count,
                        text: Self.copiedText(
                            details, blobURL: { model.blobURL(forAsset: $0) }))
                    copyElementsToPasteboard(details.map(\.item))
                },
                onMoveTile: { tileID, worldOrigin in
                    space.moveTile(tileID: tileID, to: worldOrigin, in: content)
                },
                // ⌥-drag duplicates ANY tile (065b). It used to fire only for tiles
                // with nothing to drag out — so an asset could not be ⌥-duplicated at
                // all — because ⌥ was shared with the drag-out gesture, which is now ⌘.
                onDuplicateTiles: { tileIDs, worldOffset in
                    space.duplicateTiles(tileIDs: tileIDs, offset: worldOffset, in: content)
                },
                onCreateElement: { createdTool, worldRect in
                    switch createdTool {
                    case .frame:
                        space.addFrame(worldRect: worldRect)
                    case .text:
                        // Place the box, then enter inline edit immediately (054 §5.2)
                        // once the write settles and the new row has a tile id.
                        space.addText(worldRect: worldRect)
                        Task {
                            await space.waitForWrites()
                            let created = space.content()
                            if let id = space.selectedItemID,
                               let tid = created.tileID(forSpaceItemID: id) {
                                editToken += 1
                                editRequest = CanvasTextEditRequest(
                                    tileID: tid, isNewlyCreated: true, token: editToken)
                            }
                        }
                    case .select:
                        break
                    }
                    tool = .select // one-shot: back to Select after placing
                },
                onResizeTile: { tileID, worldRect in
                    space.resizeTile(tileID: tileID, to: worldRect, in: content)
                },
                // The canvas repositions its own editor before these fire, so the
                // chrome anchor always reads the frame the editor has settled on.
                onTransformChanged: { chromeAnchor.refresh() },
                // Every pan / zoom, plus the opening restore-or-fit. Debounced into
                // one write per gesture; `onDisappear` flushes the last one.
                onCameraChanged: { camera in space.cameraChanged(camera) },
                onLiveFrameChanged: { chromeAnchor.refresh() },
                // `onHostReady` fires from `makeNSView` — inside a view update, where
                // publishing is undefined behaviour — so the anchor's read is hopped
                // off the update frame.
                onHostReady: { host in
                    chromeAnchor.host = host
                    Task { @MainActor in
                        chromeAnchor.refresh()
                        // The tool keys are `keyDown` now, which only reaches a first
                        // responder — so arm the canvas as one on open, or V/F/T would
                        // be dead until the board had been clicked once. Hopped
                        // because `onHostReady` fires from `makeNSView`, before the
                        // host has been put in a window.
                        host.window?.makeFirstResponder(host)
                    }
                },
                // Drop target (SP2 · S2 + SP3 · S1). We register the app-private
                // asset-drag type PLUS the external file / image / URL types, so
                // both an in-app reference drag and a Finder/browser drop land here.
                acceptedDropTypes: [
                    AssetDragPayload.pasteboardType, .fileURL, .png, .tiff, .URL,
                ],
                onDragEntered: { pasteboard in
                    // An .assetIDs drag is ONLY ever a placement (never external) —
                    // accept iff it routes to place; otherwise fall to the external
                    // importable-content check.
                    if let payload = AssetDragPayload.decode(from: pasteboard) {
                        if case .place = canvasDropRoute(.assetDrag(payload)) { return .copy }
                        return []
                    }
                    return ImportPasteboard.hasImportableContent(on: pasteboard) ? .copy : []
                },
                onDrop: { pasteboard, worldPoint in
                    // 1. An INTERNAL drag carries .assetIDs AND (since drag-out, 011)
                    //    file promises — re-ingesting our own promised file would
                    //    duplicate the asset. So an .assetIDs drag is ONLY a
                    //    placement, never an external import (mirror handleDrop's
                    //    guard); an empty marker is refused, never falls through.
                    if let payload = AssetDragPayload.decode(from: pasteboard) {
                        guard case let .place(assetIDs) = canvasDropRoute(.assetDrag(payload)) else {
                            return false
                        }
                        space.placeDroppedAssets(ids: assetIDs, at: worldPoint)
                        return true
                    }
                    // 2. External content: ingest into Unsorted + place at the drop
                    //    point (shared with paste). An unreadable DROP is reported.
                    if importExternal(from: pasteboard, at: worldPoint) { return true }
                    model.reportUnreadableDrop()
                    return false
                },
                // SP4: ⌘V on the focused canvas pastes external content at the
                // viewport centre through the SAME import path as a drop. A paste
                // with nothing importable is a silent no-op.
                onPaste: { pasteboard, worldPoint in
                    pasteOntoBoard(from: pasteboard, at: worldPoint)
                },
                // SP7 / 065b: ⌘-drag a tile out to a sidebar space / collection row
                // (adds a copy there). Maps the carried tiles → an asset-drag payload;
                // nil (no asset tiles) means the drag simply does not start, rather than
                // degrading to a move — see `CanvasDragIntent.none`.
                //
                // ⌥ still selects copy-vs-move at DROP time on the destination side
                // (009 · N3, `DropRouter`). No conflict: the gesture modifier is latched
                // at mouse-down and the drop modifier is read when you let go.
                onBeginTileDragOut: { tileIDs in
                    content.dragOutPayload(forTileIDs: tileIDs)?.makePasteboardItem()
                },
                // Establish the board's camera exactly once, on its first open. A board
                // loads its rows asynchronously, so the canvas is laid out before there
                // is anything to look at — the host therefore waits for content rather
                // than burning its one shot on an empty world. `didFrameBoard` lives on
                // this view, whose identity is stable, so the camera survives even if
                // the host is ever rebuilt for some other reason.
                framesContentWhenReady: !didFrameBoard,
                onDidFrameContent: { Task { @MainActor in didFrameBoard = true } },
                // Where this board was left (018 · Cluster C). `nil` — never opened,
                // or a blob that no longer decodes — fits the content instead, and so
                // does a camera that would open on empty space.
                restoreCamera: space.openingCamera,
                // The host owns the edit; these two are how the app hears about it.
                //
                // `onEditingChanged` is hopped off the update frame: it publishes, and
                // it fires from inside `apply(to:)` when an edit request is delivered,
                // which runs during a view update.
                onEditingChanged: { tileID in
                    Task { @MainActor in editingTileID = tileID }
                },
                // `onFinishEditingText` is deliberately NOT hopped. The canvas un-blanks
                // the tile and restores its stored height IMMEDIATELY after this returns,
                // reading the provider fresh — so anything deferred here means the box is
                // redrawn with the OLD string at the OLD height for a turn, then reflows
                // to the new one. That was a visible glitch on every commit. Writing here
                // and now is safe because `updateStyle` mirrors into the live
                // `SpaceContent` synchronously (only the persistence is enqueued), so the
                // un-blank already finds the new text and its derived height. The host
                // hops this itself on its teardown paths, where publishing into a view
                // update would be the real hazard.
                onFinishEditingText: { tileID, outcome in
                    applyEditOutcome(outcome, tileID: tileID)
                })

            if space.items.isEmpty { emptyHint }

            // The floating palette + font/size bubble for the text box being EDITED
            // (062). The editor is a subview of the canvas host below this, and only
            // as large as the box itself, so the bubble's buttons take their own clicks.
            if let target = formatTarget(in: content) {
                SpaceFormatChrome(
                    anchor: chromeAnchor,
                    style: space.style(forItemID: target.itemID),
                    showAlign: $showAlignPanel,
                    showFont: $showFontPanel,
                    showSize: $showSizePanel,
                    showColor: $showColorPanel,
                    onChange: { space.updateStyle(itemID: target.itemID, style: $0) })
                    // Deferred: `onAppear` runs inside the view update, and the anchor
                    // publishes — the same "Publishing changes from within view
                    // updates" trap `ElementInspector.onDisappear` already dodges.
                    .onAppear {
                        let tileID = target.tileID
                        Task { @MainActor in chromeAnchor.track(tileID: tileID) }
                    }
                    .onChange(of: target.tileID) { _, tileID in
                        chromeAnchor.track(tileID: tileID)
                    }
                    // A restyle re-derives the box's height in place (`renderRevision`,
                    // never a rebuild), so the chrome has to re-read the frame it just
                    // changed — otherwise picking 96pt leaves the bubble at the height
                    // the box had at 24.
                    .onChange(of: space.renderRevision) { _, _ in chromeAnchor.refresh() }
            }
        }
        .overlay(alignment: .bottom) { actionBar.padding(.bottom, Theme.Spacing.lg) }
        // `A`'s destination picker (024 · K3), anchored where the action bar's own
        // popovers open from and opening upward like them.
        .overlay(alignment: .bottom) { destinationPickerAnchor }
        // Live import feedback for an external drop (059 · SP3 / 5A) — the SAME
        // floating pill the collection grid shows, driven by the shared
        // `IngestionModel.progress`. Top-aligned so it never collides with the
        // bottom action bar.
        .overlay(alignment: .top) {
            ImportProgressPill(progress: model.progress)
                .padding(.top, Theme.Spacing.md)
        }
        // The floating "+". A board has exactly ONE thing to add from outside the app,
        // so this is a direct action rather than a menu of one — the tooltip carries
        // the label a bare disc can't. (Frames and text come from the tool picker; the
        // library comes in by drag.)
        .floatingAdd(help: "Import images onto this board", action: importFilesOntoBoard)
    }

    /// The zero-size anchor `A`'s picker hangs off (024 · K3) — the same corner the
    /// action bar's align / spacing / z-order panels open from, so a keyboard-raised
    /// panel lands where a clicked one does. Non-interactive, so it can never shadow a
    /// press meant for the canvas.
    ///
    /// **Nothing is greyed.** The grid greys the collection you are looking at because
    /// filing there is a no-op; a board is not a collection, so every destination is a
    /// real one.
    @ViewBuilder private var destinationPickerAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .padding(.bottom, Theme.Spacing.xxl)
            .allowsHitTesting(false)
            .popover(item: $destinationRequest, arrowEdge: .top) { request in
                DestinationPicker(
                    verb: request.verb,
                    count: request.assetIDs.count,
                    folders: model.folders,
                    unsortedID: model.unsortedFolderID,
                    // `copyToCollection` with no source: a board's tiles are
                    // placements, not memberships, so there is no folder for the
                    // notice's verb to read "moved out of" (019 · C1).
                    onSelect: { model.copyToCollection(assetIDs: request.assetIDs, to: $0) },
                    onDismiss: { destinationRequest = nil })
            }
            // However it closed, the canvas gets the keyboard back — the same
            // `restoreCanvasFocus` every other bar popover runs on dismiss.
            .onChange(of: destinationRequest?.id) { _, id in
                if id == nil { restoreCanvasFocus() }
            }
    }

    /// "+" on a board: choose files, ingest them, and flow them in below the content.
    ///
    /// Into UNSORTED, matching the canvas's drop and ⌘V paths (`importExternal`) — a
    /// board is not a collection, so an import here has no collection context to
    /// inherit, and inventing one would file the user's images somewhere they never
    /// chose. Placement goes through `SpaceModel`, the only writer that reloads an
    /// OPEN board; `IngestionModel.addAssetsToSpace` writes the rows but refreshes the
    /// spaces LIST, so an import routed that way would not appear until reopen.
    private func importFilesOntoBoard() {
        let folder = model.unsortedFolderID
        ImportFilesPanel.present { urls in
            guard !urls.isEmpty else { return }
            Task {
                let assets = await model.importInputs(
                    IngestionModel.fileInputs(urls, into: folder))
                await model.refreshFolders()
                space.addAssets(assets)
            }
        }
    }

    /// Apply the outcome of an inline edit the canvas host just finished (054 §5.3).
    ///
    /// The host decided WHAT happened; this decides what it means for the model. A
    /// commit routes through the SAME `updateStyle` path the inspector uses, so an
    /// edit is one undo step covering both the string and the height it implies.
    private func applyEditOutcome(_ outcome: CanvasTextEditOutcome, tileID: Int) {
        guard let itemID = space.content().spaceItemID(forTileID: tileID) else { return }
        switch outcome {
        case .committed(let newText):
            var style = space.style(forItemID: itemID)
            style.text = newText
            space.updateStyle(itemID: itemID, style: style)
        case .deleted:
            space.removeItem(itemID)
        case .cancelled:
            break
        }
    }

    /// The text box the floating format chrome targets (062) — **the one being
    /// edited**. Merely selecting a box doesn't raise it: formatting belongs to the
    /// act of writing, and chrome that appears on every selection is chrome in the
    /// way of every drag.
    ///
    /// The one exception is a panel the chrome itself opened. The custom panels don't
    /// take key-window focus the way `NSPopover` did, so the edit usually stays live
    /// while one is up — but a click that lands in a focusable control inside one
    /// (the font panel's search field) still blurs the `NSTextView` and commits. So
    /// while a panel is up the target falls through to the sole selected `.text`
    /// element, which is the box that was being edited a moment ago, and the format
    /// still lands where the user aimed it.
    ///
    /// The chrome anchors on the TILE (its on-screen frame) but writes to the ITEM,
    /// so both are resolved here, together.
    private func formatTarget(in content: SpaceContent) -> (tileID: Int, itemID: UUID)? {
        if let editingTileID, let detail = content.detail(forTileID: editingTileID),
           detail.item.kind == .text {
            return (editingTileID, detail.item.id)
        }
        guard showAlignPanel || showFontPanel || showSizePanel || showColorPanel
        else { return nil }
        guard let element = space.selectedElement, element.item.kind == .text,
              let tileID = content.tileID(forSpaceItemID: element.item.id) else { return nil }
        return (tileID, element.item.id)
    }

    // MARK: - Bottom action bar

    /// The bar's mode, derived PURELY from the selection count (051 · 2A). Selection
    /// wins over any active create tool (051 · E-4) — the tools stay reachable via
    /// the hoisted V/F/T shortcuts regardless of mode.
    private var barMode: SpaceBarMode { .forSelection(count: space.selectedItemIDs.count) }

    /// The floating action pill over the canvas, context-aware (051 · 2A/E-2).
    ///
    /// Undo/redo and the z-order shortcut carriers are MODE-INVARIANT — mounted in
    /// every mode — so ⌘Z / ⌘⇧Z / ⌘⇧] / ⌘⇧[ always fire (a `keyboardShortcut` on an
    /// unrendered button is dead). The mode-switched half is the tools (`.idle`) /
    /// Edit + duplicate + z-order (`.single`) / align + spacing + duplicate + z-order
    /// (`.multi`).
    ///
    /// `.multi` carried sixteen glyphs before 069, twelve of them ops. Align (6),
    /// spacing (distribute ×2 + tidy + gap) and z-order (2) now sit behind one glyph
    /// each, so the row is eight wide in every mode and no longer roughly doubles when
    /// a second tile is selected. Reuses the shared `SelectionBarButton` glyphs +
    /// ``floatingBarChrome(leading:trailing:vertical:)`` capsule (parity with the
    /// Collection/Search bar) — a flat `spacing: 2` row.
    ///
    /// It is the app's one ICON-ONLY bar, so it passes `trailing: 16` to balance the
    /// chrome's text-tuned leading inset. That used to be a local
    /// `.padding(.trailing, 10)` stacked on top of the modifier's own 6 — the same
    /// number, arrived at by addition, which read as this bar disagreeing with the
    /// chrome rather than as the chrome having a documented second case.
    private var actionBar: some View {
        HStack(spacing: 2) {
            undoRedoBar // mode-invariant (051 · E-2)
            zOrderShortcuts // mode-invariant, zero-size (069)
            switch barMode {
            case .idle: toolPicker
            case .single: singleBar
            case .multi: multiBar
            }
            barSeparator
            exportBar // mode-invariant
        }
        .floatingBarChrome(trailing: Theme.Spacing.lg)
    }

    /// The rule between the mode-switched half and the export.
    ///
    /// Semantically, an export LEAVES the app, so it isn't another edit in the same
    /// row — the same reason the collection's "+" menu puts a rule above "New Space
    /// from Collection". That is now the whole of its case, and it is enough.
    ///
    /// It used to earn its place twice. The bar's `spacing: 2` is not the gap you
    /// see: every glyph is a 30×28 `SelectionBarIcon` whose 15pt symbol carries ~7.5pt
    /// of its own air, so neighbouring glyphs read as ~17pt apart. The segmented
    /// `toolPicker` was the ONE child with no such margin — its bezel was a hard edge —
    /// so in `.idle` the export glyph sat 11pt from the tools while the capsule's own
    /// trailing margin is 24pt, and the button looked jammed against them. The tools
    /// are `SelectionBarIcon` glyphs now and carry the same air as everything else, so
    /// that defect is gone; the rule stays for the reason above, not for this one.
    private var barSeparator: some View {
        Rectangle()
            .fill(Theme.Colors.hairlineStrong)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 5)
    }

    /// The moodboard export, folded down out of the header — the Collection screen's
    /// contact-sheet export lives in its floating bar too, so the two now agree on
    /// where an export is raised from.
    ///
    /// Mode-invariant, like undo/redo: an export is selection-or-whole-board (052 ·
    /// B3), so it means the same thing at every selection size. The ring renders
    /// nothing unless a board is actually being written — measured, not assumed: a
    /// `Group` whose branches all fail contributes no subview, so the stack adds no
    /// spacing for it either.
    @ViewBuilder private var exportBar: some View {
        MoodboardExportButton(space: space, model: model)
        ExportProgressRing()
    }

    /// Undo / redo — always on screen so their shortcuts never die (051 · E-2).
    ///
    /// The shortcuts, but not the buttons, drop out while a text box is being edited.
    /// A sibling `keyboardShortcut` beats the canvas host's `performKeyEquivalent`
    /// (measured), so leaving ⌘Z registered means one press mid-sentence reverts the
    /// whole previous board operation instead of one keystroke. Unregistering it lets
    /// the event fall through to the `NSTextView`'s own per-keystroke undo. The
    /// buttons stay mounted and clickable — only their key binding is withdrawn, so
    /// the bar doesn't reflow when an edit starts.
    @ViewBuilder private var undoRedoBar: some View {
        let editing = editingTileID != nil
        SelectionBarButton(
            "arrow.uturn.backward",
            help: space.canUndo ? "Undo \(space.undoActionName)" : "Nothing to undo"
        ) { space.undo() }
            .disabled(!space.canUndo)
            .keyboardShortcut(editing ? nil : KeyboardShortcut("z", modifiers: .command))

        SelectionBarButton(
            "arrow.uturn.forward",
            help: space.canRedo ? "Redo \(space.redoActionName)" : "Nothing to redo"
        ) { space.redo() }
            .disabled(!space.canRedo)
            .keyboardShortcut(
                editing ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))
    }

    /// `.single`: Edit (elements only), duplicate, z-order for the lone selection.
    ///
    /// Z-order uses the SAME collapsed group `.multi` does, even though this mode has
    /// room for both buttons. The point is that the control doesn't move or change
    /// shape when you select a second tile — a bar whose buttons rearrange under the
    /// cursor as the selection grows is the thing this pass is fixing.
    @ViewBuilder private var singleBar: some View {
        editButton
        duplicateButton
        groupButton(.zOrder)
    }

    /// `.multi`: align, spacing and z-order, each collapsed behind one glyph (069).
    ///
    /// This used to be a flat `ForEach` over all nine `CanvasArrange.Operation` cases
    /// plus a ruler and two z-order buttons — twelve glyphs, in a bar that already
    /// carried undo/redo and the export pair. The ops didn't change; only how many of
    /// them are on screen at rest did.
    @ViewBuilder private var multiBar: some View {
        groupButton(.align)
        groupButton(.spacing)
        duplicateButton
        groupButton(.zOrder)
    }

    /// One collapsed group: a bar glyph that opens its panel, gated on whether ANY op
    /// inside would run at this selection size (see ``SpaceBarGroup/isEnabled(selectionCount:)``).
    ///
    /// `arrowEdge: .top`, so the panel opens UPWARD over the canvas. A bar popover
    /// that opens downward is clipped by the floating capsule — the reason
    /// `CollectionView`'s overflow documents the same choice. (066's gap popover used
    /// `.bottom`; it is folded into `.spacing` here and inherits the fix.)
    ///
    /// Focus is handed back to the canvas on dismiss, deferred off the view update
    /// because `onDisappear` runs inside one. Without it the canvas stays deaf to ⌫
    /// and the V/F/T tool keys after any panel closes.
    @ViewBuilder private func groupButton(_ group: SpaceBarGroup) -> some View {
        let count = space.selectedItemIDs.count
        let enabled = group.isEnabled(selectionCount: count)
        SelectionBarButton(group.symbol, help: group.help) {
            openGroup = (openGroup == group) ? nil : group
        }
        .disabled(!enabled)
        .popover(item: popoverBinding(for: group), arrowEdge: .top) { _ in
            groupPanel(group, selectionCount: count)
                .onDisappear { restoreCanvasFocus() }
        }
    }

    /// A per-group binding onto the single ``openGroup`` state: non-nil only while
    /// THIS group is the open one. Each trigger owns its own `.popover`, so each needs
    /// a binding that reads as "am I showing", not "is anything showing".
    private func popoverBinding(for group: SpaceBarGroup) -> Binding<SpaceBarGroup?> {
        Binding(
            get: { openGroup == group ? group : nil },
            set: { if $0 == nil, openGroup == group { openGroup = nil } })
    }

    /// The panel behind each group. No branch dismisses on apply: align and spacing
    /// are repeated, adjusted actions, and the canvas updates live behind the panel.
    /// Z-order closes on pick — front and back are terminal, and there is nothing to
    /// chain.
    @ViewBuilder
    private func groupPanel(_ group: SpaceBarGroup, selectionCount: Int) -> some View {
        switch group {
        case .align:
            SpaceAlignPopover(selectionCount: selectionCount) { space.arrange($0) }
        case .spacing:
            SpaceSpacingPopover(
                selectionCount: selectionCount,
                gap: $gapValue,
                onArrange: { space.arrange($0) },
                onPack: { space.pack(axis: $0, gap: CGFloat(gapValue)) })
        case .zOrder:
            SpaceZOrderPopover(
                onBringToFront: { space.bringSelectionToFront(); openGroup = nil },
                onSendToBack: { space.sendSelectionToBack(); openGroup = nil })
        }
    }

    /// Hand first responder back to the canvas after a panel closes, deferred off the
    /// view update (`onDisappear` runs inside one).
    private func restoreCanvasFocus() {
        guard let host = chromeAnchor.host else { return }
        Task { @MainActor in host.window?.makeFirstResponder(host) }
    }

    /// Duplicate the selection (⌘D, 065) — in both `.single` and `.multi`, because a
    /// duplicate means the same thing at any selection size.
    ///
    /// The shortcut is WITHDRAWN while a text box is being edited, the same bargain
    /// ⌘Z strikes in ``undoRedoBar``: a key equivalent is dispatched before `keyDown`
    /// reaches the first responder, so a live binding here would fire while the user is
    /// typing — and ⌘D in a text field means nothing, so the keystroke would simply
    /// vanish into a duplicated box. Withdrawing the binding rather than unmounting the
    /// button keeps the bar from reflowing mid-edit.
    @ViewBuilder private var duplicateButton: some View {
        SelectionBarButton(
            "plus.square.on.square",
            help: "Duplicate the selection (⌘D)"
        ) { space.duplicateSelection() }
            .keyboardShortcut(
                editingTileID != nil ? nil : KeyboardShortcut("d", modifiers: .command))
    }

    /// ⌘⇧] / ⌘⇧[ for z-order (034 P2 · 049 D7 — relative order preserved), carried by
    /// two zero-size buttons rather than by the visible controls.
    ///
    /// The bindings USED to live on the two z-order bar buttons. Collapsing those into
    /// a popover (069) would have killed both shortcuts, because a `keyboardShortcut`
    /// on a view that isn't rendered never fires — the same trap `undoRedoBar` and
    /// `duplicateButton` already document from the other direction, where the button
    /// stays mounted precisely so its binding survives. A closed popover's content is
    /// not mounted at all, so the binding has to be hoisted out of it.
    ///
    /// MODE-INVARIANT, like undo/redo: mounted in `.idle` too, so ⌘⇧] works on a
    /// selection made by any route. The model no-ops on an empty selection.
    ///
    /// The shortcuts, but not the buttons, drop out while a text box is being edited —
    /// a key equivalent is dispatched before `keyDown` reaches the first responder, so
    /// a live binding here would restack the board mid-sentence.
    @ViewBuilder private var zOrderShortcuts: some View {
        let editing = editingTileID != nil
        Group {
            Button("Bring to Front") { space.bringSelectionToFront() }
                .keyboardShortcut(
                    editing ? nil : KeyboardShortcut("]", modifiers: [.command, .shift]))
            Button("Send to Back") { space.sendSelectionToBack() }
                .keyboardShortcut(
                    editing ? nil : KeyboardShortcut("[", modifiers: [.command, .shift]))
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - External import (drop + paste)

    /// Decode an external pasteboard (a DROP or a ⌘V PASTE) and — if it carries
    /// importable content — ingest into Unsorted and place it centred on
    /// `worldPoint` through the shared import-and-place seam (059 · SP3 / SP4).
    /// Returns whether it was handled (`false` = nothing importable). ONE method so
    /// drop + paste can never diverge on how a pasteboard becomes board content.
    /// Write the copied rows' board representation to the general pasteboard (065).
    ///
    /// Appends — the caller has already cleared. An empty selection writes nothing
    /// rather than an empty payload, so a later paste falls through to the branches
    /// below instead of matching a copy that carried nothing.
    /// The WORDS of a copied selection (464) — the flavour an app that takes nothing
    /// but text will read, in the board's own z-order.
    ///
    /// Handed to ``IngestionModel/copyToPasteboard(assets:sourceCollectionID:alsoCopied:text:)``
    /// rather than written here, because it is the WHOLE selection's words and that
    /// method would otherwise derive them from the assets alone: a text box sitting
    /// between two links belongs BETWEEN them, and only this caller holds both halves
    /// in one order.
    ///
    /// What each row contributes:
    ///
    ///  - a **text box** — its string;
    ///  - a **frame** — nothing. `style.text` is a frame's label: furniture that
    ///    names a region, not content the user copied;
    ///  - an **asset** — whatever ``AssetExport/pasteboardEntry(asset:source:blobURL:)``
    ///    calls text, so media are cut out by exactly the rule the byte write uses,
    ///    and the two can never disagree about, say, a link that HAS an og:image
    ///    (a picture — it copies as the picture, and contributes no words).
    ///
    /// Static and pure so the rule is testable without a board, a model or a
    /// pasteboard; `blobURL` is the one thing it cannot know on its own.
    static func copiedText(
        _ details: [SpaceItemDetail], blobURL: (Asset) -> URL?
    ) -> String? {
        CopyText.joined(details.map { detail -> String? in
            guard let asset = detail.asset else {
                guard detail.item.kind == .text else { return nil }
                return detail.item.style.flatMap { ElementStyle(jsonString: $0)?.text }
            }
            return AssetExport.pasteboardEntry(
                asset: asset, source: detail.source, blobURL: blobURL(asset))?.text
        })
    }

    private func copyElementsToPasteboard(_ rows: [SpaceItem]) {
        guard !rows.isEmpty,
              let data = try? SpaceElementPayload(items: rows).pasteboardData() else { return }
        NSPasteboard.general.setData(data, forType: SpaceElementPayload.pasteboardType)
    }

    /// ⌘V onto the board, in strict priority order (065 + 019 · C3). The ORDER is
    /// the design — each branch is more specific than the one below it, and every
    /// lower branch would happily consume a weaker representation of the same copy:
    ///
    /// 1. **A copied piece of a board** — rebuilt with its layout intact. First,
    ///    because our own representation is the most specific thing on the pasteboard
    ///    and the other branches would happily consume a weaker one instead (a copied
    ///    text box also puts its string on the pasteboard as plain text —
    ///    `copyTextToPasteboard`, 464).
    /// 2. **Assets copied elsewhere in the app** (the grid, search, a detail page) —
    ///    PLACED by id, not re-imported. Above the importer for the 019 reason: the
    ///    same copy also carries blob file URLs, and importing those would rebuild
    ///    the asset from its bytes and lose its note, tags and provenance.
    /// 3. **Importable external content** — files, images, URLs — unchanged, so a
    ///    pasted link still becomes a reference.
    /// 4. **Plain text** — a text box. LAST, and that is what keeps it from stealing
    ///    every pasted URL, since a URL is also a string.
    private func pasteOntoBoard(from pasteboard: NSPasteboard, at worldPoint: CGPoint) -> Bool {
        if let payload = SpaceElementPayload.decode(from: pasteboard) {
            space.pasteElements(payload, at: worldPoint)
            return true
        }
        // "nil, not empty" (065 §2.4): an empty payload is not a copy — it must not
        // claim the paste and stop the chain here.
        if let payload = AssetDragPayload.decode(from: pasteboard), !payload.assetIDs.isEmpty {
            space.placeDroppedAssets(ids: payload.assetIDs, at: worldPoint)
            return true
        }
        if importExternal(from: pasteboard, at: worldPoint) { return true }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            space.pasteText(string, at: worldPoint)
            return true
        }
        return false
    }

    private func importExternal(from pasteboard: NSPasteboard, at worldPoint: CGPoint) -> Bool {
        let folder = model.unsortedFolderID
        let inputs = DirectInputReader.inputs(from: pasteboard, into: folder, now: Date())
        let webURL = ImportPasteboard.firstWebURL(on: pasteboard)
        guard case .ingestThenPlace = canvasDropRoute(
            .external(hasImportableType: !inputs.isEmpty || webURL != nil)) else {
            return false
        }
        Task {
            await space.importAndPlace(at: worldPoint) {
                if !inputs.isEmpty { return await model.importInputs(inputs) }
                if let webURL { return await model.importRemoteURL(webURL, into: folder) }
                return []
            }
        }
        return true
    }

    // MARK: - Asset detail overlay

    /// Open the detail page for a double-clicked asset row: bind the tag store to
    /// the asset and raise the overlay.
    private func openAssetDetail(_ detail: SpaceItemDetail) {
        tagStore.bind(to: detail.asset?.id)
        if let id = detail.asset?.id { model.recordView(assetID: id) }
        withAnimation { detailItem = detail }
    }

    /// Build the detail overlay for a Space asset. Reuses the presentation-only
    /// ``ItemDetailView`` with NO prev/next (a board has no ordered set) and NO
    /// folder-scoped remove/delete (the placement — not a membership — is the
    /// unit of removal here, and that's the canvas tile's ⌫).
    @ViewBuilder
    private func spaceDetailOverlay(for detail: SpaceItemDetail) -> some View {
        if let asset = detail.asset {
            let sourceURL = detail.source?.originalURL
            let hasSource = !(sourceURL ?? "").isEmpty
            let hasBlob = model.blobURL(forAsset: asset) != nil
            ItemDetailView(
                asset: asset,
                source: detail.source,
                blobURL: model.blobURL(forAsset: asset),
                previewImage: nil,
                tags: tagStore.tags,
                onAddTag: { tagStore.add($0) },
                onRemoveTag: { tagStore.remove($0) },
                onAcceptTag: { tagStore.accept($0) },
                // A board IS wrapped in `LibrarySearchable` like every other pane, so
                // a color filters there too — and, exactly as typing in the field
                // does, that replaces the board with the results (085 · C2).
                // Searching leaves the board; it does not filter it.
                colors: tagStore.colors,
                onSelectColor: librarySearch?.colorFilterAction(dismissing: {
                    model.flushViewBumps()
                    detailItem = nil
                    tagStore.bind(to: nil)
                }),
                collections: tagStore.collections,
                allCollections: tagStore.allCollections,
                onAddToCollection: { tagStore.addToCollection($0) },
                onRemoveFromCollection: { tagStore.removeFromCollection($0) },
                onSetName: { tagStore.setName($0) },
                onSetNote: { tagStore.setNote($0) },
                actions: ItemDetailActions(
                    openSource: hasSource ? { model.openSourceURL(sourceURL) } : nil,
                    openBlob: hasBlob ? { model.openBlob(asset: asset) } : nil,
                    revealInFinder: hasBlob ? { model.revealInFinder(asset: asset) } : nil,
                    copySourceLink: hasSource ? { model.copySourceLink(url: sourceURL) } : nil,
                    removeFromFolder: nil,
                    requestDelete: nil,
                    // A board has no membership verbs, but the star is a property of
                    // the ASSET (011 · U5) — favoriting from a Space is the same
                    // write, visible in every collection that holds the item.
                    setFavorite: { model.setFavorite($0, assetIDs: [asset.id]) },
                    // 023 · A3 — the same verb the grid menus offer, from the page.
                    setArchived: { model.setArchived($0, assetIDs: [asset.id]) }),
                navigator: nil,
                onClose: {
                    model.flushViewBumps()
                    withAnimation { detailItem = nil }
                    tagStore.bind(to: nil)
                })
        }
    }

    /// A non-blocking hint over the (empty) canvas — the tools stay live, so drawing
    /// the first Frame / Text still works.
    private var emptyHint: some View {
        ContentUnavailableView(
            "This space is empty",
            systemImage: "square.on.square.dashed",
            description: Text(
                "Drag references in from a collection, or draw a Frame / Text with the tools below."))
            .allowsHitTesting(false)
    }
}
