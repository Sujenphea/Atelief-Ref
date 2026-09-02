// AtelierRefsMobile — one item, pushed onto the same stack (093 § 2).
//
// The Mac's detail page is a media area beside a fixed 298pt side panel
// (`ItemDetailView.swift:461`). A phone has no room for that, so the panel's three 041
// sections — Data, Source, Details — reflow BELOW the media in one scroll, in the same
// order. 093 § 7 leaves the full layout undecided on purpose; what is decided is the
// order and the reflow, and this draws exactly that and no more.
//
// **Read-only, and visibly so.** The Mac's Details section is the item's EDITABLE
// surface: name, note, collection chips, tag chips, each with a verb behind it. None of
// those verbs exist here (091 · D1), so the section shows the two fields that have
// content and omits itself entirely when neither does — rather than rendering empty
// text fields the user cannot type into. Visit is the one action, and it leaves the
// app rather than changing the library.
//
// The image is the 1280 tier, never the original blob — see
// `LibraryMediaPaths.detailThumbnailSize`. Zoom is not here: 093 § 7 lists "what a
// phone does with zoom" among the things it does not design.

import AtelierBrowse
import AtelierCore
import AtelierTokens
import SwiftUI

struct ItemDetailScreen: View {
    let detail: CollectionItemDetail
    let imageURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xl) {
                media
                dataSection
                sourceSection
                detailsSection
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.bottom, MobileTheme.Spacing.xxl)
        }
        .background(MobileTheme.Colors.panel)
        .navigationTitle(title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Media

    @ViewBuilder
    private var media: some View {
        let aspect = MasonryColumns.aspect(detail.asset)
        Group {
            switch detail.asset.content {
            case .color(let hex):
                (Color(hexString: hex) ?? MobileTheme.Colors.mediaBackdrop)
                    .aspectRatio(1, contentMode: .fit)
            case .image, .video, .link, .tweet, .unknown:
                if imageURL != nil {
                    // No width to hand down here — the media area is as wide as the
                    // screen, so `MediaThumbnail` measures itself.
                    MediaThumbnail(url: imageURL)
                        .aspectRatio(aspect, contentMode: .fit)
                } else {
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.card, style: .continuous))
        .padding(.top, MobileTheme.Spacing.md)
    }

    // MARK: - Sections

    /// "Data" — saved date + dimensions only (041).
    private var dataSection: some View {
        DetailSection("Data") {
            DetailRow("Saved", BrowseFormat.savedDate(detail.asset.createdAt))
            if let dimensions = BrowseFormat.dimensions(
                width: detail.asset.width, height: detail.asset.height) {
                DetailRow("Dimensions", dimensions)
            }
        }
    }

    /// "Source" — platform / author / title, then Visit (041).
    private var sourceSection: some View {
        DetailSection("Source") {
            DetailRow("Platform", BrowseFormat.platform(detail.source.platform))
            if let author = BrowseFormat.author(
                name: detail.source.authorName, handle: detail.source.authorHandle) {
                DetailRow("Author", author)
            }
            if let sourceTitle = TextRules.nonBlank(detail.source.title) {
                DetailRow("Title", sourceTitle)
            }
            if let url = sourceURL {
                VisitButton { openURL(url) }
                    .padding(.top, MobileTheme.Spacing.xs)
            }
        }
    }

    /// "Details" — the Mac's editable surface, read-only and therefore only as much of
    /// it as has content. Omitted entirely when there is nothing to show.
    @ViewBuilder
    private var detailsSection: some View {
        let name = TextRules.nonBlank(detail.asset.name)
        let note = TextRules.nonBlank(detail.asset.note)
        if name != nil || note != nil {
            DetailSection("Details") {
                if let name { DetailRow("Name", name) }
                if let note { DetailRow("Note", note) }
            }
        }
    }

    private var title: String? {
        BrowseFormat.title(name: detail.asset.name, sourceTitle: detail.source.title)
    }

    private var sourceURL: URL? {
        guard let raw = TextRules.nonBlank(detail.source.originalURL),
              let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

/// A titled block, mirroring the Mac's `DetailSection` (`ItemDetailView.swift:2241`).
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text(title)
                .font(MobileTheme.Typography.sectionTitle)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label / value pair. The label is `inkSecondary` and the value `inkPrimary`, which
/// is the Mac's `DetailRow` weighting.
private struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MobileTheme.Spacing.md) {
            Text(label)
                .font(MobileTheme.Typography.label)
                .foregroundStyle(MobileTheme.Colors.inkSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(MobileTheme.Typography.label)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A full-width field-styled "Visit ↗" (041 · Source / links) — the one action on this
/// screen, and it leaves the app rather than touching the library.
private struct VisitButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                Text("Visit").font(MobileTheme.Typography.label)
                Image(systemName: "arrow.up.right").font(.system(size: 11))
            }
            .foregroundStyle(MobileTheme.Colors.inkSecondary)
            .frame(maxWidth: .infinity)
            // 093 § 5: the label keeps its token size, and the hit area is stated at
            // Apple's minimum rather than the padding being inflated to reach it.
            .frame(minHeight: MobileTheme.touchTarget)
            .fieldChrome()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the original source")
    }
}
