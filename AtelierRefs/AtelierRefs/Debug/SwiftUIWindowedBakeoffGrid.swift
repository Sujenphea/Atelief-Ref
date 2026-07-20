//
//  SwiftUIWindowedBakeoffGrid.swift
//  AtelierRefs
//
//  037 · mode `swiftUIWindowed` — the BASELINE the other two are judged against.
//
//  ── What this is, precisely ──────────────────────────────────────────────
//  A faithful RECONSTRUCTION of the shipping windowed grid, not the shipping
//  view itself. It reuses the production path's real, load-bearing pieces
//  verbatim:
//
//    • `MasonryLayoutCache.frames(...)`      — the same memoized layout
//    • `masonryVisibleIndices` / `windowedCells` — the same windowing filter
//    • `gridWindow(...)`                     — the same band quantization
//    • `CollectionCell` + `.equatable()`     — the same cell, same thumbnails
//    • `MarqueeCaptureLayer` / `MarqueeRectangleLayer` — the same hit-test
//      surface and named coordinate space
//    • the same wrapper chain (`.draggable` / `.dropDestination` /
//      `.contextMenu` / `.onHover`) that 035 §4 identifies as the residual cost,
//      with the REAL `dragPreview` and the REAL two-`Menu` `cellMenu` inside it
//
//  It is a reconstruction because `CollectionView.masonryWindow` and
//  `masonryCell` are PRIVATE methods on `CollectionView`, closing over `model`,
//  `hoveredItemID`, `moveTargetsCache` and a `ScrollViewProxy`. Reusing them
//  literally would require either editing `CollectionView.swift` (owned by
//  another agent — explicitly out of bounds) or instantiating a whole
//  `CollectionView`, which brings its header, toolbar, drop rail and its own
//  `ScrollView` whose `ScrollPosition` the harness cannot reach to drive. See
//  the bake-off report for the exact edit that would make literal reuse
//  possible.
//
//  ── Why the `.full` branch is expensive on purpose (037 §2) ──────────────
//  An earlier revision of this harness STUBBED the expensive per-cell work:
//  `dragPreview` was a 1×1 `Color.clear`, `cellMenu` was one `Button`, the
//  marquee layers were absent, and `isSelected`/`isCursor` were hardwired
//  `false`. Every one of those divergences made the harness CHEAPER than
//  production, and all in the same direction — so a "Smooth" verdict would have
//  been an artifact of the stubs rather than a property of SwiftUI. As built
//  then, the bake-off could honestly REJECT the SwiftUI option but never
//  honestly ACCEPT it, which is backwards: accepting it is what cancels the 1–2
//  week rewrite. `.full` now pays the measured costs (035 §4: `dragPreview`
//  230ms/20s, `cellMenu` 122ms/20s, hit-testing 385ms/20s) for real.
//
//  ── What `.stripped` still is ────────────────────────────────────────────
//  Genuinely stripped, and deliberately UNCHANGED by the fidelity work: no
//  drag, no drop, no menu, no hover, no marquee layers, no coordinate space, no
//  selection lookups. It is the control — the substrate number that is fair to
//  compare against the read-only AppKit spike (037 §2). Restoring production
//  cost into the control would have destroyed the very comparison the wrapper
//  axis exists to make.
//

import AtelierCore
import SwiftUI

struct SwiftUIWindowedBakeoffGrid: View {
    let context: GridBakeoffContext

