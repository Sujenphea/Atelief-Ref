//
//  ItemDetailView.swift
//  AtelierRefs
//
//  The full-window detail page for a single item (replaces the old trailing
//  `.inspector()` panel): the media fills most of the width — a full-resolution
//  image, or an inline `VideoPlayer` for video — with the item's metadata /
//  provenance / tags / actions docked on the right.
//
//  A PRESENTATION-ONLY view: it is fed an explicit `asset` + `source` + media
//  URLs + tags + action closures, and an OPTIONAL ``ItemDetailNavigator`` for
//  prev/next. So the collection grid drives it from `IngestionModel`'s
//  folder-scoped selection (with prev/next), while a Space board can open the
//  same page for a placed asset (no folder context, so no prev/next). The media
//  is (re)loaded off-main whenever `asset.id` changes.
//

import AVKit
import AppKit
import AtelierCore
import SwiftUI

/// Prev/next stepping for the detail page. Absent (`nil`) when the item has no
/// ordered set behind it — e.g. an asset opened from a Space board.
struct ItemDetailNavigator {
    /// The current item's 0-based position in its set.
    let index: Int
    /// The set's size (for the "N / total" counter).
    let count: Int
    /// Step the selection by `delta` (±1), clamped by the caller.
    let step: (Int) -> Void
}

/// The detail page's source / lifecycle actions. Each is optional so a caller can
/// omit the ones that don't apply — a Space board, for instance, has no
/// folder-membership to remove from.
struct ItemDetailActions {
    var openSource: (() -> Void)?
    var openBlob: (() -> Void)?
    var revealInFinder: (() -> Void)?
    var copySourceLink: (() -> Void)?
    var removeFromFolder: (() -> Void)?
    var requestDelete: (() -> Void)?
}

struct ItemDetailView: View {
    /// The asset being shown (drives the media branch + metadata).
    let asset: Asset
    /// The asset's provenance, if known (drives the source section + title).
    let source: Source?
    /// Full-resolution blob URL, decoded off-main; `nil` → preview/spinner only.
    let blobURL: URL?
    /// An instant placeholder (e.g. the 1280 tier) shown while full-res decodes.
    let previewImage: NSImage?
    /// The item's tags + their editors.
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    /// Source / lifecycle actions (each optional — omitted ones disable/hide).
    let actions: ItemDetailActions
    /// Optional prev/next; `nil` hides the navigator (no ordered set).
    let navigator: ItemDetailNavigator?
    /// Dismiss the page (Back button / Escape).
    let onClose: () -> Void

