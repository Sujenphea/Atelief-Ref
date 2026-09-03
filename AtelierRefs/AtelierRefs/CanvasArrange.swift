//
//  CanvasArrange.swift
//  AtelierRefs
//
//  051 Phase 1 — the pure geometry kernel behind Figma-style alignment (6) and
//  distribution (2) over a multi-selection. Deliberately identity-agnostic
//  ([5A]): it speaks only `[CGRect] → [CGRect]`, so it structurally cannot touch
//  a row's id or z — the model maps live rects in, calls one entry point, and
//  zips the results back to the selected ids by index. Keeping this out of
//  `SpaceLayout` (which owns flow-in) leaves both single-purpose and this one
//  testable in isolation ([1A]). No renderer / model coupling, no viewport data.
//

import CoreGraphics

/// Pure alignment + distribution over a set of world-space rects. One enum-driven
/// op ([E-3]): every case carries its undo action name + `minimumCount`, and a
/// single `apply(_:to:)` entry dispatches. Aligns to the selection bounding box
/// (Figma default, [3A]); distributes with equal gaps (Figma "distribute
/// spacing", [6A]).
enum CanvasArrange {

    /// The eleven arrange operations: 6 aligns + 2 distributes + tidy + reflow + grid.
    /// `allCases` drives the table-driven kernel tests and the bar's op wiring, so a
    /// new op is added in exactly one place.
    enum Operation: CaseIterable {
        // Aligns (bounding box): need ≥2 to be meaningful.
        case alignLeft, alignHorizontalCenter, alignRight
        case alignTop, alignVerticalCenter, alignBottom
        // Distributes (equal gaps): need ≥3 (two items have no interior gap).
        case distributeHorizontal, distributeVertical
        // Tidy up (066): snap the selection into clean rows at a uniform gap.
        case tidyUp
        // Reflow into grid: repack the selection the way a bulk add flows it in —
        // one of the two ops that resize (see ``reflowGrid(_:)``).
        case reflowGrid
        // A TRUE uniform grid (076's T3, 099 · P12): one cell size for every tile,
        // aspect discarded. The other resizing op — see ``uniformGrid(_:gap:)``.
        case arrangeGrid

        /// The undo action name shown in the ⌘Z menu — carried by the op so the
        /// model doesn't scatter string literals.
        var actionName: String {
            switch self {
            case .alignLeft: "Align Left"
            case .alignHorizontalCenter: "Align Horizontal Centers"
            case .alignRight: "Align Right"
            case .alignTop: "Align Top"
            case .alignVerticalCenter: "Align Vertical Centers"
            case .alignBottom: "Align Bottom"
            case .distributeHorizontal: "Distribute Horizontally"
            case .distributeVertical: "Distribute Vertically"
            case .tidyUp: "Tidy Up"
            case .reflowGrid: "Reflow Into Grid"
            case .arrangeGrid: "Arrange Into Grid"
            }
        }

        /// Minimum selection size for the op to do anything: align 2, distribute 3
        /// ([3A]). The bar's enablement predicates read this instead of literals
        /// ([E-3]); `apply(_:to:)` guards on it so degenerate input is a no-op.
        var minimumCount: Int {
            switch self {
            case .distributeHorizontal, .distributeVertical: 3
            default: 2
            }
        }

        /// Whether this op distributes (vs aligns) — used only by the bar's
        /// grouping; the kernel dispatches on the case itself.
        var isDistribute: Bool {
            switch self {
            case .distributeHorizontal, .distributeVertical: true
            default: false
            }
        }
    }

