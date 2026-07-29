//
//  FontFamilyPicker.swift
//  AtelierRefs
//
//  064 — choosing a font family without paying for every family you didn't choose.
//
//  Both font controls used to be a plain SwiftUI `Picker` over the whole catalogue.
//  On macOS that is backed by an `NSPopUpButton`, which has to derive an intrinsic
//  width — and doing that means MEASURING every item's title. Measured on a
//  402-family machine: building the `NSMenu` itself costs 0.5 ms, but sizing the
//  popup button over it costs **160 ms**, and unlike the one-time enumeration
//  (``FontFamilyCatalog``) that cost is paid on EVERY open.
//
//  So the list stops being one sizing-sensitive control and becomes a scrolling one:
//  a `LazyVStack` realises only the visible rows, and the width comes from the popover
//  rather than from the content. A search field earns its place at 402 families too —
//  a flat menu that long is not really browsable.
//
//  Deliberately plain labels rather than each family drawn in its own face: resolving a
//  typeface costs ~1.7 ms, which is invisible for the handful on screen but turns a
//  scroll into a stutter. Legibility of the list beats a preview here.
//

import SwiftUI

/// A searchable, lazily-rendered font-family list. `selection` is the family name, or
/// ``FontFamilyCatalog/systemFamily`` (empty) for the system font — matching how
/// `ElementStyle.fontFamily` stores it (054 §1).
struct FontFamilyPicker: View {
    @Binding var selection: String

    /// Search text. Local: a query is a way of looking, not part of the document.
    @State private var query = ""

    /// How tall the scrolling list is. Enough to show ~8 families without making the
    /// popover taller than the boards it floats over.
    private static let listHeight: CGFloat = 180

    private var matches: [String] {
        let all = FontFamilyCatalog.shared.families
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // "System" is the nil family, pinned first, and always offered —
                        // it is not a real family name so it can't match a search.
                        row(title: "System", value: FontFamilyCatalog.systemFamily)
                        ForEach(matches, id: \.self) { row(title: $0, value: $0) }
                    }
                }
                .frame(height: Self.listHeight)
                // Open on the family that is actually set. Without this a user who has
                // chosen "Helvetica" reopens the list at the top of the alphabet and has
                // to hunt for their own selection.
                //
                // Deferred by one turn on purpose: during `onAppear` the `LazyVStack`
                // has not realised its rows yet, so a scroll issued now can resolve
                // against nothing and silently do nothing.
                .onAppear {
                    let target = selection
                    Task { @MainActor in proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private func row(title: String, value: String) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 4)
            // The whole row is the target, not just the glyphs.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A selected ROW is `selection`, the token the sidebar and the search
        // results already use — not a tinted accent. The app is monochrome by
        // design (`Theme`), and a translucent tint also shifted colour with the
        // fill behind it once this list moved onto the popover surface.
        .background(
            isSelected ? Theme.Colors.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .id(value)
    }
}
