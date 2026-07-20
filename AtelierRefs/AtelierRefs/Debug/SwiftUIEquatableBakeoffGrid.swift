//
//  SwiftUIEquatableBakeoffGrid.swift
//  AtelierRefs
//
//  037 · mode `swiftUIEquatable` — 035 §5 OPTION A, the cheap alternative to the
//  1–2 week `NSCollectionView` rewrite.
//
//  ── The one variable under test ──────────────────────────────────────────
//  This file is a DELIBERATE near-copy of `SwiftUIWindowedBakeoffGrid`. The
//  windowing, the layout cache, the band quantization, the scroll target, the
//  marquee layers, the seeded selection, the cell content and the wrapper chain
//  are all identical, on purpose. The ONLY difference is that the per-cell tree —
//  which the baseline builds inline in a `@ViewBuilder` method — is hoisted here
//  into ``MasonryCellView``, an `Equatable` `View` applied through `.equatable()`.
//
//  Copying rather than sharing a helper is the right call for the cell HOSTING
//  structure: a shared helper parameterised by "equatable or not" would put a
//  branch in the hot path of BOTH modes and neither number would be clean. Two
//  files that differ in exactly one construct isolate exactly one variable.
//
//  That doctrine stops at the cell's LEAVES. The drag preview, the context menu,
//  the selection circle and the seeded selection are defined once, in
//  ``BakeoffCellFidelity`` / ``BakeoffSelection``, and called identically from
//  both files — see the "Shared production-fidelity leaves" note there. Those
//  carry no mode parameter, so they add no branch; duplicating them would instead
//  create a standing risk that one file's menu drifts by a `Button` and the two
//  modes quietly stop being comparable.
//
//  ── Why this is expected to be faster ────────────────────────────────────
//  035 §4 measured the residual as `masonryCell` (763ms) + `ForEachChild.updateValue`
//  (842ms) per 20s: on every band republish SwiftUI re-evaluates the cell closure
//  for EVERY windowed cell (~4 screenfuls, ~100 cells) when only ~8–12 actually
//  entered or left the window. `.equatable()` makes SwiftUI compare the cell's
//  value inputs and SKIP `body` when they are unchanged, so a band crossing costs
//  ~a dozen rebuilds instead of ~a hundred.
//
//  That claim only means something now that `body` is expensive for real. With the
//  stubbed drag preview and one-button menu this mode was skipping a `body` that
//  cost almost nothing, so its advantage over the baseline was itself understated
//  — the fidelity work makes BOTH numbers honest, not just the baseline's.
//
//  ── The whole risk, stated plainly ──────────────────────────────────────
//  035 §5: "every appearance-affecting input MUST be in `==`, or that cell goes
//  stale." An omitted field is not a crash and not a slowdown — it is a cell that
//  silently stops updating. That is why ``MasonryCellView/==`` lists every input
//  BY NAME with a comment saying what it changes on screen, why the action
//  closures are built inside `body` rather than stored (a stored closure would
//  have to be excluded from `==`, and excluding things is exactly how the bug
//  happens), and why `MasonryCellEquatableTests` asserts one-field-at-a-time that
//  each input alone breaks equality.
//

import AtelierCore
import SwiftUI

struct SwiftUIEquatableBakeoffGrid: View {
    let context: GridBakeoffContext

    /// The harness's scroll handle. Held as plain `@State` (a reference that
    /// survives re-inits) and refreshed each body pass — the same discipline the
    /// baseline and `MarqueeCaptureLayer` use.
    @State private var target = SwiftUIScrollPositionTarget()
    /// The programmatic scroll position the driver writes through — the same
    /// mechanism the shipping marquee edge auto-scroll uses.
    @State private var scrollPosition = ScrollPosition()
    /// The same memoized masonry layout the production grid uses, so this mode
    /// pays the production layout cost — no more, no less.
    @State private var masonryCache = MasonryLayoutCache()
    /// The published windowing band (012). Republished only on a band crossing —
    /// the re-materialization 035 §4 blames for the residual, and the exact event
    /// the equatable cell exists to make cheap.
    @State private var window = GridWindow(band: 0, rect: .zero)
    @State private var hoveredItemID: UUID?
    /// The stable hover sink the cells write through (see ``BakeoffHoverSink``).
    @State private var hoverSink = BakeoffHoverSink()
    /// The marquee's per-tick state (009 · N6) — held exactly as `CollectionView`
    /// and the baseline hold it.
    @State private var marquee = GridMarqueeState()
    /// The seeded selection (037 fidelity item 4), identical to the baseline's:
    /// same builder, same items, therefore the same set.
    @State private var selection = BakeoffSelection()