    /// Apply `op` to `rects`, returning a new index-aligned array (the caller zips
    /// results back to ids by index). Pure: for every op but two, sizes are preserved
    /// and only the relevant origin coordinate moves. ``Operation/reflowGrid`` and
    /// ``Operation/arrangeGrid`` are the exceptions and resize deliberately — see
    /// ``reflowGrid(_:)`` and ``uniformGrid(_:gap:)`` — so callers must
    /// carry the returned `size` through, not just the origin. Below
    /// `op.minimumCount` it returns `rects` unchanged, so callers can invoke it
    /// safely on any selection.
    static func apply(_ op: Operation, to rects: [CGRect]) -> [CGRect] {
        guard rects.count >= op.minimumCount else { return rects }
        switch op {
        case .alignLeft:
            return align(rects) { box, r in CGPoint(x: box.minX, y: r.minY) }
        case .alignHorizontalCenter:
            return align(rects) { box, r in CGPoint(x: box.midX - r.width / 2, y: r.minY) }
        case .alignRight:
            return align(rects) { box, r in CGPoint(x: box.maxX - r.width, y: r.minY) }
        case .alignTop:
            return align(rects) { box, r in CGPoint(x: r.minX, y: box.minY) }
        case .alignVerticalCenter:
            return align(rects) { box, r in CGPoint(x: r.minX, y: box.midY - r.height / 2) }
        case .alignBottom:
            return align(rects) { box, r in CGPoint(x: r.minX, y: box.maxY - r.height) }
        case .distributeHorizontal:
            return distribute(rects, axis: .horizontal)
        case .distributeVertical:
            return distribute(rects, axis: .vertical)
        case .tidyUp:
            return tidy(rects)
        case .reflowGrid:
            return reflowGrid(rects)
        case .arrangeGrid:
            return uniformGrid(rects, gap: gridSpacing)
        }
    }

    // MARK: - Tidy up (066)

    /// Snap a messy selection into clean rows at one uniform gap — Figma's ⌃⌥⌘T.
    ///
    /// One algorithm covers a row, a column and a grid, because all three ARE the same
    /// thing: cluster the rects into rows by vertical overlap, then lay each row out
    /// left-to-right. Everything in one cluster is a row; one item per cluster is a
    /// column; anything else is a grid. No mode to infer, so no mode to infer wrongly.
    ///
    /// **Idempotence is the design constraint, not a nice property.** `allCases` is
    /// tested for "re-applying changes nothing", and it is also what the user expects —
    /// clicking Tidy Up twice must not creep. Every rule below is chosen to survive its
    /// own output:
    ///
    /// - the anchor is the selection's top-left, which does not move, so the box is
    ///   unchanged and a second pass starts from the same place;
    /// - rows are clustered on STRICT overlap, so rows laid out `gap` apart (even
    ///   `gap == 0`, where they merely touch) re-cluster identically;
    /// - the gap is the SMALLEST observed gap, and after a pass every gap is exactly
    ///   that, so re-deriving it returns the same number;
    /// - items in a row share a top edge afterwards, which is total overlap, so they
    ///   re-cluster into the same row.
    ///
    /// A cluster is not automatically a laid-out row: it wraps at ``tidyMaxRowWidth(_:)``
    /// (028). Without that bound a row ran until its members ran out, so 60 tiles came
    /// out as one row ~24,000pt wide — off-screen at any usable zoom, and the shape the
    /// bug report described. The wrap re-uses the same `gap` and the same top-left
    /// anchor, so a wrapped row is indistinguishable from a clustered one on the way
    /// back in: pass two sees the wrapped rows AS clusters and lays them out where they
    /// already are.
    private static func tidy(_ rects: [CGRect]) -> [CGRect] {
        let rows = tidyRows(rects)
        let gap = tidyGap(rects, rows: rows)
        let box = boundingBox(rects)
        let maxWidth = tidyMaxRowWidth(rects)

        var result = rects
        var y = box.minY
        for row in rows {
            var x = box.minX
            var rowHeight: CGFloat = 0
            var rowIsEmpty = true
            for index in row {
                let size = rects[index].size
                // Wrap when this item would push the row past the bound — but never
                // when the row is still empty. A selection mixing a huge frame with
                // small tiles has items wider than the bound on their own, and a row
                // that can refuse every item is a loop that never terminates. Such an
                // item lands alone on its row and overhangs, which is the honest
                // result: tidy moves tiles, it does not resize them.
                if !rowIsEmpty, x + size.width > box.minX + maxWidth {
                    x = box.minX
                    y += rowHeight + gap
                    rowHeight = 0
                    rowIsEmpty = true
                }
                result[index] = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + gap
                rowHeight = max(rowHeight, size.height)
                rowIsEmpty = false
            }
            y += rowHeight + gap
        }
        return result
    }

