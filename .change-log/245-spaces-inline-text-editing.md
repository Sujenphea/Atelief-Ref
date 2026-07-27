# 245 — Spaces: inline on-canvas text editing (2B)

The final slice of the Spaces Text Phase-2 epic (053/054/055). Double-clicking a
`.text` element now edits its **string in place** on the canvas via a transparent
`NSTextView` overlay; the inspector popover keeps the **style** controls (D3).
Frames still open the popover (they have no inline path). Builds on 2A (241) +
2C (244); no DB schema change.

Implements plan Steps 6–7 (055) = Commit C.

## Summary

- **Step 6 — boundary seam (CanvasRenderer, infra):**
  - `CanvasEngine` emits `onTransformChanged` exactly **once** per transform
    mutation (`pan` / `zoom` / `setTransform`, so `frameToContent` for free) — the
    single choke point the editor rides (054 §5.1 · R2). Notified AFTER `sync()` so
    a listener reads post-mutation geometry.
  - `CanvasEngine.editingTileID` blanks the edited tile's `CATextLayer` in `sync()`
    so the live `NSTextView` glyphs aren't doubled beneath (§5.2 · R16).
  - `CanvasHostView` exposes `var transform`, `func screenFrame(forTileID:)`,
    `var editingTileID`, and forwards `onTransformChanged` (wired from the engine in
    `init`).
  - `CanvasView` forwards `onTransformChanged` + `editingTileID` + a new
    `onHostReady` (hands the live host to the app for the editor). **No
    `Binding<CGRect?>`** — the editor positions itself imperatively (R15).

- **Step 7 — inline editor overlay (AtelierRefs):**
  - New `InlineTextEditor.swift` (`NSViewRepresentable` + Coordinator): a
    transparent, flipped, pass-through overlay whose Coordinator sets
    `textView.frame` from `screenFrame(forTileID:)` on each `onTransformChanged` —
    **off the SwiftUI diff** (no per-frame `body` re-eval, R15). Auto modes re-measure
    the current string through `TextMetrics` (the same source as the committed box)
    and resize **only the overlay** per keystroke — no engine `sync()`, no
    `renderRevision` bump (§5.2 · R16/R14).
  - Commit on ⌘↵ / blur → the model's existing `updateStyle` path (2C — one undo
    step, auto-size + one `sync()`); Esc = cancel; a tile that scrolls out of the
    viewport commits-and-exits (§5.4).
  - Pure, unit-tested lifecycle: `inlineEditOutcome(text:wasNewlyCreated:committed:)`
    (persist / cancel / delete-empty-new-box), `inlineEditShouldCommitOnViewportExit`,
    and a one-shot `CommitGuard` (blocks the blur+Esc / commit-during-undo double
    write — the `ElementInspector.finished` pattern).
  - `SpaceView`: double-click `.text` → enter inline edit (frames still open the
    popover); a new-text-box create enters edit immediately once the write settles.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — `onTransformChanged`,
  `editingTileID` (+ blank-while-editing in `sync`), emit in `pan`/`zoom`/`setTransform`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `transform`,
  `screenFrame(forTileID:)`, `editingTileID`, `onTransformChanged` forward.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — forward
  `onTransformChanged` + `editingTileID` + `onHostReady`.
- `CanvasRenderer/Tests/CanvasRendererTests/TransformSeamTests.swift` — **new**
  (Step 6 seam tests).
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — **new** (overlay + pure logic).
- `AtelierRefs/AtelierRefs/SpaceView.swift` — inline-edit state, wiring, overlay,
  double-click routing.
- `AtelierRefsTests/SpaceInlineEditTests.swift` — **new** (pure lifecycle matrix).

## Tests

- `swift test` (CanvasRenderer) — 171 tests pass, incl. the 8-test
  `Canvas transform seam` suite (pan-shift, zoom-about-anchor, once-per-mutation
  spy incl. `frameToContent`, editing blanks/restores the overlay).
- `xcodebuild test -scheme AtelierRefs -only-testing:AtelierRefsTests/SpaceInlineEditTests`
  — the pure `inlineEditOutcome` matrix, viewport-exit predicate, and double-commit
  guard.

## Spec interpretation / deviations

- **`inlineEditOutcome` signature:** the design lists `(wasNewlyCreated:textIsEmpty:
  committed:)`, but the `.persist(String)` case needs the actual string, so the
  predicate takes `text: String` and derives emptiness internally (one source; the
  matrix is unchanged). "Empty" is whitespace/newline-insensitive for the
  delete-new-box rule.
- **Editor display font:** `CanvasRenderer.CanvasFont` (the single typeface source)
  is `internal` to the package, so the transient editing glyphs are built in the app
  with the SAME family/weight mapping. The **persisted** result is still measured +
  drawn through `TextMetrics` / `CanvasFont`, so the committed box can't drift.
- **`onHostReady`:** added to `CanvasView` (not enumerated in 055) as the minimal
  mechanism to hand the live `CanvasHostView` to the app so the editor can reach
  `transform` / `screenFrame(forTileID:)` — the two seam methods 054 §5.1 exposes
  on the host.

## Manual-verification checklist (live `NSTextView` lifecycle — PENDING)

The first-responder / IME / blur lifecycle can only be exercised in the running
app. All headless logic is covered above; the following are **pending manual
verification** by a human (not done):

- [ ] Double-click a text tile → the inline editor appears over the tile and takes focus.
- [ ] Type → glyphs update live; the underlying `CATextLayer` is blanked (no doubling).
- [ ] Pan / zoom while editing → the editor tracks the tile exactly (imperative reposition).
- [ ] Auto-width / auto-height box grows live per keystroke (overlay only; canvas not re-synced).
- [ ] ⌘↵ commits → the tile shows the new text at the committed size.
- [ ] ⌘Z after a commit reverts BOTH the text and the auto-sized box in one step.
- [ ] Esc cancels → no write; the original text is retained.
- [ ] Create a new text box, type nothing, click away → the empty box is deleted (no orphan).
- [ ] Clear an existing box's text and commit → the element persists with empty text.
- [ ] Scroll the tile out of the viewport while editing → commits-and-exits.
- [ ] IME / multibyte input (e.g. CJK, emoji) composes and commits correctly.
- [ ] Double-click a FRAME → still opens the style popover (unchanged).