    var body: some View {
        GeometryReader { geo in
            let cols = context.density.columns(forWidth: geo.size.width)
            let layout = masonryCache.frames(
                // The item set is fixed for a bake-off run, so a constant version
                // is correct AND is what the production cache sees during a
                // scroll (items don't change while scrolling).
                version: 0, width: geo.size.width, columns: cols,
                spacing: context.spacing, topInset: context.topInset,
                aspects: { context.items.map { aspect(for: $0) } })
            let viewportHeight = max(geo.size.height, 1)
            let queryRect = window.rect.height > 0
                ? window.rect
                : CGRect(x: 0, y: 0, width: geo.size.width, height: viewportHeight)
            let visible = masonryVisibleIndices(
                in: queryRect, frames: layout.frames, columns: layout.columns,
                overscan: viewportHeight)
            let cells = windowedCells(
                visible: visible, itemCount: context.items.count, frames: layout.frames)
            let contentHeight = max(layout.contentHeight, viewportHeight)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Background capture layer (009 · N6), restored for `.full` —
                    // constructed identically to the baseline's, including the O(N)
                    // `itemIDs` map production rebuilds on every parent pass. This is
                    // the hit-test surface 035 §3 still measures at 385ms/20s after
                    // windowing.
                    if context.wrappers == .full {
                        MarqueeCaptureLayer(
                            state: marquee,
                            itemIDs: context.items.map { $0.item.id },
                            frames: layout.frames,
                            columns: layout.columns,
                            spaceName: BakeoffCellFidelity.marqueeSpace,
                            selectionIDs: selection.selection.ids,
                            onMarquee: { _, _ in },
                            onClear: {},
                            onAutoScroll: { _ in })
                    }
                    ForEach(cells) { cell in
                        let detail = context.items[cell.index]
                        // The selection-derived inputs, resolved through the SAME
                        // shared function the baseline calls — two real lookups plus
                        // the payload query, or the zero value under `.stripped`.
                        let inputs = context.wrappers == .full
                            ? selection.inputs(for: detail)
                            : BakeoffCellInputs()
                        MasonryCellView(
                            detail: detail,
                            frame: cell.frame,
                            url: context.thumbnailURL(detail),
                            gifURL: detail.asset.mimeType == GifMotion.gifMimeType
                                ? context.blobURL(detail) : nil,
                            isSelected: inputs.isSelected,
                            isCursor: inputs.isCursor,
                            isSelecting: inputs.isSelecting,
                            showsCircle: inputs.isSelecting
                                || hoveredItemID == detail.item.id,
                            actionTargets: inputs.actionTargets,
                            moveTargets: BakeoffCellFidelity.moveTargets,
                            wrappers: context.wrappers,
                            hover: hoverSink)
                            // THE one line this whole mode exists to measure.
                            // Without it SwiftUI re-evaluates every windowed cell's
                            // `body` on each band republish; with it, only the cells
                            // whose inputs actually changed.
                            .equatable()
                            .offset(x: cell.frame.minX, y: cell.frame.minY)
                    }
                    // The live marquee rectangle, drawn in the same space.
                    if context.wrappers == .full {
                        MarqueeRectangleLayer(state: marquee)
                    }
                }
                // Explicit content size: with only a window of cells rendered the
                // cells no longer establish the scrollable height — this does.
                // Without it the driver's travel would be a viewport, not the
                // collection.
                .frame(
                    width: geo.size.width, height: contentHeight, alignment: .topLeading)
                .modifier(BakeoffMarqueeSpace(wrappers: context.wrappers))
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, g in
                // The marquee's non-published viewport, fed every tick exactly as
                // production feeds it.
                if context.wrappers == .full {
                    marquee.visibleRect = CGRect(
                        x: g.contentOffset.x, y: g.contentOffset.y,
                        width: g.containerSize.width, height: g.containerSize.height)
                    marquee.contentHeight = g.contentSize.height
                }
                let next = gridWindow(
                    offsetY: g.contentOffset.y,
                    viewportHeight: g.containerSize.height,
                    contentHeight: g.contentSize.height,
                    width: g.containerSize.width,
                    bandHeight: g.containerSize.height)
                if next != window { window = next }
            }
            .onChange(of: window) { _, _ in
                let visibleIDs = Set(cells.map { context.items[$0.index].item.id })
                hoveredItemID = hoverAfterWindowChange(
                    current: hoveredItemID, visibleIDs: visibleIDs)
            }
            // Refresh the target's geometry + scroll closure, then hand it to the
            // harness — registered EXACTLY as the baseline does, so the two modes
            // are driven over identical travel. The hover sink is refreshed on the
            // same edge: its REFERENCE is stable, so a cell that skipped `body`
            // still writes to live state, which is what makes it safe to exclude
            // that reference from `==`.
            .onChange(of: contentHeight, initial: true) { _, height in
                seedSelectionIfNeeded()
                hoverSink.onHoverChanged = { id, hovering in
                    if hovering { hoveredItemID = id }
                    else if hoveredItemID == id { hoveredItemID = nil }
                }
                target.contentHeight = height
                target.viewportHeight = viewportHeight
                target.scrollTo = { scrollPosition.scrollTo(y: $0) }
                context.registerScrollTarget(target)
            }
            .onChange(of: viewportHeight) { _, height in
                target.viewportHeight = height
                target.contentHeight = contentHeight
                target.scrollTo = { scrollPosition.scrollTo(y: $0) }
                context.registerScrollTarget(target)
            }
        }
    }

    /// Seed the deterministic selection once, on the first geometry pass — the
    /// same guard, the same builder, the same edge as the baseline's.
    private func seedSelectionIfNeeded() {
        guard context.wrappers == .full, selection.selectedAssetIDs.isEmpty else { return }
        selection = BakeoffCellFidelity.selection(for: context.items)
    }
}

