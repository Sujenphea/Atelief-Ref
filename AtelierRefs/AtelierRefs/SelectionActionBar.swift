//
//  SelectionActionBar.swift
//  AtelierRefs
//
//  The floating "N selected" action bar shown over the grid whenever a selection
//  is active — shared chrome + icon buttons so Collection (`CollectionView`) and
//  Search (`LibrarySearch`) render the SAME pill. Previously each view inlined its
//  own HStack with a text "Clear" button and default `Label` hit areas of varying
//  width; this centralizes the look to the reference: a monochrome capsule with a
//  leading "N selected" count, an `×` clear, then an evenly-sized row of action
//  glyphs. Chrome only — every button calls back into the owning view's model.
//

import SwiftUI

// MARK: - Icon glyph

/// The styled glyph shared by every bar button: a fixed 30×28 hit area with a
/// subtle rounded hover fill, so the row reads as a tidy group of taps rather than
/// crowded symbols. Reused directly as the `Menu`/popover trigger label too, which
/// is why it's split out from `SelectionBarButton`.
struct SelectionBarIcon: View {
    let systemName: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0)))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

// MARK: - Action button

/// One action icon in the selection bar. `role` stays cosmetic here — `.plain`
/// keeps every glyph the same monochrome ink (the reference's trash is white, not
/// red); the destructive confirmation lives in the model call, not the tint.
struct SelectionBarButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    var action: () -> Void

    init(_ systemName: String, help: String, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            SelectionBarIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
    }
}

// MARK: - Chrome

extension View {
    /// Wrap a selection bar's `HStack` in the shared floating capsule. The fill is
    /// the SOLID `field` token, not `.regularMaterial`: a translucent material tints
    /// from whatever grid content sits behind it, so the Collection and Search bars
    /// rendered slightly different greys over their different backdrops. A fixed
    /// token makes both pixel-identical and matches the reference's opaque pill.
    /// The leading inset is wider than the trailing one so the count text breathes
    /// while the last icon's own hit area supplies the right margin.
    func selectionBarChrome() -> some View {
        self
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.Colors.field, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .padding(.bottom, 16)
    }
}
