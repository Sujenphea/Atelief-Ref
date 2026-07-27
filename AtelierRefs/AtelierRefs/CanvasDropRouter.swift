//
//  CanvasDropRouter.swift
//  AtelierRefs
//
//  059 · SP1 / 11A — the ONE pure decision for "what does a drop onto a Space
//  board do?", the canvas analog of ``DropRouter``. The AppKit destination
//  (``CanvasHostView``, 4A) decodes the drag pasteboard + providers into a
//  ``CanvasDropContents`` classification, then calls ``canvasDropRoute`` and
//  executes the returned ``CanvasDropRoute`` — it never hand-rolls accept/reject
//  guards, so the edge cases (empty payload, a foreign space-reorder drag,
//  nothing importable, an internal marker) live in ONE unit-tested place.
//
//  Deliberately at the SAME level as ``DropRouter``: it decides place / ingest /
//  reject over an ALREADY-decoded classification. It does NOT re-derive input
//  precedence (image-vs-URL, media-less, file-vs-remote) — that is
//  ``DirectInputReader``'s job and is tested there; duplicating it here would be
//  a second source of truth for the same rule.
//
//  The world point under the cursor is NOT an input to the decision: a drop onto
//  a board always places at that point on the CANVAS, even when a tile sits under
//  the cursor (a board has no "drop onto a tile" meaning). The executor applies
//  the point; the route stays point-free so it can't drift.
//

import Foundation

/// What a drop onto a Space board carries, after ``CanvasHostView`` has decoded
/// the drag pasteboard + item providers. The async content decode (files →
/// bytes, a remote URL → a download) stays with ``DirectInputReader``; this only
/// captures the CLASS of drop, which is all the routing decision needs.
enum CanvasDropContents: Equatable {
    /// An in-app asset drag — the grid, library search results, or another board.
    /// Carries the payload verbatim so the route can honour its (possibly empty)
    /// id list exactly as ``DropRouter`` does.
    case assetDrag(AssetDragPayload)
    /// A sidebar space-reorder drag (``SpaceDragPayload``). Never a board drop —
    /// you can't drop a board onto a board.
    case spaceReorder
    /// External content from Finder / a browser / another app.
    /// `hasImportableType` is the destination's cheap pre-check that at least one
    /// provider (or the pasteboard) conforms to an importable type; the
    /// authoritative decode still happens async via ``DirectInputReader``.
    case external(hasImportableType: Bool)
    /// Nothing the board recognizes was on the drop.
    case empty
}

/// The resolved effect of a board drop. The executor applies the drop point.
enum CanvasDropRoute: Equatable {
    /// Refuse the drop — no state change, never a crash.
    case reject
    /// Place already-imported assets (these ids) at the drop point.
    case place(assetIDs: [UUID])
    /// Ingest the external content first, then place the resolved assets at the
    /// drop point. The resolved-asset set is discovered by the async import.
    case ingestThenPlace
}

/// Decide what `contents` does when dropped onto a Space board. Pure — the
/// AppKit pasteboard/provider reads that build `contents` are isolated in the
/// destination, so this stays trivially testable across every branch.
func canvasDropRoute(_ contents: CanvasDropContents) -> CanvasDropRoute {
    switch contents {
    case let .assetDrag(payload):
        // An empty id list (e.g. ``AssetDragPayload/internalMarker``) marks a drag
        // as internal without granting it any placement — mirror DropRouter and
        // refuse it rather than placing nothing.
        return payload.assetIDs.isEmpty ? .reject : .place(assetIDs: payload.assetIDs)
    case .spaceReorder:
        return .reject
    case let .external(hasImportableType):
        return hasImportableType ? .ingestThenPlace : .reject
    case .empty:
        return .reject
    }
}