    /// The harness's scroll handle. Held as plain `@State` (a reference that
    /// survives re-inits) and refreshed each body pass — the same discipline
    /// `MarqueeCaptureLayer` uses for `pump.onTick`.
    @State private var target = SwiftUIScrollPositionTarget()
    /// The programmatic scroll position the driver writes through. This is the
    /// SAME mechanism the shipping marquee edge auto-scroll uses.
    @State private var scrollPosition = ScrollPosition()
    /// The same memoized masonry layout the production grid uses, so the
    /// baseline pays the production layout cost — no more, no less.
    @State private var masonryCache = MasonryLayoutCache()
    /// The published windowing band (012). Republished only on a band crossing,
    /// which is exactly the re-materialization 035 §4 blames for the residual.
    @State private var window = GridWindow(band: 0, rect: .zero)
    @State private var hoveredItemID: UUID?
    /// The marquee's per-tick state (009 · N6) — a class in plain `@State`, held
    /// EXACTLY as `CollectionView` holds it, so the capture layer this grid
    /// installs observes state the same way production's does.
    @State private var marquee = GridMarqueeState()
    /// The seeded selection (037 fidelity item 4). Empty until the first geometry
    /// pass seeds it; under `.stripped` it stays empty forever by design.
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
                    // Background capture layer (009 · N6), restored for `.full`:
                    // a full-content-rect `.contentShape(Rectangle())` plus the
                    // `DisplayLinkHost` NSView. This is the hit-test surface 035
                    // §3 still measures at 385ms/20s AFTER windowing — omitting it
                    // made the harness cheaper than production in exactly the way
                    // that would fake a favourable result.
                    if context.wrappers == .full {
                        MarqueeCaptureLayer(
                            state: marquee,
                            // Production passes `model.items.map { $0.item.id }` —
                            // an O(N) array built on every parent body pass. Built
                            // the same way here on purpose; it is real cost.
                            itemIDs: context.items.map { $0.item.id },
                            frames: layout.frames,
                            columns: layout.columns,
                            spaceName: BakeoffCellFidelity.marqueeSpace,
                            selectionIDs: selection.selection.ids,
                            // Inert: the harness carries no `IngestionModel`, and a
                            // programmatic scroll fires no marquee. The COST being
                            // measured is the layer's hit-test surface, not its
                            // callbacks.
                            onMarquee: { _, _ in },
                            onClear: {},
                            onAutoScroll: { _ in })
                    }
                    ForEach(cells) { cell in
                        cellView(context.items[cell.index], frame: cell.frame)
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
            // Refresh the target's geometry + scroll closure every pass, then
            // hand it to the harness. `scrollTo` mutates `@State` through its
            // stable storage box, so a closure captured one render ago still
            // drives the live scroll view.
            .onChange(of: contentHeight, initial: true) { _, height in
                seedSelectionIfNeeded()
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

    /// Seed the deterministic selection once, on the first geometry pass.
    ///
    /// Not seeded in `init`: the seam constructs this view positionally on every
    /// parent body pass, and an O(N) walk of 2000 items in `init` would be a cost
    /// production never pays. `.stripped` is left empty — it is the read-only
    /// control (037 §2).
    private func seedSelectionIfNeeded() {
        guard context.wrappers == .full, selection.selectedAssetIDs.isEmpty else { return }
        selection = BakeoffCellFidelity.selection(for: context.items)
    }

    /// One windowed cell.
    ///
    /// Under `.full` it carries the production wrapper chain — the `.draggable`
    /// (with the real `dragPreview`) / `.dropDestination` / `.contextMenu` (with
    /// the real two-`Menu` `cellMenu`) / `.onHover` / `.animation` trees that 035
    /// §4 measures as the band-crossing rebuild cost — plus the real per-cell
    /// selection lookups and the production selection circle. The action closures
    /// are inert (there is no model here), but every TREE is constructed, which is
    /// where the cost lives.
    ///
    /// Under `.stripped` it carries none of them — the substrate number that is
    /// fair to compare against the read-only AppKit spike (037 §2).
    @ViewBuilder
    private func cellView(_ detail: CollectionItemDetail, frame: CGRect) -> some View {
        switch context.wrappers {
        case .stripped:
            CollectionCell(
                detail: detail,
                url: context.thumbnailURL(detail),
                isSelected: false,
                isCursor: false,
                isSelecting: false,
                fill: true,
                gifURL: detail.asset.mimeType == GifMotion.gifMimeType
                    ? context.blobURL(detail) : nil,
                onImagePress: { _, _ in false },
                onImageClick: { _, _ in },
                onHoverChanged: { _ in })
                .equatable()
                .frame(width: frame.width, height: frame.height)
                .id(detail.item.id)
        case .full:
            // Two REAL selection lookups per cell, exactly as `masonryCell` does:
            // a `Set.contains` and a `lead` comparison. Production pays these on
            // every cell build; hardwiring them to `false` made the harness cheaper
            // AND made `isSelecting` permanently false, which suppressed the
            // selection circle on every cell.
            //
            // `inputs` also resolves the model-shaped per-cell payload query
            // (`dragPayload(forCellItemID:)` / `actionTargets(forCellItemID:)`): the
            // WHOLE selection when this cell is part of it, else this cell alone.
            let inputs = selection.inputs(for: detail)
            let showsCircle = inputs.isSelecting || hoveredItemID == detail.item.id
            let targets = inputs.actionTargets
            ZStack(alignment: .topTrailing) {
                CollectionCell(
                    detail: detail,
                    url: context.thumbnailURL(detail),
                    isSelected: inputs.isSelected,
                    isCursor: inputs.isCursor,
                    isSelecting: inputs.isSelecting,
                    fill: true,
                    gifURL: detail.asset.mimeType == GifMotion.gifMimeType
                        ? context.blobURL(detail) : nil,
                    onImagePress: { _, _ in false },
                    onImageClick: { _, _ in },
                    onHoverChanged: { _ in })
                    .equatable()
                    .frame(width: frame.width, height: frame.height)
                    .draggable(
                        AssetDragPayload(
                            assetIDs: targets,
                            sourceCollectionID: BakeoffCellFidelity.sourceCollectionID)
                    ) {
                        BakeoffCellFidelity.dragPreview(
                            detail: detail,
                            url: context.thumbnailURL(detail),
                            count: max(targets.count, 1))
                    }
                    .dropDestination(for: AssetDragPayload.self) { _, _ in false }
                    .contextMenu {
                        BakeoffCellFidelity.cellMenu(
                            targetCount: targets.count,
                            destinations: BakeoffCellFidelity.moveTargets)
                    }
                if showsCircle {
                    BakeoffCellFidelity.selectionCircle(isSelected: inputs.isSelected)
                        .transition(.opacity)
                }
            }
            .id(detail.item.id)
            .onHover { hovering in
                if hovering { hoveredItemID = detail.item.id }
                else if hoveredItemID == detail.item.id { hoveredItemID = nil }
            }
            .animation(.easeInOut(duration: 0.12), value: showsCircle)
        }
    }
}

// MARK: - The named content space

/// Installs the grid's named coordinate space — but only under `.full` (037 §2).
///
/// A `ViewModifier` rather than an inline `if`, because `.coordinateSpace(name:)`
/// has to be applied to the sized content frame and a conditional modifier at that
/// position is otherwise unexpressible. Under `.stripped` the space is genuinely
/// absent: a named space is a real registration the layout system maintains, and
/// leaving it in would contaminate the control.
struct BakeoffMarqueeSpace: ViewModifier {
    let wrappers: GridBakeoffWrapperConfig

    @ViewBuilder
    func body(content: Content) -> some View {
        switch wrappers {
        case .full: content.coordinateSpace(name: BakeoffCellFidelity.marqueeSpace)
        case .stripped: content
        }
    }
}

// MARK: - The seeded selection

/// A deterministic stand-in for `IngestionModel`'s selection state (037 fidelity
/// item 4).
///
/// Production's `masonryCell` performs two real lookups per cell — a `Set.contains`
/// for `isSelected` and a `lead` comparison for `isCursor` — and its menu/drag
/// payload resolve through `actionTargets(forCellItemID:)`. Hardwiring those to
/// `false`/`[]` biased the harness cheaper in four places at once, and, worse,
/// forced `isSelecting` false so the selection circle never rendered on any cell.
///
/// The important structural detail is ``selectedAssetIDs``: `IngestionModel` keeps
/// this list CACHED (`rebuildSelectedAssetIDs`), so a per-cell payload query is an
/// O(1) copy of a shared, copy-on-write buffer — not an O(N) filter. Recomputing it
/// per cell here would have biased the harness HEAVIER than production, which is
/// the same kind of error in the other direction.
struct BakeoffSelection {
    /// The selection value, shaped exactly like the production ``GridSelection``.
    var selection = GridSelection()
    /// The selected assets in feed order — the cached array `IngestionModel`
    /// maintains, and the one every selected cell's drag payload shares.
    var selectedAssetIDs: [UUID] = []

    /// `IngestionModel.actionTargets(forCellItemID:)`, same scope rule: a cell
    /// inside the selection acts on the WHOLE selection, an unselected cell acts on
    /// itself. Returns the shared cached buffer in the selected case, so `==` on two
    /// such arrays hits Swift's identical-buffer fast path rather than comparing
    /// hundreds of UUIDs.
    func actionTargets(for detail: CollectionItemDetail) -> [UUID] {
        if selection.ids.contains(detail.item.id) { return selectedAssetIDs }
        return [detail.asset.id]
    }

    /// Every selection-derived input one cell needs, resolved in ONE place.
    ///
    /// Both modes call this with the same seeded selection and the same detail, so
    /// the four values can't drift between them — the alternative (each mode
    /// recomputing `contains`/`lead`/`isSelecting` inline) is four chances for the
    /// two files to disagree, which would silently stop the bake-off isolating the
    /// `.equatable()` variable.
    func inputs(for detail: CollectionItemDetail) -> BakeoffCellInputs {
        BakeoffCellInputs(
            isSelected: selection.ids.contains(detail.item.id),
            isCursor: selection.lead == detail.item.id,
            isSelecting: selection.isSelecting,
            actionTargets: actionTargets(for: detail))
    }
}

/// The selection-derived inputs to one cell. The `.stripped` control uses the
/// zero value — no lookups, nothing selected — which is what makes it comparable
/// to the read-only AppKit spike (037 §2).
struct BakeoffCellInputs {
    var isSelected = false
    var isCursor = false
    var isSelecting = false
    /// The asset ids a drag or a menu action from this cell would carry — the whole
    /// selection when this cell is in it, else this cell alone.
    var actionTargets: [UUID] = []
}

// MARK: - Shared production-fidelity leaves

/// The per-cell leaves both SwiftUI modes build, defined ONCE (037).
///
/// ── Why these are shared rather than copied ──────────────────────────────
/// The two SwiftUI modes are deliberate near-copies so that they differ in exactly
/// one construct: the `Equatable` cell. That doctrine applies to the cell HOSTING
/// structure — the thing under test. It does NOT apply to the leaf content, where
/// duplication would be a liability: a drag preview or a menu that drifted by one
/// `Button` between the two files would silently make the modes incomparable, and
/// nothing would catch it. Sharing these makes identity a compile-time fact instead
/// of a review promise, and it introduces no branch into either mode's hot path
/// (there is no "equatable or not" parameter here — both modes call the same
/// functions with the same arguments).
@MainActor
enum BakeoffCellFidelity {
    /// The grid's named content space (`CollectionView.marqueeSpace`).
    static let marqueeSpace = "bakeoffGridContent"

    /// The drag payload's source collection. Production reads
    /// `model.selectedFolderID`; a fixed constant is the faithful equivalent, and it
    /// replaces the previous `UUID()` — which minted a fresh random UUID per cell
    /// per build, a cost production does not pay.
    static let sourceCollectionID = UUID(
        uuidString: "00000000-0000-0000-0000-0000BA0EF000")!

    /// How many move/copy destinations the context menu enumerates.
    ///
    /// **4, chosen to match the measured production library.** The user's real
    /// library has 4 collections, so a cell menu there enumerates ~4 destinations
    /// per `Menu` — twice, once for "Move to" and once for "Add to". The Bakeoff
    /// library has no comparable folder tree, so they are synthesised here.
    ///
    /// Menu cost scales LINEARLY in this number and it is paid TWICE per cell (both
    /// submenus enumerate the same list), so a user with 40 folders pays ~10× the
    /// `cellMenu` component — on 035 §4's 122ms/20s baseline, order 1.2s/20s. If the
    /// bake-off verdict lands near a threshold, re-run with this raised to the
    /// largest library that must stay smooth before trusting the margin.
    static let destinationCount = 4

    /// Fraction of items pre-selected: every Nth item (037 fidelity item 4 —
    /// "a scattered ~10%, deterministic, no randomness"). A stride rather than a
    /// contiguous block on purpose: a contiguous selection would leave most
    /// screenfuls entirely unselected and most cells on the cheap `actionTargets`
    /// path, understating the cost.
    static let selectionStride = 10

    /// Build the deterministic selection for a run's items. Identical items in →
    /// identical selection out, so both modes are seeded the same by construction.
    static func selection(for items: [CollectionItemDetail]) -> BakeoffSelection {
        var ids = Set<UUID>()
        var assetIDs: [UUID] = []
        for (i, detail) in items.enumerated() where i % selectionStride == 0 {
            ids.insert(detail.item.id)
            assetIDs.append(detail.asset.id)
        }
        var sel = GridSelection()
        sel.ids = ids
        // The keyboard cursor sits on the first selected cell — production always
        // has a `lead` once anything is selected, and `isCursor` must be true for
        // exactly one visible cell rather than none.
        sel.lead = items.first(where: { ids.contains($0.item.id) })?.item.id
        sel.anchor = sel.lead
        return BakeoffSelection(selection: sel, selectedAssetIDs: assetIDs)
    }

    /// The synthetic move/copy destinations, shaped like a real ``MoveTargets``.
    ///
    /// Split as 1 subfolder + the rest roots so BOTH `ForEach` branches of
    /// production's `targetButtons` are exercised and the divider between them
    /// actually renders — a menu built entirely from one branch would skip tree
    /// nodes production builds.
    static let moveTargets: MoveTargets = {
        let epoch = Date(timeIntervalSince1970: 0)
        let parent = UUID(uuidString: "00000000-0000-0000-0000-0000BA0EF001")!
        func folder(_ i: Int, parentID: UUID?) -> Collection {
            // Deterministic, index-derived ids: no randomness anywhere in the
            // harness, so two runs build byte-identical menus.
            let id = UUID(uuidString: String(
                format: "00000000-0000-0000-0000-0000BA0E1%03d", i))!
            return Collection(
                id: id, name: "Destination \(i)", description: nil, coverAssetID: nil,
                createdAt: epoch, updatedAt: epoch, parentCollectionID: parentID)
        }
        let subfolderCount = destinationCount >= 2 ? 1 : 0
        let subfolders = (0..<subfolderCount).map { folder($0, parentID: parent) }
        let roots = (subfolderCount..<destinationCount).map { folder($0, parentID: nil) }
        return MoveTargets(subfolders: subfolders, roots: roots)
    }()

    /// The drag image — production's `CollectionView.dragPreview(for:)` verbatim:
    /// a real `AssetContentThumbnail` at 84×84 with the count badge when more than
    /// one item travels.
    ///
    /// This is the single largest restored cost: 035 §4 measured it at 230ms/20s.
    /// The previous `Color.clear.frame(width: 1, height: 1)` skipped an entire
    /// thumbnail view (and, for a byte kind, an `AsyncThumbnail` cache lookup) per
    /// cell per build.
    @ViewBuilder
    static func dragPreview(
        detail: CollectionItemDetail, url: URL?, count: Int
    ) -> some View {
        AssetContentThumbnail(asset: detail.asset, url: url)
            .frame(width: 84, height: 84)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.caption2).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(4)
                }
            }
    }

    /// The context menu — production's `CollectionView.cellMenu(for:)` structure:
    /// two `Menu`s each enumerating every destination, the conditional "Set as
    /// Cover", a `Divider`, and the two counted destructive verbs.
    ///
    /// 035 §4 measured this at 122ms/20s. The previous single `Button("Placeholder")`
    /// omitted two `Menu` containers, two `ForEach`s over destinations, an inner
    /// divider each, and four buttons — the bulk of the tree.
    @ViewBuilder
    static func cellMenu(targetCount n: Int, destinations: MoveTargets) -> some View {
        Menu("Move to") { targetButtons(destinations) }
        Menu("Add to") { targetButtons(destinations) }
        if n == 1 {
            Button("Set as Cover") {}
        }
        Divider()
        Button("Remove from Collection\(countSuffix(n))") {}
        Button("Delete\(countSuffix(n))", role: .destructive) {}
    }

    /// A Move-to / Add-to submenu: subfolders first, a divider, then roots — the
    /// same shape as `CollectionView.targetButtons`. The actions are inert (no
    /// model); the TREE is what is measured.
    @ViewBuilder
    static func targetButtons(_ dests: MoveTargets) -> some View {
        ForEach(dests.subfolders) { c in Button(c.name) {} }
        if !dests.subfolders.isEmpty && !dests.roots.isEmpty { Divider() }
        ForEach(dests.roots) { c in Button(c.name) {} }
    }

    /// " (N)" for a multi-item action — `CollectionView.countSuffix`.
    static func countSuffix(_ n: Int) -> String { n > 1 ? " (\(n))" : "" }

    /// The hover/selection circle — production's `selectionCircle(for:)`.
    ///
    /// It matters that this is the real one: with a non-empty seeded selection
    /// `isSelecting` is true, so production draws this on EVERY visible cell, not
    /// just the hovered one. The previous `Circle().fill(.thinMaterial)` was both a
    /// cheaper tree and (with selection hardwired off) drawn on at most one cell.
    static func selectionCircle(isSelected: Bool) -> some View {
        Button {} label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? Color.white : Color.white.opacity(0.95),
                    isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.15)).padding(1))
                .padding(6)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Deselect" : "Select")
        .accessibilityHidden(true)
    }
}
