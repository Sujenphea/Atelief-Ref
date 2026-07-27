# 054 — Spaces Text (Phase 2): Design Spec

> The spec for [053](./053-spaces-text-overview.md). Concrete types, seam changes,
> the measurement helper, the inline-editor mechanics, and edge cases. Plan:
> [055](./055-spaces-text-plan.md).
>
> **Revised 2026-07-26** after the full review (16 issues, all resolved). Review
> deltas are marked inline as *(Rn)*.

## 1. Model — `ElementStyle` additions (2A + 2C)

`AtelierCore/.../Domain/SpaceItem.swift`. All optional → **no migration** (D1).

```swift
public struct ElementStyle: Codable, Equatable, Sendable {
    // existing
    public var text: String?
    public var fontSize: Double?
    public var textColor: String?
    public var fillColor: String?
    public var strokeColor: String?
    public var strokeWidth: Double?
    // NEW (Phase 2)
    public var fontFamily: String?   // family name (NSFont family); nil → system
    public var fontWeight: String?   // TextWeight rawValue; nil → .regular
    public var textAlign: String?    // TextAlign rawValue; nil → .left
    public var resizeMode: String?   // TextResize rawValue; nil → .fixed
}
```

Store **semantic string tokens**, not raw enum ints — explicit over clever (a
hand-editable, self-describing, forgiving blob; forward-compatible). Tokens are
backed by three small enums in `AtelierCore` (the domain owns its vocabulary):

```swift
public enum TextWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold           // D-Weight: the 4-token set
}
public enum TextAlign: String, Codable, CaseIterable, Sendable {
    case left, center, right
}
public enum TextResize: String, Codable, CaseIterable, Sendable {
    case fixed        // box w/h authoritative; text wraps + truncates (today)
    case autoWidth    // one line; width grows to the text, height to the line
    case autoHeight   // width fixed (create-time); height grows to wrapped text
}
```

`TextResize` stays **domain/app-only** — it never crosses into the renderer *(R1
· Issue 1)*; only weight + alignment do (§2), because the renderer needs them to
draw.

### 1.1 Typed accessors — one owned default per field *(R7 · Issue 7)*

Storage stays `String?` (forgiving decode, no migration). Parsing + defaulting
lives in **one** place — computed accessors on `ElementStyle` — so no reader
re-implements the parse or picks its own default:

```swift
extension ElementStyle {
    var weight: TextWeight { TextWeight(rawValue: fontWeight ?? "") ?? .regular }
    var align:  TextAlign  { TextAlign(rawValue: textAlign ?? "")  ?? .left }
    var resize: TextResize { TextResize(rawValue: resizeMode ?? "") ?? .fixed }
}
```

Every reader (renderer bridge §3, inspector §6, `SpaceModel` §4) uses
`style.weight` / `.align` / `.resize`. An unknown/malformed token degrades to the
default, never throws — the "forgiving blob" property D1 depends on is preserved.
**Default resize-mode is `.fixed`** so every existing text element behaves exactly
as today (Open-Q 3).

## 2. Renderer seam — `TextStyle` additions (2A)

