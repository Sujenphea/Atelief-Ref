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

    /// The eight arrange operations: 6 aligns + 2 distributes. `allCases` drives
    /// the table-driven kernel tests and the bar's op wiring, so a new op is added
    /// in exactly one place.
    enum Operation: CaseIterable {
        // Aligns (bounding box): need ≥2 to be meaningful.
        case alignLeft, alignHorizontalCenter, alignRight
        case alignTop, alignVerticalCenter, alignBottom
        // Distributes (equal gaps): need ≥3 (two items have no interior gap).
        case distributeHorizontal, distributeVertical
        // Tidy up (066): snap the selection into clean rows at a uniform gap.
        case tidyUp

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
    /// results back to ids by index). Pure: sizes are preserved, only the relevant
    /// origin coordinate moves. Below `op.minimumCount` it returns `rects`
    /// unchanged, so callers can invoke it safely on any selection.
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
    private static func tidy(_ rects: [CGRect]) -> [CGRect] {
        let rows = tidyRows(rects)
        let gap = tidyGap(rects, rows: rows)
        let box = boundingBox(rects)

        var result = rects
        var y = box.minY
        for row in rows {
            var x = box.minX
            var rowHeight: CGFloat = 0
            for index in row {
                let size = rects[index].size
                result[index] = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + gap
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + gap
        }
        return result
    }

    /// Cluster indices into rows by vertical overlap — top-to-bottom, each row ordered
    /// left-to-right. Ties break on the original index so the result is deterministic.
    ///
    /// A rect joins the open row when it starts ABOVE that row's lowest edge so far.
    /// Strictly above: a rect starting exactly at the edge is touching, not overlapping,
    /// and must begin a new row — that is what makes a `gap == 0` tidy stable.
    private static func tidyRows(_ rects: [CGRect]) -> [[Int]] {
        let topDown = rects.indices.sorted { a, b in
            let (ra, rb) = (rects[a], rects[b])
            if ra.minY != rb.minY { return ra.minY < rb.minY }
            if ra.minX != rb.minX { return ra.minX < rb.minX }
            return a < b
        }
        var rows: [[Int]] = []
        var openBottom: CGFloat = 0
        for index in topDown {
            if !rows.isEmpty, rects[index].minY < openBottom {
                rows[rows.count - 1].append(index)
                openBottom = max(openBottom, rects[index].maxY)
            } else {
                rows.append([index])
                openBottom = rects[index].maxY
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