    /// How wide a tidied row may get before it wraps, in world units (028).
    ///
    /// Derived from the rects' own total AREA — `sqrt(totalArea × 16:9)` — and
    /// deliberately NOT from the selection's bounding box. The box is the obvious
    /// source and the wrong one: it NARROWS the moment a wrap happens, so a
    /// box-derived bound comes back smaller on the next pass and the layout creeps
    /// narrower on every press. Total area is invariant under tidy — sizes are
    /// preserved and the array order with them, so the sum is not merely equal but
    /// bit-identical — which makes idempotence structural here rather than something
    /// to hope for.
    ///
    /// The target aspect is a fixed 16:9, not the viewport's: the same selection must
    /// tidy the same way in a resized window.
    ///
    /// Quantised to ``tidyBoundQuantum`` so the wrap decision cannot ride on the last
    /// bits of a square root. The quantum is coarse (100pt, a quarter of a typical
    /// tile) precisely so that no realistic selection lands near a quantum boundary,
    /// where a hair of drift could move a tile between rows.
    ///
    /// ``fallbackMaxRowWidth`` is a FLOOR, not just a guard for the degenerate case.
    /// Below it the derived bound would wrap selections that tidy already handles
    /// correctly — three tiles in a row, a 2×2 grid — because `sqrt(area × 16:9)` for
    /// a handful of tiles is narrower than the row they form. Flooring it keeps small
    /// selections behaving exactly as they do today and confines the wrap to the
    /// many-item case, which is where the bug lives. It also covers a zero-area
    /// selection (every rect degenerate) with no division and no square root of zero.
    static func tidyMaxRowWidth(_ rects: [CGRect]) -> CGFloat {
        let area = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        guard area > 0 else { return fallbackMaxRowWidth }
        let ideal = (area * tidyTargetAspect).squareRoot()
        let quantised = (ideal / tidyBoundQuantum).rounded(.down) * tidyBoundQuantum
        return max(fallbackMaxRowWidth, quantised)
    }

    /// Aspect (w/h) of the block a tidy aims to fill. Fixed at 16:9 — see
    /// ``tidyMaxRowWidth(_:)`` for why it is not the viewport's.
    static let tidyTargetAspect: CGFloat = 16.0 / 9.0

    /// Rounding step for the derived wrap bound, world units.
    static let tidyBoundQuantum: CGFloat = 100

    /// Floor for the wrap bound — a mirror of `SpaceLayout.maxRowWidth`.
    ///
    /// Mirrored rather than read from `SpaceLayout` so this file stays the
    /// `[CGRect] → [CGRect]` island its header describes, with no dependency on the
    /// space layer. `CanvasTidyPackTests` asserts the two numbers agree, so the copy
    /// cannot drift silently.
    ///
    /// 1600 is BORROWED, not derived: `SpaceLayout` picked it for flowing 240-high
    /// rows on bulk add. As a floor for tidy it is arbitrary — it is here because it
    /// is the row width the rest of the app already wraps at, and inventing a second
    /// number would be worse than reusing an imperfect one.
    static let fallbackMaxRowWidth: CGFloat = 1600

