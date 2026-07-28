//
//  CanvasTextEditController.swift
//  CanvasRenderer
//
//  The live inline text editor: an `NSTextView` held directly over one tile by the
//  canvas host that owns the tile.
//
//  This used to be a SwiftUI `NSViewRepresentable` in the app, mounted beside the
//  canvas and reaching back into it through a bridge object. That put four asynchronous
//  hops between "the user double-clicked" and "a caret exists" — AppKit callback →
//  app closure → `@State` → SwiftUI view update → `viewDidMoveToWindow` — during which
//  the tile could move, the host could be rebuilt, or the edit could commit itself.
//  Editing is a canvas gesture, so it begins synchronously inside `mouseDown`, exactly
//  where the gesture is.
//
//  What is NOT here is policy. The controller does not know what a string means, when a
//  box should be deleted, or how anything is persisted; it reports a
//  ``CanvasTextEditOutcome`` and the app decides. Nor does it know the app's style type:
//  ``TextStyle`` comes from the provider through ``CanvasEngine/textStyle(forTileID:)``,
//  which already carries everything the glyphs need.
//

import AppKit

/// Owns the `NSTextView` for one open edit. Created and destroyed by
/// ``CanvasHostView``; never outlives an edit.
@MainActor
final class CanvasTextEditController: NSObject, NSTextViewDelegate {
    /// The tile being edited.
    let tileID: Int
    /// Whether the box was just created — the only thing that makes an empty commit
    /// mean "delete me" rather than "clear my text".
    let isNewlyCreated: Bool

    private let engine: CanvasEngine
    private unowned let host: NSView
    private let textView = CanvasEditorTextView(frame: .zero)
    private let scaleBox = CanvasEditorScaleBox()
    private var commitGuard = CanvasCommitGuard()

    /// Delivered exactly once, when the edit ends.
    private let onFinish: (CanvasTextEditOutcome) -> Void

    /// Whether ``reposition()`` has ever successfully placed the overlay. Until it has,
    /// "the tile isn't visible" cannot mean the tile scrolled away — the canvas may
    /// simply not have been laid out yet.
    private var hasPositioned = false

    /// Set when editing began before the host had a window, so first responder can be
    /// taken as soon as it gets one.
    private var wantsFirstResponder = false