// MARK: - The hover sink

/// A stable, non-observable handle a cell writes hover crossings through (037).
///
/// The problem it solves is specific to `.equatable()`: the cell must be able to
/// mutate the grid's `hoveredItemID`, but every direct way of handing it that
/// ability breaks equality. A stored closure is not `Equatable` and would have to
/// be excluded from `==` — the exact "excluded field" habit that produces stale
/// cells. A `Binding` is a struct of two closures with the same problem, and a
/// fresh one is built on every parent pass, so it would compare unequal (or be
/// excluded) either way.
///
/// A class reference sidesteps both: the grid holds ONE of these in `@State` for
/// its whole lifetime and refreshes the closure IN PLACE each pass. The reference
/// a cell captured many renders ago still routes to live state, so the cell can
/// exclude it from `==` truthfully — it is a constant, not an omitted input. Same
/// discipline as ``SwiftUIScrollPositionTarget/scrollTo``.
@MainActor
final class BakeoffHoverSink {
    /// Set by the grid to `{ id, hovering in ... }`. Optional so an un-refreshed
    /// sink is a silent no-op rather than a crash.
    var onHoverChanged: (@MainActor (UUID, Bool) -> Void)?
}

// MARK: - The equatable cell (035 §5 Option A)

/// One windowed masonry cell as a self-contained `Equatable` view — the whole of
/// 035 §5 Option A.
///
/// Mirrors `CollectionView.masonryCell` in structure: a `ZStack` of the shared
/// ``CollectionCell`` (sized to its analytic frame, carrying the production
/// `.draggable` / `.dropDestination` / `.contextMenu` chain, with the real drag
/// preview and the real two-`Menu` cell menu inside them) with the production
/// selection circle as a sibling ON TOP, and `.onHover` / `.animation` on the
/// container.
///
/// ── The two rules that make `.equatable()` correct ──────────────────────
///  1. **Every stored property is a VALUE that affects what is drawn**, and every
///     one of them appears in `==`. There is no "excluded for convenience" field.
///  2. **No closure is ever stored.** All of them — the cell's press/click/hover
///     handlers, the drag payload builder, the drop handler, the menu content —
///     are constructed inside `body`, where they cost nothing until `body` runs.
///     This is not a style preference: a stored closure cannot be compared, so it
///     would force an exclusion, and an excluded input is an input that can go
///     stale without anyone noticing. Keeping them in `body` means `==` can be
///     total over the stored state, which is what makes it trustworthy.
///
/// The single exception is ``hover``, a stable reference whose behaviour is
/// refreshed in place by the parent — see ``BakeoffHoverSink`` for why that is a
/// constant rather than an omission.
struct MasonryCellView: View, Equatable {
    /// The item. Only its `item.id` and `asset` are compared (see `==`) — the
    /// `source` is provenance metadata this cell never draws.
    let detail: CollectionItemDetail
    /// The analytic ``MasonryLayout`` frame. Its SIZE is applied here; the caller
    /// applies the origin as an `.offset`. Compared whole regardless, because on a
    /// window resize the origin moves too and a cell that kept a stale frame while
    /// the parent moved it would tear.
    let frame: CGRect
    /// The on-disk 512-tier thumbnail URL (nil for media-less kinds).
    let url: URL?
    /// The original blob URL when this cell is a GIF — drives the hover-animated
    /// overlay.
    let gifURL: URL?
    /// In the selection set — filled check + selection border.
    let isSelected: Bool
    /// The keyboard/detail cursor — focus ring.
    let isCursor: Bool
    /// Selection mode is active anywhere in the grid — circles show on ALL cells.
    let isSelecting: Bool
    /// Whether the selection circle is drawn on THIS cell (`isSelecting` or
    /// hovered, resolved by the parent). Passed as a resolved value rather than
    /// recomputed here so the cell needs no access to the hover state, and so the
    /// `.animation` below has a plain value to key off.
    let showsCircle: Bool
    /// The asset ids a drag or a menu action from this cell carries — production's
    /// `actionTargets(forCellItemID:)` / `dragPayload(forCellItemID:)` result: the
    /// whole selection when this cell is in it, else this cell alone.
    ///
    /// A stored VALUE rather than a closure or a model reference, so it stays inside
    /// `==` (rule 2 above). Comparing it is cheap despite being an array: every
    /// selected cell is handed the SAME copy-on-write buffer the parent caches, so
    /// `Array.==` short-circuits on buffer identity instead of walking hundreds of
    /// UUIDs — the same shape as `IngestionModel.cachedSelectedAssetIDs`.
    let actionTargets: [UUID]
    /// The move/copy destinations the context menu enumerates.
    let moveTargets: MoveTargets
    /// Which wrapper chain to attach (037 §2) — `.full` builds the production
    /// drag/drop/menu/hover trees, `.stripped` builds none.
    let wrappers: GridBakeoffWrapperConfig
    /// Where hover crossings go. A stable reference, deliberately NOT in `==`.
    let hover: BakeoffHoverSink