    /// Cluster indices into rows by vertical overlap — top-to-bottom, each row ordered
    /// left-to-right. Ties break on the original index so the result is deterministic.
    ///
    /// A rect joins the open row when it starts ABOVE the row's BAND. Strictly above: a
    /// rect starting exactly at the band's bottom is touching, not overlapping, and must
    /// begin a new row — that is what makes a `gap == 0` tidy stable.
    ///
    /// The band is anchored at the row's top and reaches down by the tallest member's
    /// height. It is emphatically NOT the running maximum of the members' bottom edges,
    /// which is what this used to be (028): that bottom drifts down with every member's
    /// POSITION, so membership became *transitive* overlap — A overlaps B, B overlaps C,
    /// C overlaps D, and A and D end up in one row sharing no vertical extent at all. A
    /// staircase chained end to end, and a bulk drop (tiles at slightly different y) is
    /// exactly that chain, which is how 60 tiles became one row.
    ///
    /// Anchoring at the row's top bounds the chain by construction: the band can never
    /// reach past `rowTop + tallestMemberHeight`, however many members join. Taking the
    /// tallest member's height rather than only the FIRST member's extent is the one
    /// concession — a row whose leftmost tile happens to be short still admits the tall
    /// tiles beside it, which is what keeps a ragged row of mixed heights reading as one
    /// row. The row's median was the other candidate and was rejected: the median moves
    /// as members are added, so a shallow staircase still creeps in one tile at a time —
    /// bounded in practice rather than bounded by construction.
    ///
    /// Idempotent, which is the whole constraint: after a pass a row's members all share
    /// its top edge (so each one's `minY` sits strictly inside the band), and the next
    /// row starts at `rowTop + tallestHeight + gap`, which is at or below the band's
    /// bottom — never inside it, even at `gap == 0`.
    private static func tidyRows(_ rects: [CGRect]) -> [[Int]] {
        let topDown = rects.indices.sorted { a, b in
            let (ra, rb) = (rects[a], rects[b])
            if ra.minY != rb.minY { return ra.minY < rb.minY }
            if ra.minX != rb.minX { return ra.minX < rb.minX }
            return a < b
        }
        var rows: [[Int]] = []
        var rowTop: CGFloat = 0       // where the open row's band starts…
        var bandHeight: CGFloat = 0   // …and how far down it reaches
        for index in topDown {
            let rect = rects[index]
            if !rows.isEmpty, rect.minY < rowTop + bandHeight {
                rows[rows.count - 1].append(index)
                bandHeight = max(bandHeight, rect.height)
            } else {
                rows.append([index])
                rowTop = rect.minY
                bandHeight = rect.height
            }
        }
        return rows.map { row in
            row.sorted { a, b in
                rects[a].minX == rects[b].minX ? a < b : rects[a].minX < rects[b].minX
            }
        }
    }

    /// The gap a tidy should use: the smallest gap the user already has.
    ///
    /// Smallest rather than average or largest because it is the only choice that is
    /// stable under its own output (after a pass every gap equals it) AND never makes a
    /// layout bigger than the user built. Overlaps contribute negative gaps and are
    /// ignored; a selection with no measurable gap at all falls back to
    /// ``defaultTidyGap`` rather than collapsing everything onto one point.
    private static func tidyGap(_ rects: [CGRect], rows: [[Int]]) -> CGFloat {
        var gaps: [CGFloat] = []
        for row in rows {
            for (a, b) in zip(row, row.dropFirst()) {
                gaps.append(rects[b].minX - rects[a].maxX)
            }
        }
        for (above, below) in zip(rows, rows.dropFirst()) {
            let bottom = above.map { rects[$0].maxY }.max() ?? 0
            let top = below.map { rects[$0].minY }.min() ?? 0
            gaps.append(top - bottom)
        }
        return gaps.filter { $0 >= 0 }.min() ?? defaultTidyGap
    }

    /// The spacing a tidy falls back to when the selection has no measurable gap —
    /// everything overlapping, or a single row of one. World units.
    static let defaultTidyGap: CGFloat = 20

    // MARK: - Reflow into grid

