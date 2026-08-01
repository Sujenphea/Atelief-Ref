//
//  SpaceArrangeGroups.swift
//  AtelierRefs
//
//  069 — the `.multi` action bar's ops, collapsed behind three group buttons.
//
//  The bar rendered sixteen glyphs at a multi-selection: undo/redo, then a flat
//  `ForEach` over all nine `CanvasArrange.Operation` cases, the gap ruler, duplicate,
//  two z-order buttons, and the export pair. Nine of the sixteen came from one loop,
//  and the row roughly doubled in width the instant a second tile was selected. This
//  folds the six aligns into one button, distribute + tidy + gap into a second, and
//  the two z-order buttons into a third — sixteen down to eight.
//
//  What lives here is the GROUPING and the two simple panels. The spacing panel is
//  its own file (``SpaceSpacingPopover``) because it carries a focusable field and
//  the reasoning that goes with it.
//
//  The grouping itself (``ArrangeGroup``) is pure and unit-tested, for the same
//  reason `barMode` and `isEnabled(selectionCount:)` are: a group's trigger has to
//  stay live while ANY op inside it would still run, and getting that backwards
//  locks the user out of a Tidy Up that would have worked (see `isEnabled` below).
//

import SwiftUI

// MARK: - Grouping (pure)

/// The three groups the action bar collapses its ops behind. Also the identity of
/// the ONE open panel — `SpaceView` binds a single `SpaceBarGroup?`, so two panels
/// structurally cannot race over the same corner of the canvas.
///
/// **All three panels take `popoverContent()`'s default `lg` inset. Keep it that
/// way.**
///
/// This is a deliberate departure from `selectionMenuChrome()`, which uses `xs` on
/// the reasoning that "this one's ROWS carry their own inset (they are the click
/// targets), so a wide outer pad would double it" — true of the align grid's 30×28
/// glyphs and of ``ZOrderRow`` as well. That rule optimises for equal PERCEIVED air
/// between one panel's content and its border.
///
/// These three optimise for something else, because they are used differently: they
/// open from adjacent buttons in one bar, so they are seen in succession, and the
/// thing a user reads is the FRAME jumping between them. A shared inset is what makes
/// the three feel like one control with three faces. Every other `lg` popover in the
/// app (AddColour, AddLink, the two exports, `ElementInspector`) is a form, so this
/// also keeps the panels in step with the app's most common surface.
///
/// The trade is real and accepted: content that carries its own margin gets padded
/// twice, so align and z-order sit airier than ``SpaceSpacingPopover``'s form. Don't
/// "fix" that by reverting one panel to `xs` — that just reintroduces the frame jump
/// this chose to remove.
/// Isolation follows `CanvasArrange`'s (main-actor, like the rest of the module) —
/// not `SpaceBarMode`'s `nonisolated`, which it can afford only because it reads
/// nothing but an `Int`. This reads `minimumCount` off every child op.
enum SpaceBarGroup: CaseIterable, Identifiable {
    /// The six bounding-box aligns.
    case align
    /// Everything that decides how much room sits between items: the two
    /// distributes, Tidy Up, and the exact-gap pack.
    case spacing
    /// Bring to Front / Send to Back.
    case zOrder

    var id: Self { self }

    /// The `CanvasArrange` ops behind this group's button, in panel order.
    ///
    /// Empty for `.zOrder` — restacking rows isn't an arrange op (it doesn't move a
    /// rect, so it has no `minimumCount` to read), which is exactly why `isEnabled`
    /// treats it separately rather than deriving from this list.
    var operations: [CanvasArrange.Operation] {
        switch self {
        case .align:
            [.alignLeft, .alignHorizontalCenter, .alignRight,
             .alignTop, .alignVerticalCenter, .alignBottom]
        case .spacing:
            [.distributeHorizontal, .distributeVertical, .tidyUp]
        case .zOrder:
            []
        }
    }

    /// The glyph on the collapsed trigger. Static — a multi-selection has no
    /// "current" alignment or spacing to mirror, unlike the text bubble's align
    /// segment, so there is no honest state for the button to show. No chevron
    /// either: the trigger keeps the exact weight of every other bar glyph.
    var symbol: String {
        switch self {
        case .align: "align.horizontal.left"
        case .spacing: "arrow.left.and.right"
        case .zOrder: "square.3.layers.3d"
        }
    }

    var help: String {
        switch self {
        case .align: "Align the selection"
        case .spacing: "Distribute, tidy or space the selection"
        case .zOrder: "Order the selection front to back"
        }
    }

    /// The trigger is live while ANY op inside would run — not while all of them
    /// would.
    ///
    /// The distinction is the whole reason this is a tested function rather than a
    /// literal. At a 2-item selection the distributes are dead (they need 3) but Tidy
    /// Up and the exact gap are not, and two items are exactly when a user reaches for
    /// a tidy. Gating the trigger on the group's headline op would bury both behind a
    /// dimmed button. The dead ops still dim INSIDE the panel, which preserves the
    /// bar's existing dimmed-not-hidden reading of "not yet" (051 · 12A).
    ///
    /// `.zOrder` owns no ops, so it takes the floor directly: restacking means
    /// something at any selection size, which is why it appears in `.single` too.
    func isEnabled(selectionCount: Int) -> Bool {
        if self == .zOrder { return selectionCount >= 1 }
        return operations.contains { $0.isEnabled(selectionCount: selectionCount) }
    }
}