    /// The full-resolution decoded image (image assets only), loaded off-main.
    @State private var fullImage: NSImage?
    /// The inline player (video assets only), rebuilt when the item changes.
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                mediaArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DetailSidebar(
                    asset: asset, source: source, tags: tags,
                    onAddTag: onAddTag, onRemoveTag: onRemoveTag, actions: actions)
                    .frame(width: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // Reload media whenever the shown asset changes (open + prev/next).
        .task(id: asset.id) { await loadMedia() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let navigator {
                Button {
                    navigator.step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(navigator.index <= 0)

                Text("\(navigator.index + 1) / \(navigator.count)")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    navigator.step(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(navigator.index >= navigator.count - 1)
            }

            Spacer()

            Text(source?.title ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding()
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaArea: some View {
        Group {
            // Switch on the render seam (003 · O1), so a media-less kind draws its
            // own view instead of waiting on a blob that will never load.
            switch asset.content {
            case .video:
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            case .image:
                // Show the placeholder preview instantly, then swap to the
                // full-resolution decode when it lands. Keyed by `asset.id` so the
                // zoom/pan resets on navigation but survives the preview→full swap.
                if let image = fullImage ?? previewImage {
                    ZoomableImage(image: image).id(asset.id)
                } else {
                    ProgressView()
                }
            case let .color(hex):
                ColorDetailView(hex: hex)
            case let .link(link):
                // With a resolved og:image, show it above the card; else just the card.
                LinkDetailView(link: link, image: fullImage ?? previewImage)
            case let .tweet(tweet):
                // With a captured card image, show it above the card; else the card.
                TweetDetailView(tweet: tweet, image: fullImage ?? previewImage)
            case .unknown:
                ContentUnavailableView(
                    "No preview", systemImage: "questionmark.square.dashed",
                    description: Text("This item has no displayable media."))
            }
        }
        .padding()
    }

    /// Decode the full-resolution image off-main, or build the video player, for
    /// the current asset. No caching — full-res images are large, so we decode on
    /// demand and drop the previous one on navigation.
    private func loadMedia() async {
        fullImage = nil
        player?.pause()
        player = nil
        // Media-less kinds (003 · O1) have no blob — nothing to load off-disk.
        guard let url = blobURL else { return }
        switch asset.kind {
        case .video:
            player = AVPlayer(url: url)
        case .image, .link, .tweet:
            // A link's resolved og:image / a tweet's captured card image is the
            // asset's own blob; decode it like an image (a bare link or tweet has
            // no blobURL, so this arm is simply skipped).
            let decoded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            // `.task(id:)` cancels this on navigation — don't publish a stale
            // decode over the item the user moved to.
            if !Task.isCancelled { fullImage = decoded }
        case .color:
            break  // media-less: the media area draws this from content.
        }
    }
}

/// The detail-page media view for a media-less `link` asset (003 · C2): an
/// optional og:image (once resolved) over a card of title / host / description,
/// with a prominent Open Link action (SwiftUI `Link`, no closure plumbing) and
/// the full URL selectable beneath.
private struct LinkDetailView: View {
    let link: LinkContent
    /// The resolved og:image, if the link has one decoded; nil for a bare link.
    var image: NSImage?

    private var host: String? { URL(string: link.url)?.host }

    var body: some View {
        VStack(spacing: 16) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "link")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }

            if let title = link.title, !title.isEmpty {
                Text(title)
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
            }
            if let host {
                Text(host).font(.callout).foregroundStyle(.secondary)
            }
            if let description = link.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if let url = URL(string: link.url) {
                Link(destination: url) {
                    Label("Open Link", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Text(link.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}

/// The detail-page media view for a media-less `tweet` asset (003 · C3): an
/// optional captured card image over the author line, the tweet text, the media
/// references (URLs — no local bytes, so shown as openable rows), and a prominent
/// Open on X action to the canonical permalink.
private struct TweetDetailView: View {
    let tweet: TweetContent
    /// The captured card image, if the tweet has one decoded; nil otherwise.
    var image: NSImage?

    /// `@handle` when known, else the author name, else a generic label.
    private var byline: String {
        if let handle = tweet.authorHandle, !handle.isEmpty { return "@\(handle)" }
        if let name = tweet.authorName, !name.isEmpty { return name }
        return "Tweet"
    }

    private var permalink: URL? {
        URL(string: TweetPayload.canonicalTweetURL(id: tweet.tweetID))
    }

    var body: some View {
        VStack(spacing: 16) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }

            if let name = tweet.authorName, !name.isEmpty {
                Text(name).font(.title3).bold()
            }
            Text(byline).font(.callout).foregroundStyle(.secondary)

            if let text = tweet.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if !tweet.media.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("^[\(tweet.media.count) media](inflect: true)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(tweet.media, id: \.url) { media in
                        if let mediaURL = URL(string: media.url) {
                            Link(destination: mediaURL) {
                                Label(media.url, systemImage: "photo")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let permalink {
                Link(destination: permalink) {
                    Label("Open on X", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}

/// The detail-page media view for a media-less `color` asset (003 · C1): a large
/// rounded swatch of the color with its canonical hex beneath, selectable.
private struct ColorDetailView: View {
    let hex: String

    var body: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hexString: hex) ?? Color(.quaternaryLabelColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420, maxHeight: 420)
            Text(hex.uppercased())
                .font(.system(.title2, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Zoomable image

/// A fit-to-view image with pinch-to-zoom and (once zoomed) drag-to-pan; a
/// double-click snaps back to fit. Its zoom/pan is local `@State`, and the
/// caller keys it by `asset.id` so navigation resets it while the low-res→full-res
/// swap (same id) keeps the current zoom.
private struct ZoomableImage: View {
    let image: NSImage

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    /// Ceiling so a huge pinch can't lose the image off-screen.
    private let maxZoom: CGFloat = 6

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(zoom * pinch)
            .offset(
                x: pan.width + dragTranslation.width,
                y: pan.height + dragTranslation.height)
            .gesture(magnify)
            .simultaneousGesture(dragToPan)
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.25)) { zoom = 1; pan = .zero }
            }
            .animation(.interactiveSpring, value: zoom)
            .contentShape(Rectangle())
            .clipped()
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), maxZoom)
                if zoom == 1 { pan = .zero } // snap back to centre at fit
            }
    }

    /// Panning only bites once zoomed in — at fit there's nothing to pan, so a
    /// drag there is ignored (leaving room for other interactions).
    private var dragToPan: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = zoom > 1 ? value.translation : .zero
            }
            .onEnded { value in
                guard zoom > 1 else { return }
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }
}

/// The right-hand details column: a thin stack of the metadata, provenance, and
/// source-action sections (ported from the former `InspectorView`, minus the
/// small preview). Each section is its own subview so the column stays a clean
/// seam — the tags editor slots in between provenance and actions.
private struct DetailSidebar: View {
    let asset: Asset
    let source: Source?
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    let actions: ItemDetailActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MetadataSection(asset: asset)
                if let source {
                    ProvenanceSection(source: source)
                }
                TagsSection(tags: tags, onAddTag: onAddTag, onRemoveTag: onRemoveTag)
                ActionsSection(actions: actions)
            }
            .padding()
        }
    }
}

// MARK: - Sections

/// Kind / dimensions / (duration) / size / type / captured-at.
private struct MetadataSection: View {
    let asset: Asset

    var body: some View {
        DetailSection("Details") {
            DetailRow("Kind", DetailFormat.kind(asset.kind))
            // Byte-backed metadata is present only for image/video (003 · O1).
            if let w = asset.width, let h = asset.height {
                DetailRow("Dimensions", "\(w) × \(h)")
            }
            if asset.kind == .video, let duration = asset.duration {
                DetailRow("Duration", DetailFormat.duration(duration))
            }
            if case let .color(hex) = asset.content {
                DetailRow("Hex", hex.uppercased())
            }
            if let size = asset.fileSize {
                DetailRow("Size", DetailFormat.size(size))
            }
            if let mime = asset.mimeType {
                DetailRow("Type", mime)
            }
            DetailRow("Captured", DetailFormat.date(asset.createdAt))
        }
    }
}

/// Capture provenance — platform, author, title, and the original URL.
private struct ProvenanceSection: View {
    let source: Source

    var body: some View {
        DetailSection("Source") {
            DetailRow("Platform", DetailFormat.platform(source.platform))
            if let name = source.authorName, !name.isEmpty {
                DetailRow("Author", name)
            }
            if let handle = source.authorHandle, !handle.isEmpty {
                DetailRow("Handle", handle)
            }
            if let title = source.title, !title.isEmpty {
                DetailRow("Title", title)
            }
            if let url = source.originalURL, !url.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original URL").foregroundStyle(.secondary).font(.callout)
                    Text(url)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            } else {
                DetailRow("Original URL", "—")
            }
        }
    }
}

/// Source actions + the membership-only / library-wide delete pair. Each button
/// renders only when its action was supplied — a disabled `openSource` (no URL)
/// passes `nil`, and a Space board omits the folder-scoped remove/delete pair.
private struct ActionsSection: View {
    let actions: ItemDetailActions

    var body: some View {
        VStack(spacing: 8) {
            actionButton(actions.openSource, "Open Original Source", "safari")
            actionButton(actions.openBlob, "Open Full Resolution", "photo")
            actionButton(actions.revealInFinder, "Reveal in Finder", "folder")
            actionButton(actions.copySourceLink, "Copy Source Link", "link")

            if actions.removeFromFolder != nil || actions.requestDelete != nil {
                Divider().padding(.vertical, 2)
            }
            // Membership-only (reversible) vs library-wide (destructive) delete.
            // Both are hidden (not just disabled) where they don't apply, e.g. on
            // a Space board where the placement — not a folder membership — is the
            // unit of removal.
            if let removeFromFolder = actions.removeFromFolder {
                Button(action: removeFromFolder) {
                    Label("Remove from Folder", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            if let requestDelete = actions.requestDelete {
                Button(role: .destructive, action: requestDelete) {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.large)
    }

    /// A full-width labelled button, disabled (greyed, still visible) when its
    /// action is absent — matches the old "no source URL" affordance.
    @ViewBuilder
    private func actionButton(
        _ action: (() -> Void)?, _ title: String, _ symbol: String
    ) -> some View {
        Button {
            action?()
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .disabled(action == nil)
    }
}

/// The item's tags as removable chips plus an add field — the app's first tags
/// surface. User vs agent tags are visually distinguished (agent tags carry a
/// sparkle + tint) so agent-written organization stays reviewable.
private struct TagsSection: View {
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    @State private var draft = ""

    var body: some View {
        DetailSection("Tags") {
            if !tags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        TagChip(tag: tag) { onRemoveTag(tag) }
                    }
                }
            }
            TextField("Add tag…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDraft)
        }
    }

    /// Commit the field on Return; the funnel trims + validates, so we only guard
    /// the trivially-empty case here and clear on submit.
    private func commitDraft() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onAddTag(name)
        draft = ""
    }
}

/// A single tag pill with a remove button.
private struct TagChip: View {
    let tag: Tag
    let onRemove: () -> Void

    private var isAgent: Bool { tag.source == .agent }

    var body: some View {
        HStack(spacing: 4) {
            if isAgent {
                Image(systemName: "sparkles").font(.caption2)
            }
            Text(tag.name).font(.callout)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove tag")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (isAgent ? Color.purple : Color.secondary).opacity(0.15), in: Capsule())
    }
}

/// A minimal left-to-right flow layout that wraps chips onto new rows when they
/// exceed the available width (the sidebar's fixed 300pt column).
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Shared building blocks

/// A titled group in the detail sidebar.
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

/// A label-on-the-left, selectable-value-on-the-right metadata row.
private struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// Value formatting for the detail sidebar.
private enum DetailFormat {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `m:ss` for a video's playback duration (seconds).
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A human-facing label for an asset kind (003 · O1).
    static func kind(_ kind: AssetKind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .tweet: "Tweet"
        case .link: "Link"
        case .color: "Color"
        }
    }

    /// A human-facing label for a capture platform.
    static func platform(_ platform: Platform) -> String {
        switch platform {
        case .twitter: "Twitter / X"
        case .pinterest: "Pinterest"
        case .instagram: "Instagram"
        case .cosmos: "Cosmos"
        case .web: "Web"
        case .localPaste: "Pasted"
        case .localDrag: "Dragged in"
        }
    }
}