`CanvasRenderer/.../TileContent.swift`. Mirror only weight + alignment as
`Sendable` value types (the renderer can't import `AtelierCore` — 1A):

```swift
public enum FontWeight: String, Hashable, Sendable { case regular, medium, semibold, bold }
public enum TextAlignment: String, Hashable, Sendable { case left, center, right }

public struct TextStyle: Equatable, Hashable, Sendable {
    public var string: String
    public var fontSize: Double            // world units (unchanged)
    public var color: RGBAColor
    public var fontFamily: String?         // NEW; nil → system font
    public var weight: FontWeight          // NEW; default .regular
    public var alignment: TextAlignment    // NEW; default .left
}
```

Defaulted memberwise init so existing call sites (`ElementRendering` frame-label
+ media-less-card builders) compile unchanged. The `FontWeight`/`TextAlignment`
rawValues **match** the `AtelierCore` tokens; that convention is enforced by a
conformance test, not a comment *(R5 · Issue 5, see §8)*.

### 2.1 Font construction — the single source, memoized *(R13 · Issue 13)*

```swift
// CanvasRenderer/.../TextMetrics.swift  (new)
enum CanvasFont {
    /// The typeface for a style, memoized by (family, weight). Family nil → the
    /// system font at the mapped weight; an unknown family → system fallback
    /// (never nil, never blank text). Callers set point size separately.
    static func resolve(family: String?, weight: FontWeight) -> CTFont
}
```

- Weight maps `regular→.regular … bold→.bold` (`NSFont.Weight`).
- Family nil → `NSFont.systemFont(ofSize:weight:)`; set → resolve via
  `NSFontManager.font(withFamily:traits:weight:size:)`; nil result → system.
- **Memoized by `(family, weight)`** in a small dict, because `setTextOverlay`
  runs per visible text tile **every `sync()` frame** (pan/zoom hot path); the
  typeface only changes on a style change, so resolving it per frame is waste.
  The cache is bounded by the distinct family/weight combos on the board.

### 2.2 `setTextOverlay` changes (`CanvasEngine.swift:447`)

```swift
text.font = CanvasFont.resolve(family: style.fontFamily, weight: style.weight) // cached
text.fontSize = CGFloat(max(1, style.fontSize)) * transform.scale              // per-frame, cheap
text.alignmentMode = style.alignment.caAlignment                              // .left/.center/.right
```

`CATextLayer.font` sets the typeface; `fontSize` still carries the zoom-scaled
size, so glyphs stay crisp at any zoom. `isWrapped`/`truncationMode` stay as-is
for `.fixed`; auto-modes are handled by sizing the box (§4), not by changing
wrapping.

## 3. Bridge — `ElementRendering.tileContent` (2A)

`AtelierRefs/.../ElementRendering.swift:43–69`. Pass the new fields through using
the typed accessors (§1.1), crossing weight/alignment by a `rawValue` hop:

```swift
return .text(TextStyle(
    string: style.text ?? "",
    fontSize: style.fontSize ?? defaultFontSize,
    color: rgba(fromHex: style.textColor) ?? defaultTextRGBA,
    fontFamily: style.fontFamily,
    weight: FontWeight(rawValue: style.weight.rawValue) ?? .regular,
    alignment: TextAlignment(rawValue: style.align.rawValue) ?? .left))
```

(The `?? .regular`/`?? .left` here are the conformance-test-guaranteed no-ops —
§8 fails CI if a token can't cross.)

## 4. Resize-mode + measurement (2C)

### 4.1 The measurement helper — pure, mode-agnostic *(R1 · Issue 1)*

```swift
// CanvasRenderer/.../TextMetrics.swift
enum TextMetrics {
    static let padding: CGFloat = …  // world-space inset (see §4.3)

    /// World-space size the text occupies, measured with the SAME font as
    /// drawing (`CanvasFont.resolve`) at the world `fontSize`, so it's
    /// zoom-independent. `maxWidth == nil` → unconstrained (one-line / autoWidth);
    /// a value → width-constrained wrapping (autoHeight). Padding is added on the
    /// measured axes by the caller policy (§4.2). Knows nothing of `TextResize`.
    static func size(for style: TextStyle, maxWidth: CGFloat?) -> CGSize
}
```

`NSAttributedString` built from `CanvasFont.resolve(...)` at world `fontSize`;
`boundingRect(with:options:.usesLineFragmentOrigin)` unconstrained (nil) or
constrained to `maxWidth`. The **app** maps `TextResize → maxWidth?` and whether
to call at all.

### 4.2 Where auto-size runs + who writes `w/h`

The app owns the mode→measurement policy (`SpaceModel`):

| mode | measure call | result → frame |
|---|---|---|
| `fixed` | — (skip) | no geometry write |
| `autoWidth` | `size(for:, maxWidth: nil)` | `w` = text + 2·pad, `h` = line + 2·pad |
| `autoHeight` | `size(for:, maxWidth: box.w − 2·pad)` | `h` = wrapped + 2·pad, `w` frozen |

Top-left **anchor**: `x`/`y`/`z` are always frozen; the box grows right/down. Auto
recompute fires when the **text**, **fontSize**, **fontFamily**, **fontWeight**,
or **resizeMode** changes.

```swift
// SpaceModel — nil unless mode is auto AND the fit changed.
func autosizedFrame(item: SpaceItem, style: ElementStyle) -> CGRect?
```

**Width-adjust is deferred** *(R4 · Issue 4 · D7)*: the canvas has no resize
handles, so `autoHeight`'s constraining width is the **create-time** width and
`fixed` is as-drawn. There is no "width drag" input in Phase 2 (removed from the
spec). Handles are a Phase-3 affordance (050).

### 4.3 Atomic restyle + resize *(R6 · Issue 6 · D5)*

Auto-size is *derived from* the style, so the two writes are logically one edit.
A new **combined service transaction** persists both in a single GRDB `db.write {}`
and registers **one** undo step:

```swift
// AppServices
func updateSpaceItemStyleAndPlacement(id:, style:, placement: SpaceItemPlacement?) throws
// SpaceModel.performRestyle: build style → autosizedFrame → one call → one undo
//   ("Restyle Text"), bump renderRevision once so the canvas re-syncs.
```

A `.fixed` restyle passes `placement: nil` and writes no geometry (the common
path has zero new writes). One ⌘Z reverts style **and** size together.

### 4.4 Rendering-padding reconciliation *(R12 · Issue 12)*

`setTextOverlay` currently insets `.text` tiles by a **screen-space** `pad =
min(6, screenFrame.width·0.04)` (`CanvasEngine.swift:469`) — zoom-dependent, so it
can't match a world-space measurement. Fix: for `.text` tiles use a **fixed world
padding** (`TextMetrics.padding`, mapped `×scale` at draw time) so the drawn inset
== the measured inset at **every** zoom. Frame **labels** keep the current screen
pad (not auto-sized). This is the one non-additive renderer change; it **changes
text-tile pixels at zoom ≠ crossover**, so the "byte-identical" claim holds only
for frame labels — the intended invariant (draw inset ≡ measure inset across zoom)
gets a characterization test (§8), and the pixel change is noted in the changelog.

## 5. Inline on-canvas editing (2B)

### 5.1 The exposed seam (renderer → SwiftUI), notification from the engine *(R2 · Issue 2)*

- **`CanvasEngine`** — emit an `onTransformChanged: (() -> Void)?` (or a bumped
  revision) inside `pan` / `zoom` / `setTransform` — the **single** transform
  mutation choke point. `frameToContent()` and any future source get it for free.
- **`CanvasHostView`** — forward `onTransformChanged` outward; add
  `public var transform: CanvasTransform { engine.transform }` and
  `public func screenFrame(forTileID:) -> CGRect? { engine.currentScreenFrame(forTileID:) }`.
- **`CanvasView` (NSViewRepresentable)** — forward `onTransformChanged` and an
  `editingTileID: Int?` input. **No `Binding<CGRect?>`** *(R15 · Issue 15)* — the
  editor positions itself imperatively (§5.2).

### 5.2 The editor — imperative, off the SwiftUI diff path *(R15 · Issue 15)*

`AtelierRefs/.../InlineTextEditor.swift` — an `NSViewRepresentable` around
`NSTextView`. Its **Coordinator** subscribes to `onTransformChanged` and sets
`textView.frame` **directly** from `screenFrame(forTileID: editingTileID)` — so a
pan/zoom during editing does **not** re-evaluate `SpaceView.body`. Font/size/color
/alignment come from `CanvasFont`; transparent background; first responder on
appear.

- **Enter:** double-click a `.text` element (`SpaceView.swift:186`) → set
  `editingTileID` (frames still open the popover). Finishing a *create* of a new
  text box (`onCreateElement → addText`) enters edit immediately.
- **Live growth is editor-only** *(R16 · Issue 16)*: while editing, the underlying
  `CATextLayer` string is blanked (no double glyphs); the visible text is the
  `NSTextView`. For auto-modes the box grows by re-measuring **per keystroke**
  *(R14 · Issue 14 — cheap for short moodboard text; if long paragraphs become
  common, add runloop coalescing)* and resizing **only the overlay** — **no**
  `renderRevision` bump, **no** `engine.sync()` per keystroke.
- **Commit:** ⌘↵ or blur → `updateStyle` (§4.3, one undo step, exactly **one**
  `sync()`); clear `editingTileID`. Esc = cancel (no write). Tile leaves the
  viewport (`screenFrame` → nil) → commit-and-exit (§5.4).

### 5.3 Commit / cancel / delete-empty — a pure, tested predicate *(R8 · Issue 8)*

The lifecycle decision is isolated as one pure function (mirroring how
`ElementInspector.builtStyle()` isolates pure logic), unit-tested exhaustively:

```swift
enum InlineEditOutcome { case persist(String), cancel, deleteElement }
func inlineEditOutcome(wasNewlyCreated: Bool, textIsEmpty: Bool, committed: Bool) -> InlineEditOutcome
// committed==false            → .cancel
// empty & wasNewlyCreated     → .deleteElement   (no invisible orphan boxes)
// empty & !wasNewlyCreated    → .persist("")     (explicit ⌫ / Delete removes)
// non-empty                   → .persist(text)
```

A **double-commit guard** flag (the `ElementInspector.finished` pattern,
`:23–25`) prevents blur+Esc / commit-during-undo from writing twice.

### 5.4 Trade-off recorded (D6)

The editor could instead be a child `NSView` inside `CanvasHostView` that the
engine positions in `sync()` (rides the exact tile math, no callback). Rejected
for Phase 2: it pulls `NSTextView`/IME/commit concerns into the lean renderer
(which `031`/`ElementInspector` deliberately kept clean) and couples the editor
lifecycle to the engine. The app-layer overlay keeps the renderer additive; the
cost is the `onTransformChanged` plumbing — small, engine-sourced (§5.1), and
independently testable (§8).

## 6. Inspector (`ElementInspector.swift`) — style controls (2A + 2C)

- **`.text` editor** (`:89`): **remove the string `TextField`** *(R3 · Issue 3)* —
  the string is edited on-canvas (§5). Add a **font-family** `Picker`
  (`NSFontManager.availableFontFamilies`, "System" = nil sentinel), a **weight**
  segmented `Picker` (`TextWeight.allCases`), an **alignment** segmented `Picker`
  (`TextAlign.allCases`, SF Symbols `text.align{left,center,right}`), and a
  **resize-mode** `Picker` (`TextResize.allCases`).
- **`.frame` editor** (`:105`): **keeps** its label `TextField` (frames have no
  inline path). No resize-mode (frames aren't auto-sized).
- `builtStyle()` (`:126`) writes the four new tokens for `.text`.

## 7. Backward compatibility & invariants

- Legacy rows: all four fields `nil` → system font, regular, left, fixed = today's
  exact rendering (pinned by a decode-to-defaults test).
- Frames unaffected: labels pass `.regular/.left/system`; resize-mode is `.text`-
  only; the frame-label pad is unchanged.
- Auto-size never fires for `.fixed`; the common path adds zero writes and zero
  syncs.
- One font/measure source (`CanvasFont`/`TextMetrics`) ⇒ drawn size ≡ measured
  size at every zoom — the "auto-box a few px off the glyphs" class is structurally
  excluded (the `CanvasTransform` discipline, reused).

## 8. Test surface (summary — full plan in [055](./055-spaces-text-plan.md))

- **Enum conformance** *(R5)*: every `AtelierCore` weight/align token has a
  matching `CanvasRenderer` token, both directions (`allCases`). Fails CI on drift.
- **Typed accessors** *(R7)*: unknown/nil token → correct default; round-trip.
- **`CanvasFont` / `TextMetrics`** *(R10)*: assert the **resolved font's**
  family/weight/pointSize (nil→system, unknown→system never nil); **bounded +
  monotonic** sizing (longer→wider, larger size→taller, more lines→taller,
  autoWidth height ≈ one line, padding present) — no brittle exact-pixel pins.
- **Auto-size write path** *(R9)*: at the `SpaceArrangeTests` bar — exact frozen
  axes, top-left anchor invariance across **grow and shrink**, shrink-back, "one
  step" via next-undo-name, `renderRevision` bumped on resize / not on `.fixed`.
- **Padding reconciliation** *(R12)*: drawn text inset == `TextMetrics.padding ×
  scale` at zoom ∈ {0.5, 1, 2, 4}; byte-identical for frame labels only.
- **Transform seam** *(R11)*: after a known pan, `screenFrame` == pre-pan frame
  shifted by exactly the delta; zoom scales about the anchor; `onTransformChanged`
  fires once per mutation.
- **Inline-edit outcome** *(R8)*: the pure `inlineEditOutcome` matrix incl.
  delete-empty-new-box + the "tile-left-viewport → commit" predicate.
