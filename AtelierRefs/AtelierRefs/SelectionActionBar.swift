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

    /// Wrap the `…` overflow popover's content in the design-system container — the
    /// shared ``popoverChrome(cornerRadius:)`` surface — and make the host popover's
    /// own chrome transparent so ONLY this card shows. Fixed width so the section
    /// headers and rows all align. Replaces the raw system-menu look.
    func selectionMenuChrome() -> some View {
        self
            .padding(Theme.Spacing.xs)
            .frame(width: 220)
            .popoverChrome()
            .presentationBackground(.clear)
    }
}

// MARK: - Overflow popover atoms

/// Carries a destination list's measured natural height up so its capped
/// `ScrollView` can size to `min(content, cap)` (a bare ScrollView collapses to
/// zero in a content-sized popover).
struct MenuListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A collapsible section header for the selection bar's `…` overflow popover (e.g.
/// "Move to" / "Add to"). Mirrors the sidebar's `sectionHeader` idiom — a leading
/// glyph + title with a trailing chevron that swaps open/closed — so the popover
/// reads as part of the design system rather than a raw menu.
struct SelectionMenuSectionHeader: View {
    let title: String
    let systemImage: String?
    let isExpanded: Bool
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, systemImage: String? = nil, isExpanded: Bool,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.Typography.row)
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One tappable row in the overflow popover — a destination collection or a leaf
/// action (Set as Cover). Full-width with the app's radius-6 `selection` hover fill
/// (the `SidebarView.rowHighlight` idiom), 14pt ink. Pass `isEnabled: false` for a
/// non-tappable empty-state row ("No collections").
struct SelectionMenuRow: View {
    let title: String
    let systemImage: String?
    let indent: Int
    let isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, systemImage: String? = nil, indent: Int = 0,
         isEnabled: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.indent = indent
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.Typography.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isEnabled ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
            .padding(.leading, Theme.Spacing.sm + CGFloat(indent + 1) * 8)
            .padding(.trailing, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEnabled && isHovering ? Theme.Colors.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { if isEnabled { isHovering = $0 } }
    }
}
