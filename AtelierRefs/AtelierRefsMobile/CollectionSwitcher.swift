// AtelierRefsMobile — the switcher (093 § 2).
//
// The Mac sidebar holds six things and exactly one survives onto a phone: the
// collections tree. A navigation container built to hold one destination type is not a
// navigation container, it is a picker — so the grid is the root, its TITLE is the
// switcher, and this is what the title presents.
//
// Not a tab bar (a tab bar wants two or more peer destinations, and v1 has one, and it
// would spend permanent bottom chrome on a surface whose whole job is showing
// pictures), and not a collections list as the root (that puts a list of folder NAMES
// between the user and the artwork on every cold launch, to answer a question the phone
// user usually is not asking).
//
// A `DisclosureGroup` per parent, ordered by `BrowseCollectionTree` — which is
// `CollectionTargets`' order, Unsorted pinned first.
//
// Rows carry a thumbnail, which 093 § 2 asks for by borrowing the Mac's Home gallery of
// cover cards: a reference library's collections are recognised by their contents, not
// their spelling. The picture is the collection's explicit cover where one is set and
// its most recently added member where none is — that rule is `AppServices`', not this
// view's (410), so this file only decides how big the square is and what stands in when
// there is nothing to show.

import AtelierBrowse
import AtelierCore
import SwiftUI

struct CollectionSwitcher: View {
    let nodes: [BrowseCollectionNode]
    /// One thumbnail per collection; a missing entry is a collection with nothing to
    /// show, not a failed load.
    let covers: [UUID: URL]
    let selectedID: UUID
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The row's square. Below the 44pt touch minimum on purpose: the minimum is the
    /// row's HIT area, which the whole row already satisfies (093 § 5), and a thumbnail
    /// sized to it would push the tree's indentation off a 390pt screen by the second
    /// level of nesting.
    private static let coverSide: CGFloat = 36

    var body: some View {
        NavigationStack {
            // `List(_:children:)` rather than a hand-rolled recursive row view:
            // a `View` whose body contains itself cannot infer its opaque type, and the
            // outline API is exactly the shape `BrowseCollectionNode` already has.
            List(nodes, children: \.childNodes) { node in
                label(node.collection)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MobileTheme.Colors.canvasOuter)
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(MobileTheme.Typography.row)
                }
            }
        }
        .presentationBackground(MobileTheme.Colors.canvasOuter)
    }

    private func label(_ collection: Collection) -> some View {
        Button {
            onSelect(collection.id)
            dismiss()
        } label: {
            HStack(spacing: MobileTheme.Spacing.sm) {
                cover(collection.id)
                Text(collection.name)
                    .font(MobileTheme.Typography.row)
                    .foregroundStyle(MobileTheme.Colors.inkPrimary)
                Spacer(minLength: 0)
                if collection.id == selectedID {
                    Image(systemName: "checkmark")
                        .font(MobileTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(MobileTheme.Colors.inkSecondary)
                }
            }
            // 093 § 5: the row's LOOK stays on the tokens and the hit area is stated
            // separately, at Apple's touch minimum.
            .frame(minHeight: MobileTheme.touchTarget)
            .contentShape(Rectangle())
        }
        // Deliberately NO `listRowInsets`: the outline's per-level indentation is spent
        // out of the row's leading inset, so replacing it flattens the nesting the tree
        // exists to show.
        .buttonStyle(.plain)
        .listRowBackground(
            collection.id == selectedID
                ? MobileTheme.Colors.selection : MobileTheme.Colors.canvasOuter)
        .listRowSeparatorTint(MobileTheme.Colors.hairline)
    }

    /// The row's picture, or a folder when the collection has nothing to show.
    ///
    /// The square is drawn whichever it is, so the names stay on one left edge — a
    /// column of text that shifts by 44pt depending on whether a folder happens to hold
    /// an image would read as two lists. `mediaBackdrop` under both for 093 § 6's
    /// reason: a light thumbnail and a dark one meet the same ground, and an empty
    /// folder's tile is that ground rather than a hole.
    private func cover(_ id: UUID) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: MobileTheme.Radius.tile, style: .continuous)
        return Group {
            if let url = covers[id] {
                ThumbnailImage(url: url, width: Self.coverSide)
            } else {
                Image(systemName: "folder")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.inkSecondary)
            }
        }
        .frame(width: Self.coverSide, height: Self.coverSide)
        .background(MobileTheme.Colors.mediaBackdrop)
        .clipShape(shape)
        .overlay(shape.strokeBorder(MobileTheme.Colors.hairline, lineWidth: 1))
        // The picture says nothing the row's name does not; VoiceOver reads the name.
        .accessibilityHidden(true)
    }
}
