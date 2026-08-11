//
//  HoverButtonStyle.swift
//  AtelierRefs
//
//  The one reusable hover treatment for app-chrome buttons. Generalizes the recipe
//  `SelectionBarIcon` pioneered in the selection action bar — a rounded
//  ``Theme/Colors/hoverControl`` fill that appears on `.onHover`, over a padded
//  `.contentShape` hit area — so every plain chrome button (sidebar toggle / sort /
//  trash, section disclosure + add, nav rows, the search × controls) reads with the
//  SAME feedback instead of staying inert under `.buttonStyle(.plain)`.
//
//  Two entry points share one implementation: `HoverButtonStyle` for `Button`s and
//  `.hoverHighlight()` for the views that aren't buttons (the sort `Menu`, whose
//  `.menuStyle` ignores a `ButtonStyle`).
//
//  The fill is a TOKEN, not a free opacity: `hoverControl` for a glyph button and
//  `hoverRow` for a full-width row are the only two strengths the app has, and
//  `selection` is never a hover — it marks where you are.
//

import SwiftUI

// MARK: - Core modifier

/// Fills a rounded rect behind its content on hover. The padded `.contentShape` also
/// gives a bare template-`Image` label a real hit / tooltip area, which
/// `.buttonStyle(.plain)` alone does not.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.control
    var fill: Color = Theme.Colors.hoverControl
    var padding: CGFloat = 6

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? fill : .clear))
            .contentShape(Rectangle())
            // Disabled has to dim EXPLICITLY. This wraps `.plain`-family labels, which
            // drop the system's own dimming (the reason ``DialogButtonStyle`` states
            // for doing the same), so until now a disabled chrome button rendered
            // pixel-identical to a live one — the detail pager's ← on the first item
            // looked pressable. 0.35 is `DialogButtonStyle`'s existing dim.
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Apply the shared chrome hover fill to any view (e.g. a `Menu` that can't take a
    /// `ButtonStyle`). For `Button`s prefer `.buttonStyle(HoverButtonStyle())`.
    /// Pass ``Theme/Colors/hoverRow`` for a full-width row; the default suits glyphs.
    func hoverHighlight(
        cornerRadius: CGFloat = Theme.Radius.control,
        fill: Color = Theme.Colors.hoverControl,
        padding: CGFloat = 6
    ) -> some View {
        modifier(HoverHighlight(
            cornerRadius: cornerRadius, fill: fill, padding: padding))
    }
}

// MARK: - Button style

/// The shared hover treatment as a `ButtonStyle`: the same rounded fill on hover plus a
/// pressed dim, matching the selection action bar's glyphs.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Radius.control
    var fill: Color = Theme.Colors.hoverControl
    var padding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverHighlight(
                cornerRadius: cornerRadius, fill: fill, padding: padding)
    }
}

// MARK: - Toolbar tier

/// A glyph button living in a macOS 26 `ToolbarItem` — the window toolbar's own
/// tier, distinct from the sidebar rail's bare glyphs.
///
/// The toolbar is different in a way that is easy to miss: the item's glass pill
/// **hugs its content**, so the button's own padding IS the pill's margin, and a
/// hover fill drawn at the content's bounds is the SAME RECTANGLE as the pill.
/// ``HoverButtonStyle`` there produced two visible faults:
///
/// 1. **The fill overhung the pill.** Same rect, but ``Theme/Radius/control``'s 7pt
///    corners against the far rounder capsule macOS draws — so the fill's corners
///    poked out past the glass. Shrinking the padding could not fix it; that shrinks
///    both rects together. The fill has to be INSET and capsule-cornered, so it
///    cannot overhang whatever radius the system picks.
/// 2. **Two buttons were two widths.** SF Symbols have different intrinsic widths —
///    `paintpalette` is visibly wider than `star` — so content-hugging gave each
///    toolbar button a differently-sized pill. Pinning the glyph to a square box
///    makes every toolbar button one size regardless of its symbol.
///
/// The pill is **wider than it is tall**, which is what a toolbar button looks like
/// on macOS and what ``Theme/Radius/control`` already assumes ("a 15pt icon in a
/// 30×28 hit area"). A glyph box pinned to a single dimension gives a true square,
/// and a square toolbar pill reads squat and cramped. 38×30 here — the proportion
/// AppKit's own toolbar items carry, arrived at by widening until it stopped looking
/// tight rather than by picking a ratio.
struct ToolbarGlyphButtonStyle: ButtonStyle {
    /// The box the glyph is centred in. Comfortably holds the 14pt symbols the
    /// toolbar uses, and is what makes every toolbar pill the same size whatever its
    /// symbol's intrinsic width. Wider than tall, per the note above.
    private static let glyphWidth: CGFloat = 26
    private static let glyphHeight: CGFloat = 18
    /// Fill inset from the glyph box.
    private static let hoverPad = Theme.Spacing.xs
    /// Fill inset from the PILL — the gap that stops any overhang.
    private static let pillInset: CGFloat = 2
    /// Half the fill's SHORTER side, i.e. a capsule laid on its side. Derived rather
    /// than written down, so it stays a capsule if the box or the padding is ever
    /// retuned — and read off the height, because that is the shorter dimension and
    /// a radius past half of it would be clamped anyway.
    private static var fillRadius: CGFloat { (glyphHeight + hoverPad * 2) / 2 }

    var fill: Color = Theme.Colors.hoverControl

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: Self.glyphWidth, height: Self.glyphHeight)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverHighlight(
                cornerRadius: Self.fillRadius, fill: fill, padding: Self.hoverPad)
            // OUTSIDE the fill: the pill hugs this, the fill does not reach it.
            .padding(Self.pillInset)
    }
}