// MARK: - Symbols

/// The SF Symbol for each arrange op. Lives in the view layer so `CanvasArrange`
/// stays geometry-only (051 · 1A), and in its own type rather than `SpaceView`'s so
/// the bar and the group panels read the same table.
enum SpaceArrangeSymbols {
    static func symbol(for op: CanvasArrange.Operation) -> String {
        switch op {
        case .alignLeft: "align.horizontal.left"
        case .alignHorizontalCenter: "align.horizontal.center"
        case .alignRight: "align.horizontal.right"
        case .alignTop: "align.vertical.top"
        case .alignVerticalCenter: "align.vertical.center"
        case .alignBottom: "align.vertical.bottom"
        case .distributeHorizontal: "arrow.left.and.right"
        case .distributeVertical: "arrow.up.and.down"
        case .tidyUp: "square.grid.2x2"
        }
    }
}

// MARK: - Shared panel atoms

/// One glyph inside a group panel: the bar's own 30×28 ``SelectionBarIcon``, so a
/// collapsed op looks identical to the button it used to be in the bar. Dimmed
/// rather than hidden below its `minimumCount`.
struct ArrangeGlyphButton: View {
    let systemName: String
    let help: String
    let isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            SelectionBarIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

// MARK: - Align panel

/// The six aligns, in two rows: horizontal above, vertical below (Figma's
/// arrangement). Icon-only — `align.horizontal.left` and its five siblings ARE the
/// diagram, and labelling them would triple the panel for no added meaning.
///
/// Nothing here dismisses the popover. Aligning is a rapid-fire, repeated action —
/// align left, then align top, then nudge — and closing after each one would cost a
/// click per op and undo the point of collapsing the row. The canvas updates live
/// behind the panel, so the feedback is already there; Esc or an outside click
/// closes it.
struct SpaceAlignPopover: View {
    let selectionCount: Int
    let onApply: (CanvasArrange.Operation) -> Void

    private static let rows: [[CanvasArrange.Operation]] = [
        [.alignLeft, .alignHorizontalCenter, .alignRight],
        [.alignTop, .alignVerticalCenter, .alignBottom],
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(row, id: \.self) { op in
                        ArrangeGlyphButton(
                            systemName: SpaceArrangeSymbols.symbol(for: op),
                            help: op.actionName,
                            isEnabled: op.isEnabled(selectionCount: selectionCount)
                        ) { onApply(op) }
                    }
                }
            }
        }
        // The default `lg`, shared with the other two group panels — see the note on
        // ``SpaceBarGroup`` for why these three match frames rather than gutters.
        .popoverContent()
    }
}

// MARK: - Z-order panel

/// Bring to Front / Send to Back for the whole selection, as labelled rows.
///
/// Labelled, unlike the align panel: `square.3.layers.3d.top.filled` and its
/// `.bottom` twin differ by which sliver of a three-layer stack is shaded, which is
/// not a distinction anyone reads at 15pt. The shortcuts are spelled out in the row
/// titles, but the BINDINGS are not here — they stay mounted in the bar, because a
/// `keyboardShortcut` inside a closed popover never fires (see `zOrderShortcuts`).
///
/// Content-sized, and NOT wearing `selectionMenuChrome()`. That chrome pins 220pt so
/// nested collection lists line up in `CollectionView`'s overflow; two fixed rows have
/// nothing to line up against, so the width was pure dead space to their right. Its
/// inset is skipped too — see ``SpaceBarGroup`` on why these three panels share `lg`.
struct SpaceZOrderPopover: View {
    let onBringToFront: () -> Void
    let onSendToBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZOrderRow("Bring to Front  ⌘⇧]",
                      systemImage: "square.3.layers.3d.top.filled",
                      action: onBringToFront)
            ZOrderRow("Send to Back  ⌘⇧[",
                      systemImage: "square.3.layers.3d.bottom.filled",
                      action: onSendToBack)
        }
        .popoverContent()
    }
}

/// One row in the z-order panel.
///
/// Deliberately NOT ``SelectionMenuRow``, which looks like the right reuse and isn't:
/// its leading inset is `Spacing.sm + (indent + 1) * 8`, indentation math for the
/// nested destination tree in `CollectionView`'s overflow. At `indent: 0` that lands
/// on 16pt leading against an 8pt trailing — a lopsided row, in a panel with no tree
/// to indent. This one is symmetric because it has no depth to express.
private struct ZOrderRow: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 16)
                Text(title)
                    .font(Theme.Typography.row)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            // `sm` vertically, not ``SelectionMenuRow``'s 6. That 6 is tuned for a
            // long scrolling destination list, where compact rows let more of the
            // tree show at once; this panel has exactly two rows and a `lg` inset
            // around them, and at 6 the hover fill read as a thin band sitting in a
            // roomy frame. 8 puts the row at 8 + 16 (`.body` line) + 8 = 32pt.
            .padding(.vertical, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isHovering ? Theme.Colors.hoverRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