    init(
        tileID: Int,
        isNewlyCreated: Bool,
        style: TextStyle,
        engine: CanvasEngine,
        host: NSView,
        onFinish: @escaping (CanvasTextEditOutcome) -> Void
    ) {
        self.tileID = tileID
        self.isNewlyCreated = isNewlyCreated
        self.engine = engine
        self.host = host
        self.onFinish = onFinish
        super.init()

        // Plain-text mode BEFORE the font: toggling `isRichText` off resets the font to
        // the default, so a font applied earlier would be silently discarded and the
        // glyphs would render at the system size.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // TextKit's default 5pt line-fragment padding is invisible to `TextMetrics`, so
        // leaving it on makes the editor wrap ~10pt narrower than the committed box
        // measures — a line could break differently the moment you start typing. Zero it
        // so both agree on the wrap width.
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.string = style.string
        applyTypography(style)
        textView.onCommandReturn = { [weak self] in self?.finish(commit: true) }
        textView.onEscape = { [weak self] in self?.finish(commit: false) }

        scaleBox.addSubview(textView)
        host.addSubview(scaleBox)

        // The engine blanks this tile's committed glyphs while an editor owns them, so
        // they aren't doubled by the live ones.
        engine.editingTileID = tileID
        reposition()
        takeFirstResponder()
        // A just-created box shows its placeholder pre-selected so the first keystroke
        // replaces it; an existing edit lands the caret at the end. UTF-16 length (not
        // Character count) so the caret lands correctly after composed text.
        if isNewlyCreated {
            textView.selectAll(nil)
        } else {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    // MARK: - Focus

    private func takeFirstResponder() {
        guard let window = host.window else {
            wantsFirstResponder = true
            return
        }
        wantsFirstResponder = false
        window.makeFirstResponder(textView)
    }

    /// Called by the host once it has a window, for an edit that began without one.
    func hostDidMoveToWindow() {
        guard wantsFirstResponder else { return }
        takeFirstResponder()
    }

    /// Whether `point` (in the host's coordinates) is inside the edited box, so the host
    /// can leave the cursor to the text view rather than forcing its own.
    func contains(hostPoint point: CGPoint) -> Bool {
        scaleBox.frame.contains(point)
    }

    // MARK: - Typography

    /// Everything the live glyphs are built from EXCEPT the string. The string belongs
    /// to the text view while an edit is open and must never be written back from the
    /// model's — still stale — copy.
    private struct Typography: Equatable {
        let fontSize: Double
        let color: RGBAColor
        let fontFamily: String?
        let weight: FontWeight
        let alignment: TextAlignment

        init(_ style: TextStyle) {
            fontSize = style.fontSize
            color = style.color
            fontFamily = style.fontFamily
            weight = style.weight
            alignment = style.alignment
        }
    }

    private var appliedTypography: Typography?

    /// Rebuild the live glyphs iff the style's typography actually moved. Called on
    /// every re-sync, because a restyle can arrive mid-edit — the format bubble is
    /// anchored on the box being edited (062) — and because resetting the font also
    /// resets the typing attributes, which must not happen on every unrelated sync.
    func applyTypographyIfChanged() {
        guard let style = engine.textStyle(forTileID: tileID) else { return }
        guard Typography(style) != appliedTypography else { return }
        applyTypography(style)
        reposition()
    }

    private func applyTypography(_ style: TextStyle) {
        appliedTypography = Typography(style)
        // The point size is the WORLD size and never changes with zoom — `scaleBox`
        // carries the zoom instead (see `reposition`).
        textView.font = CanvasFont.nsFont(
            family: style.fontFamily, weight: style.weight, size: CGFloat(style.fontSize))
        textView.textColor = NSColor(
            srgbRed: style.color.red, green: style.color.green,
            blue: style.color.blue, alpha: style.color.alpha)
        switch style.alignment {
        case .left: textView.alignment = .left
        case .center: textView.alignment = .center
        case .right: textView.alignment = .right
        }
    }

    // MARK: - Placement

    /// Place the overlay from the tile's live screen frame. A tile that scrolls out of
    /// the viewport commits and exits (054 §5.4).
    ///
    /// Re-measures the CURRENT string through `TextMetrics` — the same source the
    /// committed box uses — and resizes only the overlay. Called from every cause the
    /// frame can move for (typing, a pan, a zoom, a move drag, a resize drag), so the
    /// two halves of what the user sees can never drift apart.
    func reposition() {
        if canvasInlineEditShouldCommitOnViewportExit(
            isVisible: engine.isVisible(tileID: tileID),
            viewportSize: engine.viewportSize,
            hasPositioned: hasPositioned) {
            finish(commit: true)
            return
        }
        // A tile the provider no longer has is a torn-down board, not a scrolled one —
        // nothing to place the overlay over, so hold still and let teardown run.
        guard let frame = engine.screenFrame(forTileID: tileID),
              var style = engine.textStyle(forTileID: tileID) else { return }
        hasPositioned = true
        let scale = max(0.0001, engine.transform.scale)

        style.string = textView.string
        let measured = TextMetrics.size(
            for: style, maxWidth: max(1, frame.width / scale - 2 * TextMetrics.padding))
        let worldSize = canvasInlineEditorWorldBox(
            tileScreenFrame: frame, scale: scale, measuredWorldSize: measured)

        // The canvas draws the box, its border and its handles; the editor draws the
        // glyphs. Hand over the height so the two agree at every keystroke (062) —
        // without this the box keeps its committed height and the text grows straight
        // out through its own border.
        engine.setEditingBoxHeight(worldSize.height)

        // The zoom lives HERE and nowhere else: a screen-space frame over a world-space
        // bounds makes the box's scale exactly the camera's, and the text view inside
        // fills those world-sized bounds at scale 1. With layout fixed in world units a
        // zoom is pure rasterization, so line breaks hold — and hold identically to the
        // committed box, measured against the same world width.
        let padded = NSSize(width: TextMetrics.padding, height: TextMetrics.padding)
        scaleBox.frame = CGRect(
            x: frame.minX, y: frame.minY,
            width: worldSize.width * scale, height: worldSize.height * scale)
        scaleBox.bounds = CGRect(origin: .zero, size: worldSize)
        textView.textContainerInset = padded
        textView.frame = CGRect(origin: .zero, size: worldSize)
    }

    // MARK: - Finishing

    /// Resolve the outcome ONCE and dispatch it. Safe to call from every teardown path;
    /// the guard makes all but the first a no-op.
    func finish(commit: Bool) {
        guard commitGuard.begin() else { return }
        let outcome = canvasTextEditOutcome(
            text: textView.string, isNewlyCreated: isNewlyCreated, committed: commit)

        // Tear the views down before reporting, so the app's write lands on a canvas
        // with no editor over it and nothing can re-enter through a delegate callback.
        textView.delegate = nil
        scaleBox.removeFromSuperview()

        onFinish(outcome)

        // Hand the height back to the stored geometry AFTER the outcome is applied: a
        // commit has by then written the derived height, so the box holds still; a
        // cancel drops back to the height it had before the edit, which is the point of
        // cancelling.
        engine.setEditingBoxHeight(nil)
        engine.editingTileID = nil
    }

    // MARK: - NSTextViewDelegate

    /// Live growth: re-place from the new string. No provider mutation and no write —
    /// nothing is persisted until the edit commits, so the undo stack sees one entry
    /// rather than one per keystroke.
    func textDidChange(_ notification: Notification) { reposition() }

    /// Blur (click-away, or focus taken by a popover) commits. The guard makes this a
    /// no-op when ⌘↵ or Esc already finished.
    func textDidEndEditing(_ notification: Notification) { finish(commit: true) }
}
