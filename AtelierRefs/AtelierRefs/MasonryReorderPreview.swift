//
//  MasonryReorderPreview.swift
//  AtelierRefs
//
//  040 §1 — pure math for the live reorder drop preview. While an internal
//  same-collection drag hovers the grid, the layout renders a PERMUTED
//  arrangement — the dragged block (the dimmed "ghost") at the pointer's
//  insertion slot, every other cell slid aside — and the drop commits exactly
//  what is shown (`reorderedIDs(ids:movingIDs:insertAt:)`, GridReorder.swift).
//  Kept AppKit-free so the display permutation, the frame mapping and the slot
//  hit-testing are unit-tested directly (`MasonryReorderPreviewTests`).
//
//  Vocabulary: a SLOT `s ∈ 0...remaining.count` is a position in the
//  block-removed order; the block occupies display positions
//  `s ..< s + block.count`. All frames here are ANALYTIC content-space frames
//  (the 038 §3.4 rule: hit-testing never reads pixel-snapped view frames).
//

import CoreGraphics
import Foundation

/// A solved preview arrangement: every DATA index's frame under the permuted
/// display order, plus the content height — what `MasonryCollectionLayout`
/// renders while a reorder drag hovers (040 §2).
struct MasonryPreviewFrames: Equatable {
    /// Index-aligned to the data source's items (NOT display order): item `i`
    /// draws at `framesByDataIndex[i]`, wherever its display slot put it.
    var framesByDataIndex: [CGRect]
    /// The tallest column's bottom edge under the permuted arrangement.
    var contentHeight: CGFloat
}

/// The data indices in the order they should be SHOWN while the dragged block
/// sits at `slot`: `remaining[..<slot] + block + remaining[slot...]`. The block
/// is gathered in FEED order whatever order `blockIndices` arrives in, and
/// out-of-range indices are dropped — mirroring the gather rule of
/// `reorderedIDs` so preview and commit can never disagree. `slot` clamps to
/// `0...remaining.count`; an empty block yields the identity. The result is
/// always a permutation of `0..<count`.
func previewDisplayOrder(count: Int, blockIndices: [Int], slot: Int) -> [Int] {
    let blockSet = Set(blockIndices)
    var block = [Int]()
    var remaining = [Int]()
    for index in 0..<max(0, count) {
        if blockSet.contains(index) { block.append(index) } else { remaining.append(index) }
    }
    let clamped = min(max(0, slot), remaining.count)
    return Array(remaining[..<clamped]) + block + Array(remaining[clamped...])
}

/// Solve the masonry for a permuted arrangement and hand the frames back in
/// DATA order: display position `p` gets the `p`-th masonry frame, filed under
/// `displayOrder[p]`. Cell sizes ride their cells — width is the shared column
/// width, height `columnWidth / aspect` of the DATA item — so a preview never
/// re-buckets or re-decodes a thumbnail (040 decision 9).
///
/// `displayOrder` must be a permutation of `aspects.indices` (the
/// `previewDisplayOrder` contract); a stray out-of-range entry defensively
/// solves as a square and maps nowhere rather than trapping.
///
/// `leadingInset` / `trailingInset` are the horizontal content margins (200) the
/// real solve reserves; the preview MUST pass the same values or its columns pack
/// edge-to-edge and the cells scale up mid-drag, snapping back on drop. Both
/// default to 0 so the pre-inset call sites (and search) are unchanged.
func previewFrames(
    displayOrder: [Int], aspects: [Double], availableWidth: CGFloat,
    columns: Int, spacing: CGFloat, topInset: CGFloat,
    leadingInset: CGFloat = 0, trailingInset: CGFloat = 0
) -> MasonryPreviewFrames {
    let permutedAspects = displayOrder.map { index in
        aspects.indices.contains(index) ? aspects[index] : 1
    }
    let solved = MasonryLayout.layout(
        aspects: permutedAspects, availableWidth: availableWidth,
        columns: columns, spacing: spacing, topInset: topInset,
        leadingInset: leadingInset, trailingInset: trailingInset)
    var frames = [CGRect](repeating: .zero, count: aspects.count)
    for (position, dataIndex) in displayOrder.enumerated()
    where frames.indices.contains(dataIndex) {
        frames[dataIndex] = solved.frames[position]
    }
    return MasonryPreviewFrames(
        framesByDataIndex: frames, contentHeight: solved.contentHeight)
}

/// The insertion slot for a pointer at `point` (content space), decided against
/// the ON-SCREEN preview frames so it is pointer-stable (040 decision 3): a hit
/// on one of the ghost's own cells keeps the CURRENT slot — hovering the block
/// never oscillates — while any other cell splits at its midX (left half →
/// before it, right half → after; feed adjacency is horizontal in a round-robin
/// masonry). A gap, the area below the content, or the top inset falls to the
/// NEAREST cell by center distance, same midX rule. An empty grid (or a wholly
/// dragged one) answers `0`.
func masonryInsertionSlot(
    at point: CGPoint, framesByDataIndex: [CGRect], displayOrder: [Int],
    blockIndices: [Int]
) -> Int {
    guard !displayOrder.isEmpty else { return 0 }
    let blockSet = Set(blockIndices)
    // The block is contiguous in display order, so its first member's display
    // position IS the current slot (everything before it is non-block).
    let currentSlot = displayOrder.firstIndex { blockSet.contains($0) } ?? 0

    func slot(for dataIndex: Int) -> Int {
        if blockSet.contains(dataIndex) { return currentSlot }
        guard let position = displayOrder.firstIndex(of: dataIndex) else {
            return currentSlot
        }
        let blockBefore = displayOrder[..<position].count { blockSet.contains($0) }
        let rank = position - blockBefore
        return point.x >= framesByDataIndex[dataIndex].midX ? rank + 1 : rank
    }

    if let hit = framesByDataIndex.indices.first(
        where: { framesByDataIndex[$0].contains(point) }) {
        return slot(for: hit)
    }
    var nearest: (index: Int, distanceSquared: CGFloat)?
    for index in framesByDataIndex.indices {
        let frame = framesByDataIndex[index]
        guard !frame.isEmpty else { continue }   // unmapped data index
        let dx = point.x - frame.midX
        let dy = point.y - frame.midY
        let distanceSquared = dx * dx + dy * dy
        if nearest.map({ distanceSquared < $0.distanceSquared }) ?? true {
            nearest = (index, distanceSquared)
        }
    }
    guard let nearest else { return 0 }
    return slot(for: nearest.index)
}

/// Pointer travel below this many points never re-slots — the jitter guard for
/// hovering near a cell's midX or a column boundary (040 decision 3). Lives
/// beside the slot math so tuning it is one edit.
let masonryReslotHysteresis: CGFloat = 8

/// Whether the pointer has moved far enough from the point that produced the
/// current slot to justify recomputing it.
func masonryShouldReslot(
    from lastSlotPoint: CGPoint, to point: CGPoint,
    threshold: CGFloat = masonryReslotHysteresis
) -> Bool {
    let dx = point.x - lastSlotPoint.x
    let dy = point.y - lastSlotPoint.y
    return dx * dx + dy * dy >= threshold * threshold
}
