//
//  HoverButtonStyle.swift
//  AtelierRefs
//
//  The one reusable hover treatment for app-chrome buttons. Generalizes the recipe
//  `SelectionBarIcon` pioneered in the selection action bar — a rounded
//  `Color.primary` fill that appears on `.onHover`, over a padded
//  `.contentShape` hit area — so every plain chrome button (sidebar toggle / sort /
//  trash, section disclosure + add, nav rows, the search × controls) reads with the
//  SAME feedback instead of staying inert under `.buttonStyle(.plain)`.
//
//  Two entry points share one implementation: `HoverButtonStyle` for `Button`s and
//  `.hoverHighlight()` for the views that aren't buttons (the sort `Menu`, whose
//  `.menuStyle` ignores a `ButtonStyle`).
//

import SwiftUI

// MARK: - Core modifier

/// Fills a rounded rect behind its content on hover. The padded `.contentShape` also
/// gives a bare template-`Image` label a real hit / tooltip area, which
/// `.buttonStyle(.plain)` alone does not.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 7
    var hoverOpacity: Double = 0.10
    var padding: CGFloat = 6

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? hoverOpacity : 0)))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Apply the shared chrome hover fill to any view (e.g. a `Menu` that can't take a
    /// `ButtonStyle`). For `Button`s prefer `.buttonStyle(HoverButtonStyle())`.
    func hoverHighlight(
        cornerRadius: CGFloat = 7, opacity: Double = 0.10, padding: CGFloat = 6
    ) -> some View {
        modifier(HoverHighlight(
            cornerRadius: cornerRadius, hoverOpacity: opacity, padding: padding))
    }
}

// MARK: - Button style

/// The shared hover treatment as a `ButtonStyle`: the same rounded fill on hover plus a
/// pressed dim, matching the selection action bar's glyphs.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var opacity: Double = 0.10
    var padding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverHighlight(
                cornerRadius: cornerRadius, opacity: opacity, padding: padding)
    }
}
