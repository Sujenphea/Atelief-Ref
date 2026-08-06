//
//  SpaceSpacingPopover.swift
//  AtelierRefs
//
//  069 — everything that decides how much room sits between the selected items:
//  distribute evenly, tidy into rows, or set an exact gap.
//
//  Was `SpaceGapPopover` (066), which held only the numeric gap. The three ops
//  belong together because they answer the SAME question with different amounts of
//  precision — "even it out", "clean it up", "make it exactly 24" — and keeping them
//  apart cost three separate glyphs in a bar that already carried sixteen.
//
//  The exact-gap half deliberately lives in a POPOVER rather than as a field in the
//  floating action bar, and that is a correctness decision, not a cosmetic one. The
//  action bar floats OVER the canvas, and a focusable field there would swallow
//  keystrokes the canvas owns — ⌫ deletes the selection, and V / F / T switch tools.
//  Two shipped bugs came from exactly this: 269 (the tool keys firing while typing in
//  a text box) and 271 (the search field's blur closing the canvas editor). A popover
//  is the shape the app already uses for focus-taking controls — the font, size and
//  colour popovers, and `ElementInspector` — because a popover is EXPECTED to hold
//  focus and gives it back when it closes. The caller restores first responder to the
//  canvas on dismiss.
//
//  No op here dismisses the panel: like the align panel, spacing is something you
//  repeat and adjust, and the canvas updates live behind it.
//

import SwiftUI

/// Distribute / tidy / exact gap for the current selection.
struct SpaceSpacingPopover: View {
    /// Drives which rows are live: the distributes need ≥3, tidy and the gap ≥2
    /// (051 · 12A, read off each op's own `minimumCount`).
    let selectionCount: Int
    /// Seeded by the caller and kept across opens, so setting the same gap on several
    /// selections doesn't mean retyping it each time.
    @Binding var gap: Double
    let onArrange: (CanvasArrange.Operation) -> Void
    let onPack: (CanvasArrange.Axis) -> Void

    /// The field is focusABLE but not auto-focused.
    ///
    /// 066's popover opened straight into the field because taking a number was the
    /// only thing it did. This panel leads with Distribute, so stealing focus on open
    /// would put a blinking cursor in an unrelated field every time someone reaches
    /// for Tidy Up. Clicking the field still works and still holds focus safely — see
    /// the file comment for why that matters.
    @FocusState private var fieldFocused: Bool

    /// Sensible bounds. Zero is meaningful (flush), and the ceiling just stops a typo
    /// from flinging the selection across the world.
    private static let range: ClosedRange<Double> = 0...2000

    /// Only the distribute row gates further than the panel itself. Tidy, reflow and
    /// the gap share the align threshold (≥2), which `.multi` already guarantees before
    /// this panel can be opened at all — so they are never dead here.
    private var canDistribute: Bool {
        CanvasArrange.Operation.distributeHorizontal.isEnabled(selectionCount: selectionCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            section("Distribute evenly") {
                HStack(spacing: Theme.Spacing.sm) {
                    axisButton("Across", systemImage: "arrow.left.and.right") {
                        onArrange(.distributeHorizontal)
                    }
                    axisButton("Down", systemImage: "arrow.up.and.down") {
                        onArrange(.distributeVertical)
                    }
                }
                .disabled(!canDistribute)
                .opacity(canDistribute ? 1 : 0.35)
                // The one row that can be dead while the panel is open — say why,
                // rather than leaving a dimmed pair with no explanation.
                .help(canDistribute
                      ? "Space the selection out with equal gaps"
                      : "Select at least 3 items to distribute")
            }

            Divider()

            section("Tidy up") {
                Button { onArrange(.tidyUp) } label: {
                    Label("Snap into rows", systemImage: "square.grid.2x2")
                }
                .buttonStyle(DialogButtonStyle())
                .help("Snap the selection into clean rows at a uniform gap")
            }

            Divider()

            // Its own section rather than a second button under "Tidy up", because the
            // two are not two flavours of one verb: tidy CLEANS UP what you built and
            // never touches a size, reflow THROWS THE ARRANGEMENT AWAY and resizes every
            // tile to repack it. Sitting them side by side under one heading would read
            // as a choice of strength; the divider says they are different acts. The
            // help string names the resize, since it is the surprising half.
            section("Reflow") {
                Button { onArrange(.reflowGrid) } label: {
                    Label("Repack into a grid", systemImage: "rectangle.grid.2x2")
                }
                .buttonStyle(DialogButtonStyle())
                .help("Resize the selection to one row height and repack it, like a fresh add")
            }

            Divider()

            section("Exact gap") {
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("Gap", value: $gap, format: .number)
                        .textFieldStyle(.plain)
                        .dialogFieldChrome()
                        .frame(width: 72)
                        .focused($fieldFocused)
                        .onSubmit { pack(.horizontal) }
                    Stepper("Gap", value: $gap, in: Self.range, step: 4)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                HStack(spacing: Theme.Spacing.sm) {
                    axisButton("Across", systemImage: "arrow.left.and.right") {
                        pack(.horizontal)
                    }
                    axisButton("Down", systemImage: "arrow.up.and.down") {
                        pack(.vertical)
                    }
                }
            }
        }
        .popoverContent(width: 240)
    }

    /// A titled block: the caption every popover section in the app uses, then its
    /// controls.
    @ViewBuilder
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
            content()
        }
    }

    /// Two co-equal actions per row, so both take the full-width treatment and split
    /// it — neither is the panel's single primary.
    private func axisButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(DialogButtonStyle())
    }

    private func pack(_ axis: CanvasArrange.Axis) {
        gap = min(max(gap, Self.range.lowerBound), Self.range.upperBound)
        onPack(axis)
    }
}