    /// Repack the selection the way a BULK ADD lays tiles in: every tile normalised to
    /// one row height, flowed left-to-right into justified rows.
    ///
    /// The sibling of ``tidy(_:)``, and deliberately the opposite bargain. Tidy PRESERVES
    /// your arrangement and cleans it up — sizes untouched, clusters kept, your own gap
    /// re-used — which is why it can never give you rows that line up along their bottom
    /// edge. Reflow DISCARDS the arrangement and keeps only the reading order: the shape
    /// goes, the sequence stays. It is the only op in this file that resizes, and the
    /// caller has to persist width and height, not just the origin.
    ///
    /// Each decision, and the alternative it beat:
    ///
    /// - **Order comes from `tidyRows(rects).flatMap { $0 }`** — top-to-bottom, then
    ///   left-to-right, the same clustering tidy reads. Array order was the other
    ///   candidate and is wrong: a selection arrives from a `Set`, so array order is not
    ///   the order anything is on screen. Reading order is what the user built.
    /// - **A uniform ``gridRowHeight``, aspect preserved per tile.** Cropping to a square
    ///   cell would make the block rectangular at the cost of lying about the picture;
    ///   fixing a row height and letting width follow is what `SpaceLayout.flowIn`
    ///   already does on add, so a reflowed board and a freshly-added one look alike.
    /// - **The wrap bound is derived from the RESIZED rects, not the input.**
    ///   ``tidyMaxRowWidth(_:)`` reads total area, and the resize changes total area. Feed
    ///   it the originals and pass two (whose input IS the resized set) sees a different
    ///   area, gets a different bound, and lays out a different number of rows —
    ///   idempotence gone. This one line is the correctness crux.
    /// - **A fixed ``gridSpacing``, not `tidyGap`.** Once every tile is a different size
    ///   from the one the user placed, the gaps they left describe a layout that no longer
    ///   exists; deriving from them would carry a measurement of the discarded shape into
    ///   the new one.
    ///
    /// Idempotent, like tidy, and for reasons that compose: after one pass every tile is
    /// exactly `gridRowHeight` high, so the resize on pass two is the identity (a tile's
    /// aspect is now `width / gridRowHeight`, and `gridRowHeight × that` is the width it
    /// already has); total area is therefore unchanged, so the bound is unchanged; and
    /// `tidyRows` over the output re-clusters exactly the rows just laid out — every
    /// member of a row shares its top edge and the band is `gridRowHeight` tall, while the
    /// next row starts at `+ gridRowHeight + gridSpacing`, strictly outside it. Same
    /// order, same bound, same output.
    ///
    /// Anchored on the INPUT selection's top-left, so the block repacks where it already
    /// sits rather than jumping across the canvas. The wrap never fires on an empty row,
    /// for tidy's reason: a tile wider than the bound (a 32:9 panorama, say) lands alone
    /// and overhangs, because a row that can refuse every item is a loop that never ends.
    private static func reflowGrid(_ rects: [CGRect]) -> [CGRect] {
        let order = tidyRows(rects).flatMap { $0 }
        let box = boundingBox(rects)

        // Resize first — the bound below reads the result, not the input.
        var sized = rects
        for index in rects.indices {
            let rect = rects[index]
            // `SpaceLayout.aspect`'s fallback, mirrored: a degenerate rect is a square,
            // never a division by zero. The floor is `flowIn`'s, and stops a sliver
            // from becoming a zero-width tile nothing can grab.
            let aspect = (rect.width > 0 && rect.height > 0) ? rect.width / rect.height : 1
            sized[index] = CGRect(x: rect.minX, y: rect.minY,
                                  width: gridRowHeight * max(aspect, 0.01),
                                  height: gridRowHeight)
        }
        let maxWidth = tidyMaxRowWidth(sized)

        var result = sized
        var x = box.minX
        var y = box.minY
        var rowIsEmpty = true
        for index in order {
            let size = sized[index].size
            if !rowIsEmpty, x + size.width > box.minX + maxWidth {
                x = box.minX
                // Every row is exactly one tile tall now, so the step is a constant —
                // no running row height to track, which is what makes the rows justify.
                y += gridRowHeight + gridSpacing
                rowIsEmpty = true
            }
            result[index] = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + gridSpacing
            rowIsEmpty = false
        }
        return result
    }

    /// The height every tile takes in a reflow — a mirror of `SpaceLayout.rowHeight`.
    ///
    /// Mirrored rather than read from `SpaceLayout`, for ``fallbackMaxRowWidth``'s
    /// reason: this file stays the `[CGRect] → [CGRect]` island its header describes.
    /// `CanvasTidyPackTests` asserts the two numbers agree so the copy cannot drift.
    ///
    /// Fixed rather than derived from the selection (its median height, say). A derived
    /// height would change under its own output — pass one normalises the heights, so
    /// pass two measures a different median — and idempotence is the design constraint
    /// here exactly as it is for tidy. Fixed also means a reflowed block and a
    /// bulk-added one are the same size, which is the whole claim the verb makes.
    static let gridRowHeight: CGFloat = 240