    /// Value-equality over EVERY appearance-affecting input.
    ///
    /// Read this as the contract: if a change to some input can change a pixel and
    /// it is not on this list, that cell renders stale forever. Each line says what
    /// it drives, and `MasonryCellEquatableTests` has one test per line asserting
    /// that changing it ALONE returns `false`.
    static func == (lhs: MasonryCellView, rhs: MasonryCellView) -> Bool {
        // Identity: a different item is a different picture, a different drag
        // payload, a different menu scope.
        lhs.detail.item.id == rhs.detail.item.id
            // The asset drives the thumbnail itself: kind, mimeType and the
            // dimensions `AssetContentThumbnail` renders from. This is the same
            // field `CollectionCell.==` compares, kept in sync deliberately — the
            // outer cell must never be MORE permissive than the inner one, or the
            // outer would skip a rebuild the inner needed.
            && lhs.detail.asset == rhs.detail.asset
            // Geometry: applied as `.frame(width:height:)` here and as `.offset` by
            // the caller. A zoom / column-count / window-resize changes it.
            && lhs.frame == rhs.frame
            // The thumbnail file. Changes when a tier lands or the blob is replaced;
            // omitting it would freeze cells on their placeholder.
            && lhs.url == rhs.url
            // The animated-GIF source. Nil for non-GIFs; omitting it would leave a
            // GIF cell unable to ever start animating.
            && lhs.gifURL == rhs.gifURL
            // Selection border + filled check — and the circle's checkmark glyph.
            && lhs.isSelected == rhs.isSelected
            // Keyboard-cursor focus ring.
            && lhs.isCursor == rhs.isCursor
            // Circles on all cells while selection mode is active.
            && lhs.isSelecting == rhs.isSelecting
            // This cell's circle specifically (hover or selecting). This is the
            // input a hover changes, so omitting it would break hover entirely —
            // the most visible form of the stale-cell bug.
            && lhs.showsCircle == rhs.showsCircle
            // The drag payload AND the menu's counted verbs ("Delete (34)") and its
            // conditional "Set as Cover" — all three read this list, so a selection
            // that grew from 33 to 34 while this cell stayed selected must rebuild
            // it. Omitting it would ship a drag that carries the wrong items, which
            // is the one stale-cell variant that silently DESTROYS DATA rather than
            // just drawing wrong.
            && lhs.actionTargets == rhs.actionTargets
            // The context menu's contents. Cheap to compare (two small arrays of
            // `Collection`) and it genuinely changes when the folder tree does.
            && lhs.moveTargets == rhs.moveTargets
            // Which branch `body` takes (037 §2). Constant within a run, but a mode
            // switch must rebuild every cell — and an input that "never changes in
            // practice" is precisely the kind that gets omitted and then bites.
            && lhs.wrappers == rhs.wrappers
        // `hover` is intentionally absent: it is a stable reference for the grid's
        // lifetime whose closure the parent refreshes in place, so it cannot differ
        // between two comparable cells. See `BakeoffHoverSink`.
    }

