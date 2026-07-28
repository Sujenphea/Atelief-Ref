//
//  CanvasEditorViews.swift
//  CanvasRenderer
//
//  The two AppKit pieces an inline text editor is built from. Deliberately small and
//  free of policy: one carries the zoom, the other intercepts two keys.
//

import AppKit

/// Carries the canvas zoom for the inline editor, so the `NSTextView` inside never has
/// to. Its frame is the tile's SCREEN rect while its bounds is the same box in WORLD
/// units, which makes the view's scale exactly the camera's — the AppKit counterpart of
/// what the renderer does for committed text (060): lay out once in world space, and
/// let the zoom be pure rasterization.
///
/// It must be a view the text system does not manage. `NSTextView` rewrites its own
/// bounds during layout, so a scale applied there is intermittently reverted and the
/// glyphs snap back to unscaled mid-edit; this box has no layout of its own, so its
/// scale is deterministic. Nor may the zoom live on the FONT: sizing it
/// `worldSize × zoom` makes the text system re-wrap on every zoom step, which is both
/// jerky and the reflow 059 removed from the canvas.
///
/// Flipped to match ``CanvasHostView`` (top-left origin, y down).
public final class CanvasEditorScaleBox: NSView {
    public override var isFlipped: Bool { true }
}

/// An `NSTextView` that intercepts ⌘↵ (commit) and Esc (cancel) ahead of the normal
/// text-editing key handling. Everything else types as usual.
public final class CanvasEditorTextView: NSTextView {
    public var onCommandReturn: (() -> Void)?
    public var onEscape: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) { // ⌘ + Return
            onCommandReturn?()
            return
        }
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