    /// The gap a reflow uses, both ways — a mirror of `SpaceLayout.spacing`.
    ///
    /// Not ``tidyGap(_:rows:)``'s smallest-observed gap: see ``reflowGrid(_:)``.
    static let gridSpacing: CGFloat = 16

    // MARK: - A true uniform grid (076 · T3, 099 · P12)

    /// The side of one cell in a uniform grid. Square, and the same number as
    /// ``gridRowHeight`` — a reflowed block and an arranged one line up on their row
    /// pitch, which is what stops the two verbs from producing visibly different
    /// boards.
    ///
    /// Fixed rather than derived from the selection, for ``gridRowHeight``'s reason and
    /// with more force: a derived side (the median area's square root, say) changes
    /// under its own output, because pass one makes every tile the same size and pass
    /// two therefore measures something else.
    static let gridCellSide: CGFloat = gridRowHeight

    /// Force every rect into ONE cell size and lay the cells out in a square-ish grid.
    ///
    /// **This is the verb [076](../../.docs/076-spaces-tidy-wraps-plan.md) called
    /// "Grid" and deferred as T3, and it is a different thing from
    /// ``reflowGrid(_:)``.** Reflow normalises the HEIGHT and lets each width follow
    /// the picture's aspect, so its rows justify and its cells are uneven — the
    /// justified-rows reading of "uniform grid". This one takes the other reading:
    /// every tile becomes `gridCellSide × gridCellSide`, aspect discarded, columns
    /// aligned down the board. 076 called it destructive to the tiles' sizes and it is;
    /// that is the point, and ⌘Z is one keystroke away.
    ///
    /// **The column count is `ceil(√n)` — derived from the COUNT, not the geometry.**
    /// Tidy and reflow both derive a wrap bound from total area, and both needed care
    /// to keep that bound stable under their own output. Here there is nothing to
    /// stabilise: `n` does not change, so the grid's shape does not either, and
    /// idempotence stops being an argument and becomes arithmetic. Square-ish rather
    /// than 16:9 because the cells are square, so a square grid is the block that
    /// wastes the least screen.
    ///
    /// Idempotent, and the three steps are worth naming since they are what the
    /// `allCases` test asserts: after one pass every rect is exactly one cell, so the
    /// resize on pass two is the identity; `n` is unchanged, so the column count is;
    /// and ``tidyRows(_:)`` over the output re-clusters exactly the rows just laid out
    /// — a row's members share a top edge, its band is one cell tall, and the next row
    /// starts at `+ side + gap`, which is at or below the band's bottom and so never
    /// inside it, even at `gap == 0`.
    ///
    /// Order comes from ``tidyRows(_:)``, as reflow's does: the shape is discarded, the
    /// reading sequence is kept. Anchored on the INPUT box's top-left so the block
    /// arranges where it already sits. A negative gap is clamped, like ``pack(_:axis:gap:)``'s.
    static func uniformGrid(_ rects: [CGRect], gap: CGFloat = gridSpacing) -> [CGRect] {
        guard rects.count >= 2 else { return rects }
        let gap = max(0, gap)
        let order = tidyRows(rects).flatMap { $0 }
        let box = boundingBox(rects)
        let side = gridCellSide
        // `rects.count >= 2`, so the square root is at least √2 and the count at least
        // 2 — no zero-column loop is reachable.
        let columns = max(1, Int(Double(rects.count).squareRoot().rounded(.up)))

        var result = rects
        for (position, index) in order.enumerated() {
            let column = position % columns
            let row = position / columns
            result[index] = CGRect(
                x: box.minX + CGFloat(column) * (side + gap),
                y: box.minY + CGFloat(row) * (side + gap),
                width: side, height: side)
        }
        return result
    }

    // MARK: - Pack at an exact gap (066)

