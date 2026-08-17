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
// `CollectionTargets`' order, Unsorted pinned first. Rows carry no thumbnail yet;
// 093 § 2 asks for one, borrowing the Mac's cover-card idea, and it needs
// `collectionCovers` plus the media loader per row. That is a read this slice has not
// wired and it is called out in the changelog rather than half-drawn.

import AtelierBrowse
import AtelierCore
import SwiftUI

struct CollectionSwitcher: View {
    let nodes: [BrowseCollectionNode]
    let selectedID: UUID
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

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
        .buttonStyle(.plain)
        .listRowBackground(
            collection.id == selectedID
                ? MobileTheme.Colors.selection : MobileTheme.Colors.canvasOuter)
        .listRowSeparatorTint(MobileTheme.Colors.hairline)
    }
}
