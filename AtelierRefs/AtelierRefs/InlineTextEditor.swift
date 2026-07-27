//
//  InlineTextEditor.swift
//  AtelierRefs
//
//  005 / 054 §5 (2B) — inline on-canvas text editing. Double-clicking a `.text`
//  element (or finishing a new-text-box create) mounts a transparent `NSTextView`
//  directly over the tile; typing edits the STRING on canvas while the inspector
//  popover keeps the STYLE controls (D3). The overlay lives in the APP layer and
//  repositions IMPERATIVELY off the SwiftUI diff — its Coordinator sets
//  `textView.frame` from the newly-exposed `CanvasHostView.screenFrame(forTileID:)`
//  on each engine-sourced `onTransformChanged` (D6 · R15), so a pan/zoom while
//  editing never re-evaluates `SpaceView.body`.
//
//  The renderer's `CanvasFont` (the single typeface source) is internal to
//  CanvasRenderer, so the transient editing glyphs are built here with the SAME
//  family/weight mapping; the persisted result is still measured + drawn through
//  `TextMetrics`/`CanvasFont` on commit, so the committed box can't drift. The
//  lifecycle decision is a pure, exhaustively-tested predicate (`inlineEditOutcome`),
//  and a one-shot `CommitGuard` blocks the blur+Esc / commit-during-undo double
//  write (mirrors `ElementInspector.finished`).
//

import AppKit
import AtelierCore
import CanvasRenderer
import SwiftUI

// MARK: - Pure lifecycle logic (unit-tested; no NSView)

/// What to do with an inline edit when it ends (054 §5.3 · R8).
enum InlineEditOutcome: Equatable {
    /// Write the string back through the model's restyle path (auto-size + one undo).
    case persist(String)
    /// Abandon the edit — no write (Esc, or the double-commit guard).
    case cancel
    /// Remove the element entirely — an empty box the user just created, so it
    /// leaves no invisible orphan (054 §5.3).
    case deleteElement
}

/// The pure commit/cancel/delete decision for an inline edit (054 §5.3 · R8).
///
/// - `committed == false` → `.cancel` (Esc / abandoned): never write.
/// - empty text, newly created → `.deleteElement`: an untouched new box is removed.
/// - empty text, pre-existing → `.persist("")`: an explicit clear is honoured
///   (the element stays; its string becomes empty).
/// - non-empty → `.persist(text)`.
///
/// "Empty" is whitespace/newline-insensitive so a box holding only spaces reads as
/// empty for the delete-new-box rule. The design lists the parameter as
/// `textIsEmpty: Bool`, but `.persist(text)` needs the string, so the text is
/// threaded through and emptiness derived here (one source, no caller re-derives it).
func inlineEditOutcome(text: String, wasNewlyCreated: Bool, committed: Bool) -> InlineEditOutcome {
    guard committed else { return .cancel }
    let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if isEmpty { return wasNewlyCreated ? .deleteElement : .persist("") }
    return .persist(text)
}

/// While editing, a tile that scrolls out of the viewport (its on-screen frame goes
/// `nil`) triggers a commit-and-exit rather than a silent abandon (054 §5.4). Pure
/// so the "tile-left-viewport → commit" rule is unit-tested without a window.
func inlineEditShouldCommitOnViewportExit(screenFrame: CGRect?) -> Bool {
    screenFrame == nil
}

/// One-shot guard mirroring `ElementInspector.finished` (054 §5.3): the FIRST finish
/// wins; a later blur / Esc / commit-during-undo is ignored so the edit never writes
/// twice. Value type so the "double-commit guard" is unit-testable.
struct CommitGuard {
    private(set) var finished = false

    /// Returns `true` exactly once — for the first caller — and `false` thereafter.
    mutating func begin() -> Bool {
        if finished { return false }
        finished = true
        return true
    }
}

// MARK: - Bridge (app ↔ live host rendezvous)

/// The rendezvous the inline editor uses to reach the live ``CanvasHostView`` and
/// to be poked on each transform change — both WITHOUT routing through SwiftUI
/// state (so the reposition stays off the `body` diff, D6 · R15). `SpaceView` owns
/// one; `CanvasView.onHostReady` fills ``host`` and `CanvasView.onTransformChanged`
/// calls ``transformDidChange()``; the editor's Coordinator registers
/// ``onReposition``.
@MainActor
final class CanvasEditingBridge {
    /// The live canvas host, captured when `CanvasView` builds it (and again if it
    /// is rebuilt via `.id`). `weak` so the bridge never keeps a detached host alive.
    weak var host: CanvasHostView?

    /// The mounted editor's reposition hook, set while an editor is up and cleared
    /// on teardown. `transformDidChange()` fans the engine notification into it.
    var onReposition: (() -> Void)?

