//
//  CanvasTextEdit.swift
//  CanvasRenderer
//
//  The inline text-editing contract, and the pure decisions behind it.
//
//  Editing a text box lives in the renderer rather than in the app because it is a
//  canvas gesture: it starts on a double-click, it has to be glued to a tile's
//  on-screen frame through every pan, zoom, move and resize, and it has to hold first
//  responder without racing anything. It used to be a SwiftUI `NSViewRepresentable`
//  mounted beside the canvas, which meant the "begin editing" decision travelled
//  AppKit → closure → `@State` → view update → `viewDidMoveToWindow` before a caret
//  ever appeared — four hops during which the tile could move, the host could be
//  rebuilt, or the edit could commit itself.
//
//  What stays in the app is POLICY: what a committed string means, whether an empty
//  box should be deleted, how a style is persisted. The renderer asks; the app answers.
//
//  Everything here is a value type or a pure function, so the lifecycle is testable
//  without a window (the `NSTextView` first-responder / IME behaviour is not, and is
//  verified by hand).
//

import CoreGraphics

// MARK: - The seam

/// A request to begin editing a tile's text, as a value.
///
/// It is a token-keyed VALUE rather than a method call because the app drives it from
/// SwiftUI, where the same state may be pushed many times: creating a text box has to
/// wait for the row to be written before it knows the tile id, so the request is set
/// once and re-delivered on every subsequent view update until the host consumes it.
/// The `token` is what makes that idempotent — and what lets the same tile be edited
/// twice in a row, which an id alone could not express.
public struct CanvasTextEditRequest: Equatable, Sendable {
    /// The tile whose text should be edited.
    public var tileID: Int
    /// Whether this box was just created, which is the only thing that makes an empty
    /// commit mean "delete me" rather than "clear my text".
    public var isNewlyCreated: Bool
    /// Monotonic; a new value means "this is a new request, act on it".
    public var token: Int

    public init(tileID: Int, isNewlyCreated: Bool, token: Int) {
        self.tileID = tileID
        self.isNewlyCreated = isNewlyCreated
        self.token = token
    }
}

/// What an inline edit turned out to mean (054 §5.3 · R8). The renderer decides which
/// of these happened; the app decides what each one does to its model.
public enum CanvasTextEditOutcome: Equatable, Sendable {
    /// Write this string back. The app owns re-measuring and persisting.
    case committed(String)
    /// Abandon the edit — no write (Esc, or the double-commit guard).
    case cancelled
    /// Remove the element entirely: an empty box the user had only just created, so it
    /// leaves no invisible orphan behind (054 §5.3).
    case deleted
}

// MARK: - Pure lifecycle decisions

/// The commit / cancel / delete decision for an inline edit (054 §5.3 · R8).
///
/// - `committed == false` → `.cancelled` (Esc / abandoned): never write.
/// - empty text, newly created → `.deleted`: an untouched new box is removed.
/// - empty text, pre-existing → `.committed("")`: an explicit clear is honoured (the
///   element stays; its string becomes empty).
/// - non-empty → `.committed(text)`.
///
/// "Empty" is whitespace/newline-insensitive, so a box holding only spaces reads as
/// empty for the delete-new-box rule. Emptiness is derived HERE rather than passed in,
/// so no caller can re-derive it differently.
public func canvasTextEditOutcome(
    text: String, isNewlyCreated: Bool, committed: Bool
) -> CanvasTextEditOutcome {
    guard committed else { return .cancelled }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return isNewlyCreated ? .deleted : .committed("")
    }
    return .committed(text)
}

/// The WORLD-space box an inline editor lays text out in — the pure geometry half of
/// placing the overlay.
///
/// The whole point is what is MISSING from the result: zoom. `scale` appears only to
/// map the tile's screen frame back into world units, so for a given tile this returns
/// the same box at every zoom — which is what keeps the text system from re-wrapping as
/// you pinch, and what makes the editor's line breaks agree with the committed box
/// (measured against the same world width).
///
/// The width is the tile's — the user owns it, and only a resize-handle drag changes it
/// (062). The height follows `measuredWorldSize`, so the editor grows and shrinks
/// exactly as the committed box will.
/// Main-actor isolated only because its default `padding` reads ``TextMetrics``, which
/// is — the arithmetic itself is pure.
@MainActor
public func canvasInlineEditorWorldBox(
    tileScreenFrame: CGRect,
    scale: CGFloat,
    measuredWorldSize: CGSize,
    padding: CGFloat = TextMetrics.padding
) -> CGSize {
    // A degenerate camera must not divide by zero — clamp rather than trap.
    let scale = max(0.0001, scale)
    return CGSize(
        width: tileScreenFrame.width / scale,
        height: measuredWorldSize.height + 2 * padding)
}

/// Whether an open edit should commit because its tile has left the viewport
/// (054 §5.4).
///
/// The two guards are the point. "Not visible" only means something once the canvas
/// knows how big it is AND the editor has placed itself at least once — before either,
/// nothing is visible by definition. An earlier version asked only whether a screen
/// frame existed, read the pre-layout answer as *the tile scrolled away*, and committed
/// the edit the instant it mounted. So an editor that has never positioned holds its
/// ground; only a tile that was on screen and then left commits.
public func canvasInlineEditShouldCommitOnViewportExit(
    isVisible: Bool, viewportSize: CGSize, hasPositioned: Bool
) -> Bool {
    guard hasPositioned, viewportSize.width > 0, viewportSize.height > 0 else { return false }
    return !isVisible
}

/// One-shot guard: the FIRST finish wins, and a later blur / Esc / commit-during-undo
/// is ignored, so an edit can never write twice. A value type so the rule is testable.
public struct CanvasCommitGuard {
    public private(set) var finished = false

    public init() {}

    /// Returns `true` exactly once — for the first caller — and `false` thereafter.
    public mutating func begin() -> Bool {
        if finished { return false }
        finished = true
        return true
    }
}
