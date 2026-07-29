//
//  SpaceGapPopover.swift
//  AtelierRefs
//
//  066 — set an exact gap between the selected items.
//
//  The eight arrange ops equalise the gaps they find; none of them lets you say "put
//  24 between these". This does, and it deliberately lives in a POPOVER rather than as
//  a field in the floating action bar.
//
//  That is a correctness decision, not a cosmetic one. The action bar floats OVER the
//  canvas, and a focusable field there would swallow keystrokes the canvas owns — ⌫
//  deletes the selection, and V / F / T switch tools. Two shipped bugs came from
//  exactly this: 269 (the tool keys firing while typing in a text box) and 271 (the
//  search field's blur closing the canvas editor). A popover is the shape the app
//  already uses for focus-taking controls — the font, size and colour popovers, and
//  `ElementInspector` — because a popover is EXPECTED to hold focus and gives it back
//  when it closes. The caller restores first responder to the canvas on dismiss.
//

import AtelierCore
import SwiftUI

/// Numeric gap entry: a value, and which way to apply it.
struct SpaceGapPopover: View {
    /// Seeded by the caller and kept across opens, so setting the same gap on several
    /// selections doesn't mean retyping it each time.
    @Binding var gap: Double
    let onApply: (CanvasArrange.Axis) -> Void

    /// Focus starts in the field: the popover exists to take a number, and making the
    /// user click into it first would be a wasted step. Safe here in a way it would not
    /// be in the action bar — see the file comment.
    @FocusState private var fieldFocused: Bool

    /// Sensible bounds. Zero is meaningful (flush), and the ceiling just stops a typo
    /// from flinging the selection across the world.
    private static let range: ClosedRange<Double> = 0...2000

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Gap").frame(width: 32, alignment: .leading)
                TextField("Gap", value: $gap, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .focused($fieldFocused)
                    .onSubmit { apply(.horizontal) }
                Stepper("Gap", value: $gap, in: Self.range, step: 4)
                    .labelsHidden()
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    apply(.horizontal)
                } label: {
                    Label("Across", systemImage: "arrow.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    apply(.vertical)
                } label: {
                    Label("Down", systemImage: "arrow.up.and.down")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 240)
        .onAppear { fieldFocused = true }
    }

    private func apply(_ axis: CanvasArrange.Axis) {
        gap = min(max(gap, Self.range.lowerBound), Self.range.upperBound)
        onApply(axis)
    }
}