    /// Called once per transform mutation (via `CanvasView.onTransformChanged`).
    func transformDidChange() { onReposition?() }

    /// The edited tile's live on-screen frame, or `nil` if it left the viewport.
    func screenFrame(forTileID id: Int) -> CGRect? { host?.screenFrame(forTileID: id) }

    /// The current world→screen scale (for mapping measured world size to screen).
    var scale: CGFloat { host?.transform.scale ?? 1 }
}

// MARK: - The NSTextView overlay

/// A transparent `NSTextView` overlay positioned over one `.text` tile. See the
/// file header for the imperative-reposition contract.
struct InlineTextEditor: NSViewRepresentable {
    /// The tile (canvas index) being edited — the id `screenFrame(forTileID:)` and
    /// the engine's blank-while-editing both key on.
    let tileID: Int
    /// The element's current style — seeds the initial string, font, colour, and
    /// alignment, and drives the editor-only auto-grow measurement.
    let style: ElementStyle
    /// Whether this box was just created — an empty commit deletes it (054 §5.3).
    let wasNewlyCreated: Bool
    /// The rendezvous to the live host + transform notification.
    let bridge: CanvasEditingBridge
    /// Persist the edited string (the app rebuilds the style + calls `updateStyle`).
    let onCommit: (String) -> Void
    /// Abandon the edit (Esc): clear the editing state, no write.
    let onCancel: () -> Void
    /// Delete the element (empty new box).
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassThroughContainer {
        let coordinator = context.coordinator
        coordinator.editor = self
        // Reposition on every engine transform notification — imperative, off the
        // SwiftUI diff (D6 · R15).
        bridge.onReposition = { [weak coordinator] in coordinator?.reposition() }
        coordinator.container.onMovedToWindow = { [weak coordinator] in coordinator?.activate() }
        return coordinator.container
    }

    func updateNSView(_ nsView: PassThroughContainer, context: Context) {
        // Keep the Coordinator's closures/style fresh, then re-place the overlay.
        context.coordinator.editor = self
        context.coordinator.reposition()
    }