    /// Lay the rects out along `axis` with EXACTLY `gap` between adjacent edges,
    /// anchored on the leading-most rect so the selection grows away from where it
    /// already starts.
    ///
    /// The numeric peer of ``distribute(_:axis:)``: same sort, same cursor walk, but the
    /// gap is given rather than derived from the span. Negative input is clamped — a
    /// gap is a space, and letting one be negative would silently overlap the layout.
    static func pack(_ rects: [CGRect], axis: Axis, gap: CGFloat) -> [CGRect] {
        guard rects.count >= 2 else { return rects }
        let gap = max(0, gap)
        let order = rects.indices.sorted { a, b in
            let la = leading(rects[a], axis), lb = leading(rects[b], axis)
            return la == lb ? a < b : la < lb
        }
        var result = rects
        var cursor = leading(rects[order.first!], axis) // the first anchor stays put
        for index in order {
            result[index] = withLeading(rects[index], axis, cursor)
            cursor += extent(rects[index], axis) + gap
        }
        return result
    }

    // MARK: - Align

    /// Move every rect to a new origin computed from the selection bounding box +
    /// the rect itself, keeping its size. The six aligns differ only by that one
    /// closure — one code path, no per-op duplication.
    private static func align(_ rects: [CGRect],
                              origin: (_ box: CGRect, _ rect: CGRect) -> CGPoint) -> [CGRect] {
        let box = boundingBox(rects)
        return rects.map { CGRect(origin: origin(box, $0), size: $0.size) }
    }

    /// The tight bounding box (union) of all rects. `rects` is non-empty here
    /// (guarded by `minimumCount`).
    private static func boundingBox(_ rects: [CGRect]) -> CGRect {
        let minX = rects.map(\.minX).min()!
        let minY = rects.map(\.minY).min()!
        let maxX = rects.map(\.maxX).max()!
        let maxY = rects.map(\.maxY).max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Distribute (equal gaps)

    /// Which way a distribute / pack runs. Internal rather than private since 066:
    /// ``pack(_:axis:gap:)`` takes it from the caller, because an exact gap is not one
    /// of the ``Operation`` cases (see ``SpaceModel/pack(axis:gap:)`` for why).
    enum Axis: Equatable, CaseIterable { case horizontal, vertical }

    /// Equal-gaps distribution along `axis` ([6A]): sort by leading edge (stable on
    /// ties by original index), keep the first & last as fixed anchors, and space
    /// the interior items so the gap between adjacent edges is constant. The gap is
    /// clamped non-negative, so overlapping / identical-position selections pack
    /// left-to-right rather than emitting negative overlaps. Only the axis
    /// coordinate moves; the cross axis is untouched. Result is index-aligned to
    /// the input.
    private static func distribute(_ rects: [CGRect], axis: Axis) -> [CGRect] {
        // Order the rects by leading edge; the tie-break on original index keeps the
        // layout deterministic when two items share a leading edge.
        let order = rects.indices.sorted { a, b in
            let la = leading(rects[a], axis), lb = leading(rects[b], axis)
            return la == lb ? a < b : la < lb
        }
        let first = rects[order.first!]
        let last = rects[order.last!]
        let span = trailing(last, axis) - leading(first, axis)
        let sumExtents = order.reduce(CGFloat(0)) { $0 + extent(rects[$1], axis) }
        // (count - 1) gaps between `count` items; count ≥ 3 here.
        let free = span - sumExtents
        let gap = max(0, free / CGFloat(order.count - 1))

        var result = rects
        var cursor = leading(first, axis) // first anchor stays put
        for index in order {
            result[index] = withLeading(rects[index], axis, cursor)
            cursor += extent(rects[index], axis) + gap
        }
        return result
    }

    // MARK: - Axis accessors

    private static func leading(_ r: CGRect, _ a: Axis) -> CGFloat {
        a == .horizontal ? r.minX : r.minY
    }
    private static func trailing(_ r: CGRect, _ a: Axis) -> CGFloat {
        a == .horizontal ? r.maxX : r.maxY
    }
    private static func extent(_ r: CGRect, _ a: Axis) -> CGFloat {
        a == .horizontal ? r.width : r.height
    }
    private static func withLeading(_ r: CGRect, _ a: Axis, _ v: CGFloat) -> CGRect {
        a == .horizontal
            ? CGRect(x: v, y: r.minY, width: r.width, height: r.height)
            : CGRect(x: r.minX, y: v, width: r.width, height: r.height)
    }
}