    var body: some View {
        // Every closure below is built HERE, inside `body` — never stored. See the
        // type doc for why that is what makes `==` trustworthy.
        switch wrappers {
        case .stripped:
            // The substrate number (037 §2): no drag, no drop, no menu, no hover,
            // and no selection lookups (the parent hands this branch the zero value).
            CollectionCell(
                detail: detail,
                url: url,
                isSelected: isSelected,
                isCursor: isCursor,
                isSelecting: isSelecting,
                fill: true,
                gifURL: gifURL,
                onImagePress: { _, _ in false },
                onImageClick: { _, _ in },
                onHoverChanged: { _ in })
                .equatable()
                .frame(width: frame.width, height: frame.height)
                .id(detail.item.id)
        case .full:
            ZStack(alignment: .topTrailing) {
                CollectionCell(
                    detail: detail,
                    url: url,
                    isSelected: isSelected,
                    isCursor: isCursor,
                    isSelecting: isSelecting,
                    fill: true,
                    gifURL: gifURL,
                    // Inert, as in the baseline: the harness carries no
                    // `IngestionModel`, and a scroll fires none of these anyway (037
                    // — selection churn is a separate axis).
                    onImagePress: { _, _ in false },
                    onImageClick: { _, _ in },
                    // Hover stays local to the cell (GIF dwell only); circle
                    // visibility is driven by the container's `.onHover` below,
                    // exactly as in production.
                    onHoverChanged: { _ in })
                    .equatable()
                    .frame(width: frame.width, height: frame.height)
                    .draggable(
                        AssetDragPayload(
                            assetIDs: actionTargets,
                            sourceCollectionID: BakeoffCellFidelity.sourceCollectionID)
                    ) {
                        BakeoffCellFidelity.dragPreview(
                            detail: detail, url: url, count: max(actionTargets.count, 1))
                    }
                    .dropDestination(for: AssetDragPayload.self) { _, _ in false }
                    .contextMenu {
                        BakeoffCellFidelity.cellMenu(
                            targetCount: actionTargets.count, destinations: moveTargets)
                    }
                if showsCircle {
                    BakeoffCellFidelity.selectionCircle(isSelected: isSelected)
                        .transition(.opacity)
                }
            }
            .id(detail.item.id)
            .onHover { hovering in
                hover.onHoverChanged?(detail.item.id, hovering)
            }
            .animation(.easeInOut(duration: 0.12), value: showsCircle)
        }
    }
}

// MARK: - Shared stub

/// The stub shown for a mode nobody has implemented yet (037). Registers no
/// scroll target on purpose — an unimplemented mode must be un-runnable, not
/// silently fast. Kept here (it was declared in this file before Option A landed)
/// because `AppKitBakeoffGrid` still renders it while that mode is in progress.
struct BakeoffModePlaceholder: View {
    let mode: GridBakeoffMode
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("\(mode.title) — not implemented")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
