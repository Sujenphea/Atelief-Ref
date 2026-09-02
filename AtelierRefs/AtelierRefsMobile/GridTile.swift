// AtelierRefsMobile — one cell of the phone's grid (093 § 3, § 5).
//
// Total over `AssetContent` (003 · O1), which is the whole reason that projection
// exists: a byte-backed kind draws its thumbnail, a colour draws its swatch, a link or
// a tweet with no card image draws a text card, and a row whose data contradicts its
// kind draws a neutral placeholder rather than crashing.
//
// **Nothing is drawn ON the artwork.** The Mac's tile carries a hover dim, an
// enter-selection circle, a post badge, a favourite marker and a context menu; 093 § 5
// is explicit that hover is STORAGE for affordances that would otherwise be permanent
// chrome over the pictures, that a phone cannot borrow that space, and that v1's answer
// is for those affordances not to exist yet rather than to be relocated onto the tile.
// So the tile is the picture, and the tap is the only event it has.

import AtelierBrowse
import AtelierCore
import AtelierTokens
import SwiftUI

struct GridTile: View {
    let detail: CollectionItemDetail
    /// The column width in points — the cell's own width, and the decode target.
    let width: CGFloat
    /// Resolved by the grid and passed down, so the tile stays a pure function of its
    /// inputs — a cell that reaches into the store is a cell that re-renders whenever
    /// anything in the store changes.
    let thumbnailURL: URL?

    var body: some View {
        content
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.tile, style: .continuous)
                    .strokeBorder(MobileTheme.Colors.hairline, lineWidth: 1))
            // The whole tile is the hit area, which is far past 44 × 44 at any column
            // count a phone uses — 093 § 5's rule needs no separate shape here.
            .contentShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.tile))
            .accessibilityLabel(accessibilityLabel)
    }

    /// `columnWidth / aspect` — the same cell height `MasonryLayout` computes
    /// (`MasonryLayout.swift:101`), which is what makes the column stack reproduce the
    /// Mac's frames.
    private var height: CGFloat {
        width / MasonryColumns.aspect(detail.asset)
    }

    @ViewBuilder
    private var content: some View {
        switch detail.asset.content {
        case .image, .video:
            MediaThumbnail(url: thumbnailURL, width: width)
        case .color(let hex):
            Color(hexString: hex) ?? MobileTheme.Colors.mediaBackdrop
        case .link(let link):
            if link.imageBlobHash != nil {
                MediaThumbnail(url: thumbnailURL, width: width)
            } else {
                // The host, not the URL, when a link has no title — which on this phone is
                // EVERY tier-1 link, because nothing enriches one (098 · "also found":
                // `ShareCapture.swift` and 092 · S4b both say the drain adds og-tags and
                // neither `InboxDrain.makeInput` nor `PageResolver` does it on iOS).
                TextCard(
                    glyph: "link",
                    title: BrowseFormat.linkTitle(link.title, url: link.url),
                    subtitle: TextRules.nonBlank(link.description))
            }
        case .tweet(let tweet):
            if tweet.cardImageBlobHash != nil {
                MediaThumbnail(url: thumbnailURL, width: width)
            } else {
                TextCard(
                    glyph: "text.bubble",
                    title: BrowseFormat.author(
                        name: tweet.authorName, handle: tweet.authorHandle) ?? "Post",
                    subtitle: TextRules.nonBlank(tweet.text))
            }
        case .unknown:
            MobileTheme.Colors.mediaBackdrop
        }
    }

    /// What VoiceOver calls this tile, and what a UI test taps by.
    ///
    /// One rule with the item detail's navigation title since 098 · P6: this was
    /// `title(name:sourceTitle:) ?? platform(_:)`, which announced "Web" for a bare link
    /// tile whose own card said `example.com` — the tile drew one answer and named itself
    /// with another.
    private var accessibilityLabel: String {
        BrowseFormat.displayTitle(for: detail.asset, source: detail.source)
    }
}

/// A media-less item's card: a glyph, a title, and whatever text there is.
private struct TextCard: View {
    let glyph: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            Image(systemName: glyph)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.inkSecondary)
            Text(title)
                .font(MobileTheme.Typography.bodyEmphasis)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
                .lineLimit(3)
            if let subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.inkSecondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MobileTheme.Colors.surface)
    }
}

// The `#rrggbb` parser this file used to carry is gone: it was a FOURTH implementation of
// a grammar three others are pinned to by `HexGrammarTests`, and it took 3/6 where they
// take 3/4/6/8 — so a stored colour with an alpha rendered on the Mac and fell back to
// grey here. `Color(hexString:)` is one implementation now, in `AtelierTokens`, linked by
// both platforms.
