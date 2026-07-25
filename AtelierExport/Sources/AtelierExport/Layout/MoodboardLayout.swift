// AtelierExport — moodboard layout + pagination (052 · B2, 10A layer 1)
//
// PURE arithmetic: world-space ``MoodboardElement``s in, page-space
// `[LayoutPage]` out, no drawing and no I/O. This is the deterministic core the
// 10A layer-1 tests pin to exact values. Two mappings share one placement
// routine:
//
//   • fit    — the whole board scaled to fit a single page bounded by a max
//              dimension (a moodboard poster / shareable image). One page.
//   • paginate — a fixed world→point scale tiled across N fixed-size pages
//              (printable). Page count = ceil(boardW/contentW) · ceil(boardH/
//              contentH), row-major from the board's top-left.
//
// Coordinate conversion (world y-DOWN → page y-UP) happens here, once, so the
// renderer never flips axes. See ``place(_:boardOrigin:scale:pageSize:offset:)``.

import CoreGraphics

/// Turns a set of world-space board elements into rendered pages. Value type;
/// its knobs (margin, background) are the layout's, not the renderer's.
public struct MoodboardLayout: Equatable, Sendable {
    /// Uniform page margin in points. Content is inset by this on all sides.
    public var margin: Double

    public init(margin: Double = 24) {
        self.margin = margin
    }

    /// The tight world-space bounding box of `elements` (union of their rects),
    /// or `nil` when there is nothing to lay out. Exposed for tests and for the
    /// renderer's empty-check.
    public static func boundingBox(of elements: [MoodboardElement]) -> CGRect? {
        guard let first = elements.first else { return nil }
        var box = first.rect
        for element in elements.dropFirst() {
            box = box.union(element.rect)
        }
        return box
    }

    /// Fit the whole board onto ONE page whose longest edge is at most
    /// `maxDimension` points (including margins). The board is scaled uniformly
    /// so its longest edge fills `maxDimension - 2·margin`; a board smaller than
    /// that is NOT upscaled past 1 world-unit-per-point (avoids exploding a tiny
    /// selection into a blurry giant). Returns `[]` for an empty selection.
    ///
    /// - Parameter maxDimension: the longest page edge in points (e.g. 2048).
    public func fitToSinglePage(
        _ elements: [MoodboardElement],
        maxDimension: Double
    ) -> [LayoutPage] {
        guard let board = Self.boundingBox(of: elements),
              board.width > 0, board.height > 0 else { return [] }

        let available = Swift.max(1, maxDimension - 2 * margin)
        let longestEdge = Swift.max(board.width, board.height)
        // Never upscale beyond 1:1 — a small board stays crisp at world size.
        let scale = Swift.min(available / longestEdge, 1)

        let pageSize = CGSize(
            width: board.width * scale + 2 * margin,
            height: board.height * scale + 2 * margin)

        let placed = elements.map {
            place($0, boardOrigin: board.origin, scale: scale, pageSize: pageSize, offset: .zero)
        }
        return [LayoutPage(size: pageSize, elements: placed)]
    }

    /// Tile the board across fixed-size pages at a FIXED world→point `scale`.
    /// Each page shows a `pageSize`-worth window of the board (inset by margin);
    /// an element that straddles a page boundary is emitted on every page it
    /// overlaps, clipped to that page's content area. Pages are ordered
    /// row-major from the board's top-left. Returns `[]` for an empty selection
    /// or a non-positive page content area.
    ///
    /// - Parameters:
    ///   - pageSize: the paper size in points (e.g. US Letter = 612×792).
    ///   - scale: points per world unit.
    public func paginate(
        _ elements: [MoodboardElement],
        pageSize: CGSize,
        scale: Double
    ) -> [LayoutPage] {
        guard scale > 0,
              let board = Self.boundingBox(of: elements),
              board.width > 0, board.height > 0 else { return [] }

        let content = CGSize(
            width: pageSize.width - 2 * margin,
            height: pageSize.height - 2 * margin)
        guard content.width > 0, content.height > 0 else { return [] }

        let boardPoints = CGSize(width: board.width * scale, height: board.height * scale)
        let columns = Swift.max(1, Int(ceil(boardPoints.width / content.width)))
        let rows = Swift.max(1, Int(ceil(boardPoints.height / content.height)))

        var pages: [LayoutPage] = []
        pages.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                // The board-point window this page covers (y-down from board top).
                let window = CGRect(
                    x: Double(column) * content.width,
                    y: Double(row) * content.height,
                    width: content.width,
                    height: content.height)
                // World→board-point offset places the window's top-left at the
                // page's content origin (margin, margin).
                let offset = CGPoint(x: -window.minX, y: -window.minY)

                let placed = elements.compactMap { element -> PlacedElement? in
                    let frame = pageFrame(
                        for: element, boardOrigin: board.origin,
                        scale: scale, pageSize: pageSize, offset: offset)
                    // Drop elements that don't touch this page's content area.
                    let contentRect = CGRect(
                        x: margin, y: margin, width: content.width, height: content.height)
                    guard frame.intersects(contentRect) else { return nil }
                    return placedElement(
                        element, frame: frame, clip: contentRect, scale: scale)
                }
                pages.append(LayoutPage(size: pageSize, elements: placed))
            }
        }
        return pages
    }

    // MARK: - Placement

    /// Convert one element to page space for the single-page (fit) case: no
    /// window offset, clip is the whole content area.
    private func place(
        _ element: MoodboardElement,
        boardOrigin: CGPoint,
        scale: Double,
        pageSize: CGSize,
        offset: CGPoint
    ) -> PlacedElement {
        let frame = pageFrame(
            for: element, boardOrigin: boardOrigin, scale: scale,
            pageSize: pageSize, offset: offset)
        let content = CGRect(
            x: margin, y: margin,
            width: pageSize.width - 2 * margin,
            height: pageSize.height - 2 * margin)
        return placedElement(element, frame: frame, clip: content, scale: scale)
    }

    /// The core world→page-point rect conversion, shared by both modes.
    ///
    /// World is y-DOWN with the board's top-left at `boardOrigin`; a page is
    /// y-UP. `offset` (in board points) shifts the board within the page — zero
    /// for fit, the tiling window's negated origin for paginate. The margin then
    /// insets the content from the page edges.
    private func pageFrame(
        for element: MoodboardElement,
        boardOrigin: CGPoint,
        scale: Double,
        pageSize: CGSize,
        offset: CGPoint
    ) -> CGRect {
        // Board-point coordinates of the element (y-down from board top-left).
        let boardX = (element.rect.minX - boardOrigin.x) * scale + offset.x
        let boardTopY = (element.rect.minY - boardOrigin.y) * scale + offset.y
        let width = element.rect.width * scale
        let height = element.rect.height * scale

        let pageX = margin + boardX
        // Flip y-down board space into y-up page space: the element's TOP edge
        // sits `margin + boardTopY` down from the page top, i.e. that far up
        // from the page bottom once inverted; subtract the height for the origin.
        let pageTopFromBottom = pageSize.height - margin - boardTopY
        let pageY = pageTopFromBottom - height
        return CGRect(x: pageX, y: pageY, width: width, height: height)
    }

    /// Assemble a ``PlacedElement`` from a computed page frame.
    private func placedElement(
        _ element: MoodboardElement,
        frame: CGRect,
        clip: CGRect,
        scale: Double
    ) -> PlacedElement {
        PlacedElement(
            frame: frame, clip: clip, z: element.z, scale: scale, content: element.content)
    }
}