    static func dismantleNSView(_ nsView: PassThroughContainer, coordinator: Coordinator) {
        coordinator.editor.bridge.onReposition = nil
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The latest representable (refreshed in make/update) — the source of the
        /// commit/cancel/delete closures + style at finish time.
        var editor: InlineTextEditor
        let textView: InlineNSTextView
        let container: PassThroughContainer
        private var commitGuard = CommitGuard()

        init(_ editor: InlineTextEditor) {
            self.editor = editor
            self.textView = InlineNSTextView(frame: .zero)
            self.container = PassThroughContainer()
            super.init()
            configure()
        }

        private func configure() {
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
            textView.delegate = self
            textView.string = editor.style.text ?? ""
            applyTypography()
            textView.onCommandReturn = { [weak self] in self?.finish(committed: true) }  // ⌘↵ commits
            textView.onEscape = { [weak self] in self?.finish(committed: false) }         // Esc cancels

            container.textView = textView
            container.addSubview(textView)
        }

        /// Font / colour / alignment from the element's style — the SAME family/weight
        /// mapping `CanvasFont` uses (it is internal to the renderer, so replicated
        /// here for the transient glyphs; the committed render still goes through it).
        /// The point size tracks the live zoom (see ``applyFontScale``) so the editor
        /// glyphs match the on-canvas `CATextLayer` (drawn at `fontSize × scale`).
        private func applyTypography() {
            applyFontScale()
            let rgba = ElementRendering.rgba(fromHex: editor.style.textColor)
                ?? RGBAColor(red: 0.07, green: 0.07, blue: 0.07)
            textView.textColor = NSColor(
                srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
            switch editor.style.align {
            case .left: textView.alignment = .left
            case .center: textView.alignment = .center
            case .right: textView.alignment = .right
            }
        }

        /// Size the editor font to the live zoom so the transient glyphs match the
        /// on-canvas `CATextLayer` (which draws at `fontSize × scale`). Re-applied on
        /// every transform change (see ``reposition``) so a zoom while editing keeps
        /// the editor and the tile in lock-step.
        private func applyFontScale() {
            textView.font = Self.nsFont(for: editor.style, scale: bridge.scale)
        }

        /// First-responder + initial placement once the overlay has a window.
        func activate() {
            reposition()
            container.window?.makeFirstResponder(textView)
            // A just-created box shows the "Text" placeholder pre-selected so the
            // first keystroke replaces it; an existing edit lands the caret at the end.
            if editor.wasNewlyCreated {
                textView.selectAll(nil)
            } else {
                // UTF-16 length (not Character count) so the caret lands correctly
                // after multibyte / composed text.
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }

        /// Place the overlay from the tile's live screen frame (imperative, R15). A
        /// `nil` frame means the tile scrolled out → commit-and-exit (§5.4). Auto
        /// modes re-measure the CURRENT string through `TextMetrics` (the SAME source
        /// as the committed box) and resize ONLY the overlay — no engine sync, no
        /// `renderRevision` bump (§5.2 · R16).
        func reposition() {
            guard let frame = bridge.screenFrame(forTileID: editor.tileID) else {
                if inlineEditShouldCommitOnViewportExit(screenFrame: nil) { finish(committed: true) }
                return
            }
            let scale = bridge.scale
            applyFontScale() // keep the editor glyphs matched to the canvas zoom
            let padScreen = TextMetrics.padding * scale
            var target = frame

            switch editor.style.resize {
            case .fixed:
                break
            case .autoWidth, .autoHeight:
                var ts = ElementRendering.textStyle(for: editor.style)
                ts.string = textView.string
                let maxWidth: CGFloat? = editor.style.resize == .autoHeight
                    ? max(1, frame.width / scale - 2 * TextMetrics.padding)
                    : nil
                let measured = TextMetrics.size(for: ts, maxWidth: maxWidth)
                let width = editor.style.resize == .autoWidth
                    ? measured.width * scale + 2 * padScreen
                    : frame.width
                let height = measured.height * scale + 2 * padScreen
                target = CGRect(x: frame.minX, y: frame.minY, width: width, height: height)
            }

            textView.textContainerInset = NSSize(width: padScreen, height: padScreen)
            textView.frame = target
        }

        /// Resolve the outcome ONCE (guarded) and dispatch. Clears the reposition hook
        /// so a late transform notification can't touch a torn-down editor.
        private var bridge: CanvasEditingBridge { editor.bridge }

        func finish(committed: Bool) {
            guard commitGuard.begin() else { return } // double-commit guard (§5.3)
            bridge.onReposition = nil
            switch inlineEditOutcome(
                text: textView.string, wasNewlyCreated: editor.wasNewlyCreated, committed: committed) {
            case .cancel: editor.onCancel()
            case .deleteElement: editor.onDelete()
            case .persist(let string): editor.onCommit(string)
            }
        }

        // NSTextViewDelegate --------------------------------------------------

        /// Editor-only live growth for auto modes — re-place from the new string; no
        /// engine sync per keystroke (§5.2 · R16 / R14).
        func textDidChange(_ notification: Notification) { reposition() }

        /// Blur (click-away / focus loss) commits (054 §5.2). The guard makes this a
        /// no-op when a ⌘↵ / Esc already finished.
        func textDidEndEditing(_ notification: Notification) { finish(committed: true) }

        // Font construction ---------------------------------------------------

        /// The display `NSFont` for a style at the current zoom — mirrors
        /// `CanvasRenderer.CanvasFont` (internal there): family via `NSFontManager`,
        /// else the system font, at the mapped weight. `scale` matches the on-canvas
        /// `fontSize × transform.scale`, so the editor glyphs never differ in size
        /// from the tile they overlay.
        private static func nsFont(for style: ElementStyle, scale: CGFloat) -> NSFont {
            let size = CGFloat(style.fontSize ?? ElementRendering.defaultFontSize) * max(0.01, scale)
            let systemWeight: NSFont.Weight
            let legacyWeight: Int
            switch style.weight {
            case .regular: systemWeight = .regular; legacyWeight = 5
            case .medium: systemWeight = .medium; legacyWeight = 6
            case .semibold: systemWeight = .semibold; legacyWeight = 8
            case .bold: systemWeight = .bold; legacyWeight = 9
            }
            if let family = style.fontFamily, !family.isEmpty,
               let font = NSFontManager.shared.font(
                   withFamily: family, traits: [], weight: legacyWeight, size: size) {
                return font
            }
            return NSFont.systemFont(ofSize: max(1, size), weight: systemWeight)
        }
    }
}

// MARK: - Live AppKit pieces

/// The flipped host for the `NSTextView`, sized to the canvas. Its `hitTest` passes
/// clicks that miss the text box through to the canvas beneath — so clicking away
/// makes the canvas first responder and blurs the editor (→ commit, §5.2/5.4) —
/// while the box itself still receives typing/selection.
final class PassThroughContainer: NSView {
    weak var textView: NSView?
    var onMovedToWindow: (() -> Void)?

    override var isFlipped: Bool { true } // match CanvasHostView's top-left origin

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // A hit on the container itself (empty area) falls through to the canvas.
        return hit === self ? nil : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }
}

/// An `NSTextView` that intercepts ⌘↵ (commit) and Esc (cancel) before the normal
/// text-editing key handling. Everything else types as usual.
final class InlineNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
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
