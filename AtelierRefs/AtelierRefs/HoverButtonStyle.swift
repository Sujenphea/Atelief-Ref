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
    var cornerRadius: CGFloat = 7
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
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Apply the shared chrome hover fill to any view (e.g. a `Menu` that can't take a
    /// `ButtonStyle`). For `Button`s prefer `.buttonStyle(HoverButtonStyle())`.
    /// Pass ``Theme/Colors/hoverRow`` for a full-width row; the default suits glyphs.
    func hoverHighlight(
        cornerRadius: CGFloat = 7,
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
    var cornerRadius: CGFloat = 7
    var fill: Color = Theme.Colors.hoverControl
    var padding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverHighlight(
                cornerRadius: cornerRadius, fill: fill, padding: padding)
    }
}
