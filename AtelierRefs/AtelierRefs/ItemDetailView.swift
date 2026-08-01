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

/// Force AVKit into the process before the first ``VideoPlayer`` is built.
///
/// `VideoPlayer` lives in the `_AVKit_SwiftUI` cross-import overlay, and its
/// backing `NSView` subclasses AVKit's `AVPlayerView` — resolved lazily, by
/// mangled name (`So12AVPlayerViewC`), when SwiftUI first instantiates the
/// representable. But neither the overlay nor this app references an AVKit
/// symbol directly, so the linker drops the framework the `import AVKit`
/// autolink asked for, and the runtime lookup finds nothing:
///
///     failed to demangle superclass of VideoPlayerView from mangled name
///     'So12AVPlayerViewC'
///
/// — a `swift::fatalError` → `abort()`, i.e. a hard crash on the first video
/// item opened. Touching the class is a real symbol reference, so AVKit keeps
/// its load command (verified: `otool -L` lists AVKit only with this call in).
@inline(never)
private func linkAVKit() {
    _ = NSStringFromClass(AVPlayerView.self)
}

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
    /// The internal identity this view's drag-out carries alongside the file (192):
    /// lets in-app drop targets recognise the drag as internal — the import guard
    /// refuses it rather than re-ingesting the app's own file. Hosts that know the
    /// shown item's collection pass a real payload (asset + source collection);
    /// the membership-less hosts (search, Space) leave the semantics-free marker.
    var dragPayload: AssetDragPayload = .internalMarker
    /// An instant placeholder (e.g. the 1280 tier) shown while full-res decodes.
    let previewImage: NSImage?
    /// The LRU-cached full-res image supplied by ``DetailSession`` (036 §3 B2),
    /// already decoded off-main. Only consulted when ``usesExternalImageLoader`` is
    /// true; `nil` (the default) leaves this view on its own decode path.
    var displayImage: CGImage? = nil
    /// When true, this view is driven by a ``DetailImageLoader`` (the collection
    /// detail overlay): it renders ``displayImage`` and does NOT decode the blob
    /// itself, which is the per-step uncached full-res decode B2 removes. Left
    /// false for the Space board + library search, which still own their decode.
    var usesExternalImageLoader: Bool = false
    /// Reports the media area's FIT long side in PIXELS (points × display scale) and
    /// the current zoom to the driving ``DetailSession`` (036 §3 B3), so it can pick
    /// the decode tier — preview for a ≤1280 viewport, a downsampled FIT decode for a
    /// larger one, native on zoom-in. Only the loader-backed collection overlay wires
    /// this; the Space board / library search leave it `nil` (they own their decode),
    /// so measuring is a no-op there.
    var onDisplayTarget: ((_ fitLongSidePx: CGFloat, _ zoom: CGFloat) -> Void)? = nil
    /// The item's tags + their editors.
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    /// The asset's collection memberships + the full library list for the "Add"
    /// picker, plus their editors (041 · Details "Collections" chips). A host with
    /// no collection context (none today — all three load them) passes `[]`.
    var collections: [Collection] = []
    var allCollections: [Collection] = []
    var onAddToCollection: (Collection) -> Void = { _ in }
    var onRemoveFromCollection: (Collection) -> Void = { _ in }
    /// Persist the item's Name / Note (041 · Details). Default no-ops keep older
    /// call sites compiling; every real host wires them to the funnel.
    var onSetName: (String) -> Void = { _ in }
    var onSetNote: (String) -> Void = { _ in }
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
    /// Zoom / pan for an image asset, lifted out of `ZoomableImage` so the top-bar
    /// buttons + ⌘± / ⌘0 can drive it (mouse/keyboard parity — pinch alone locked
    /// out non-trackpad users). Reset on navigation in `loadMedia`.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    /// The drag-out export item (011 · Cluster A) — the original blob + human
    /// filename this item drops as. Computed ONCE per asset in `loadMedia` (not per
    /// body pass, so no repeated `stat` during zoom/pan), `nil` for a media-less
    /// kind or a missing blob. Consumed by the media area's `.onDrag` at fit.
    @State private var exportItem: AssetExportItem?

    /// The media area's long side in POINTS, measured via `onGeometryChange` (036 §3
    /// B3). Combined with ``displayScale`` into the FIT pixel size reported through
    /// ``onDisplayTarget``. `0` until the first layout measures it.
    @State private var mediaLongSidePt: CGFloat = 0

    /// The backing-store scale (2 on Retina). Sharpness is set by PHYSICAL pixels, so
    /// the FIT target reported to the loader is points × this — a 700pt media area on
    /// a 2× display needs 1400px, not 700.
    @Environment(\.displayScale) private var displayScale

    /// Zoom ceiling (mirrors `ZoomableImage`'s pinch clamp) and the per-press step.
    private let maxZoom: CGFloat = 6
    private let zoomStep: CGFloat = 1.4

    /// True for the image branch — the only kind with a zoomable surface.
    private var isImage: Bool {
        if case .image = asset.content { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                mediaArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The art's stable dark ground, a shade below the panel: a light
                    // image and a dark one then sit on the same tone instead of the
                    // image's own edges reading as part of the chrome. `mediaBackdrop`
                    // has claimed this surface in its doc since it was written; it
                    // just was not applied, so the media sat on `panel`.
                    .background(Theme.Colors.mediaBackdrop)
                    // B3: measure the media area and report its FIT size + zoom up to
                    // the `DetailSession`, which picks the decode tier. `zoom` (the
                    // @State, not the transient pinch) only changes at a settle point
                    // — button press or gesture end — so reporting on it decodes at
                    // zoom SETTLE, never per pinch tick; the loader's bucket
                    // quantization is the second line of defence against a decode storm.
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        mediaLongSidePt = max(size.width, size.height)
                        reportDisplayTarget()
                    }
                    .onChange(of: zoom) { _, _ in reportDisplayTarget() }
                    // Zoom controls float over the media (image only) — the top bar
                    // is Back + pager only now (041), matching the Figma frame. The
                    // inset is `lg` to match `mediaArea`'s own padding, so the bar's
                    // edges line up with the ARTWORK's; at `md` it overhung the
                    // picture by 4pt.
                    .overlay(alignment: .bottomTrailing) {
                        if isImage { zoomControls.padding(Theme.Spacing.lg) }
                    }
                Divider()
                DetailSidebar(
                    asset: asset, source: source, tags: tags,
                    onAddTag: onAddTag, onRemoveTag: onRemoveTag,
                    collections: collections, allCollections: allCollections,
                    onAddToCollection: onAddToCollection,
                    onRemoveFromCollection: onRemoveFromCollection,
                    onSetName: onSetName, onSetNote: onSetNote,
                    onOpenSource: actions.openSource)
                    .frame(width: 298)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sit on the same panel tone as every other pane, so opening an item is no
        // longer a jump to the system background.
        .background(Theme.Colors.panel)
        // Reload media whenever the shown asset changes (open + prev/next).
        .task(id: asset.id) { await loadMedia() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        // Back pill (leading) · centered pager · overflow menu (trailing). Zoom
        // moved onto the media; the source title is dropped (041 · Figma `6:4`).
        ZStack {
            HStack {
                backButton
                Spacer()
                overflowMenu
            }
            if let navigator { pager(navigator) }
        }
        .padding(Theme.Spacing.md)
    }

    /// A rounded, hairline-bordered "Back" pill (⌘/Escape closes).
    private var backButton: some View {
        Button(action: onClose) {
            Label("Back", systemImage: "chevron.left")
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.horizontal, TopBarPill.inset)
        }
        .buttonStyle(TopBarPillButtonStyle())
        .keyboardShortcut(.cancelAction)
        .help("Back (esc)")
    }

    /// The centered `N / count` pager in a hairline pill, chevrons flanking it.
    ///
    /// The chevrons carry their own hover pad, so the pill's outer inset is `sm` where
    /// the other two take `TopBarPill.inset` — the glyph's padded hit area supplies the
    /// rest, the same trade ``selectionBarChrome()`` makes on its trailing edge.
    private func pager(_ navigator: ItemDetailNavigator) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button { navigator.step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(navigator.index <= 0)
                .help("Previous item (←)")

            Text("\(navigator.index + 1) / \(navigator.count)")
                .font(Theme.Typography.row).monospacedDigit()

            Button { navigator.step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(navigator.index >= navigator.count - 1)
                .help("Next item (→)")
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: Theme.Radius.chip, padding: Theme.Spacing.xs))
        // ONE ink for the whole pill. The numerals were tokenized and the chevrons
        // were not, so a single pill drew its text in two different whites.
        .foregroundStyle(Theme.Colors.inkPrimary)
        .padding(.horizontal, Theme.Spacing.sm)
        .topBarPill()
    }

    /// The source / lifecycle actions the Figma panel drops, relocated to a
    /// trailing overflow menu so nothing (Delete, Reveal, …) is lost (041). Each
    /// item renders only when its closure was supplied.
    private var overflowMenu: some View {
        Menu {
            if let openSource = actions.openSource {
                Button { openSource() } label: { Label("Open Original Source", systemImage: "safari") }
            }
            if let openBlob = actions.openBlob {
                Button { openBlob() } label: { Label("Open Full Resolution", systemImage: "photo") }
            }
            if let revealInFinder = actions.revealInFinder {
                Button { revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
            }
            if let copySourceLink = actions.copySourceLink {
                Button { copySourceLink() } label: { Label("Copy Source Link", systemImage: "link") }
            }
            if actions.removeFromFolder != nil || actions.requestDelete != nil {
                Divider()
            }
            if let removeFromFolder = actions.removeFromFolder {
                Button { removeFromFolder() } label: { Label("Remove from Folder", systemImage: "minus.circle") }
            }
            if let requestDelete = actions.requestDelete {
                Button(role: .destructive) { requestDelete() } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                // A GLYPH size, not a text role. It read `Typography.row`, which is
                // a sidebar-row text token — so the overflow icon tracked a
                // typography decision it has nothing to do with.
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.horizontal, TopBarPill.inset)
        }
        // `.button` + the shared pill style, NOT `.borderlessButton`: that style
        // swallows the label's padding whole — measured, the pill came out 20×14 next
        // to its 28pt-tall neighbours. `CollectionsField` below hit the identical trap
        // and fixed it the same way; this call site was simply missed.
        .menuStyle(.button)
        .buttonStyle(TopBarPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    /// Zoom out / percentage-reset / zoom in for image assets. The percentage
    /// button doubles as ⌘0 "fit," and a hidden ⌘= mirror makes zoom-in reachable
    /// without Shift (⌘+ on most layouts is Shift-⌘=).
    ///
    /// Wears the app's floating-bar chrome — the ``selectionBarChrome()`` recipe: an
    /// OPAQUE `field` capsule on a `hairlineStrong` border, lifted by
    /// ``Theme/Elevation/floating``. Opaque is the load-bearing word. These buttons
    /// carried NO style at all, so they got macOS's default bezel, which is a
    /// TRANSLUCENT vibrant material: over bright artwork the picture read straight
    /// through them and the bar looked like it sat UNDER the image. It never did — an
    /// `.overlay` always composites above its content, and the glyphs drew on top the
    /// whole time. The bezel was simply see-through.
    private var zoomControls: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                zoomBy(1 / zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1)
            .help("Zoom out (⌘−)")

            Button {
                resetZoom()
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 42)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit to view (⌘0)")

            Button {
                zoomBy(zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(zoom >= maxZoom)
            .help("Zoom in (⌘+)")
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: Theme.Radius.control, padding: Theme.Spacing.xs))
        .font(Theme.Typography.row)
        .foregroundStyle(Theme.Colors.inkPrimary)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.field, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
        .elevation(.floating)
        // ⌘= mirror (no Shift) — same action, no visible control. Kept OUT of the
        // HStack: inside it the bar's `HoverButtonStyle` would give this zero-size
        // button a 4pt hover pad plus a spacing gap, i.e. stray width in a capsule
        // whose whole job is to hug three controls.
        .background {
            Button { zoomBy(zoomStep) } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("=", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Multiply the zoom by `factor`, clamped to `[1, maxZoom]`; snap the pan back
    /// to centre once we're at fit (nothing to pan there).
    private func zoomBy(_ factor: CGFloat) {
        withAnimation(Theme.Motion.gentle) {
            zoom = min(max(zoom * factor, 1), maxZoom)
            if zoom == 1 { pan = .zero }
        }
    }

    private func resetZoom() {
        withAnimation(Theme.Motion.gentle) {
            zoom = 1
            pan = .zero
        }
    }

    /// Report the media area's FIT pixel long side (points × display scale) and the
    /// current zoom to the driving ``DetailSession`` (036 §3 B3). A no-op until the
    /// area is measured, and off entirely for the non-loader callers (Space board /
    /// library search leave ``onDisplayTarget`` nil).
    private func reportDisplayTarget() {
        guard let onDisplayTarget, mediaLongSidePt > 0 else { return }
        onDisplayTarget(mediaLongSidePt * displayScale, zoom)
    }

    // MARK: - Media

    /// The image to draw in the media area (and the link/tweet card): when a
    /// ``DetailImageLoader`` drives this view, the loader's decoded ``displayImage``
    /// (a `CGImage` → `Image(decorative:)`, no `NSImage` lazy-decode); otherwise the
    /// internally-decoded ``fullImage``. The 1280 ``previewImage`` is the fallback
    /// either way until the full image lands. Returns `nil` → the media area shows a
    /// spinner (an image kind) or its own card (a media-less kind).
    private var mediaImage: Image? {
        if usesExternalImageLoader {
            if let cg = displayImage { return Image(decorative: cg, scale: 1) }
        } else if let ns = fullImage {
            return Image(nsImage: ns)
        }
        if let ns = previewImage { return Image(nsImage: ns) }
        return nil
    }

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
                // full-resolution image when it lands. Keyed by `asset.id` so the
                // zoom/pan resets on navigation but survives the preview→full swap.
                if let image = mediaImage {
                    // Zoom/pan lives in this view (top-bar buttons + ⌘± drive it),
                    // reset per-navigation in `loadMedia` — so no `.id(asset.id)`
                    // remount is needed to clear it.
                    ZoomableImage(image: image, zoom: $zoom, pan: $pan, maxZoom: maxZoom)
                } else {
                    ProgressView()
                }
            case let .color(hex):
                ColorDetailView(hex: hex)
            case let .link(link):
                // With a resolved og:image, show it above the card; else just the card.
                LinkDetailView(link: link, image: mediaImage)
            case let .tweet(tweet):
                // With a captured card image, show it above the card; else the card.
                TweetDetailView(tweet: tweet, image: mediaImage)
            case .unknown:
                ContentUnavailableView(
                    "No preview", systemImage: "questionmark.square.dashed",
                    description: Text("This item has no displayable media."))
            }
        }
        .padding(Theme.Spacing.lg)
        // Drag-out (011 · Cluster A): drag the media pane to export the original
        // file to Finder / Figma / …. Gated to fit (`zoom == 1`) so it never fights
        // the zoom-in pan gesture — and because `zoom` commits only at gesture END,
        // this toggles between gestures, never mid-pinch (no remount hitch).
        .modifier(DetailDragOutModifier(
            item: zoom == 1 ? exportItem : nil, payload: dragPayload))
        // Edit ▸ Copy (⌘C, 052 · B1) on the open item — copies the original file
        // (image, video, or a link/tweet's captured image), or nothing for a
        // media-less item. Reuses the drag-out provider so ⌘C and drag-out stay
        // byte-identical; unaffected by zoom (only the drag gesture is fit-gated).
        .onCopyCommand {
            exportItem.map { [AssetExport.dragProvider(item: $0, payload: dragPayload)] } ?? []
        }
    }

    /// Reset zoom, (re)build the video player, and — on the non-loader path only —
    /// decode the full-resolution image off-main for the current asset.
    ///
    /// Under ``usesExternalImageLoader`` (036 §3 B2) the image is fed in via
    /// ``displayImage`` from the LRU ``DetailImageLoader``, so this view does NOT
    /// decode it here — that internal decode is the per-step uncached full-res
    /// decode B2 removes (root cause 3). The Space board + library search still own
    /// their decode (no loader wired), so the arm below stays for them.
    private func loadMedia() async {
        fullImage = nil
        // Fresh item → back to fit (the previous item's zoom shouldn't carry over).
        zoom = 1
        pan = .zero
        player?.pause()
        player = nil
        // Drag-out export item (011 · Cluster A): the original blob + human name for
        // this asset. Computed once here, `nil` for a media-less kind / missing blob.
        exportItem = source.flatMap { AssetExport.exportItem(asset: asset, source: $0, blobURL: blobURL) }
        // Media-less kinds (003 · O1) have no blob — nothing to load off-disk.
        guard let url = blobURL else { return }
        switch asset.kind {
        case .video:
            // Before the media area builds its `VideoPlayer` — see `linkAVKit`.
            linkAVKit()
            player = AVPlayer(url: url)
        case .image, .link, .tweet:
            // The loader owns the image on the collection detail path.
            guard !usesExternalImageLoader else { break }
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

// MARK: - Top-bar pill

/// Geometry for the detail top bar's three pills — Back, the pager, the ⋯ menu.
private enum TopBarPill {
    /// Every pill is exactly this tall, so the bar reads as ONE row.
    ///
    /// A fixed height rather than vertical padding, and that is the whole point.
    /// Padding sizes a pill from its content's INTRINSIC height, and the three
    /// contents do not agree: "Back" is a full text line, while `⋯` is three dots on
    /// the baseline with almost no height at all. The same declared 12/6 inset
    /// therefore produced a 28pt Back pill beside a 14pt ⋯ pill — measured, not
    /// guessed — and no amount of padding tuning closes that, because the gap is in
    /// the glyph, not the inset. 28 is what Back and the pager already measured.
    static let height: CGFloat = 28
    /// Edge-to-content inset for a pill whose content carries no pad of its own.
    static let inset: CGFloat = Theme.Spacing.md
}

private extension View {
    /// The shared pill container: a `filmstrip` capsule on a `hairlineStrong` border,
    /// at ``TopBarPill/height``.
    ///
    /// `hovered` lays the `hoverControl` wash OVER the pill's opaque fill, for a pill
    /// that is itself the button. It has to be composited on this side because the
    /// shared ``HoverHighlight`` draws into a `.background` — which would land BEHIND
    /// the opaque `filmstrip` and never show. Same token, other side of the fill. A
    /// pill that merely CONTAINS buttons (the pager) leaves this false and lets its
    /// glyphs own the hover.
    func topBarPill(hovered: Bool = false) -> some View {
        frame(height: TopBarPill.height)
            .background {
                ZStack {
                    Capsule().fill(Theme.Colors.filmstrip)
                    if hovered { Capsule().fill(Theme.Colors.hoverControl) }
                }
            }
            .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
    }
}

/// A whole-pill button (Back, the ⋯ menu): the shared container, brightened on
/// pointer-over and dimmed while pressed or disabled.
private struct TopBarPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    /// A nested view rather than a bare `configuration.label`, for the reason
    /// ``DialogButtonStyle`` documents: a `ButtonStyle` cannot read
    /// `@Environment(\.isEnabled)` inside `makeBody`.
    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .topBarPill(hovered: isHovering && isEnabled)
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.35))
                .onHover { isHovering = $0 }
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
    var image: Image?

    private var host: String? { URL(string: link.url)?.host }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                Image(systemName: "link")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }

            if let title = link.title, !title.isEmpty {
                Text(title)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                    .multilineTextAlignment(.center)
            }
            if let host {
                Text(host).font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            if let description = link.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if let url = URL(string: link.url) {
                Link(destination: url) {
                    Label("Open Link", systemImage: "safari")
                }
                // The app's inline action, not `.borderedProminent` — which paints the
                // system ACCENT, and this palette is monochrome by design (Theme).
                .buttonStyle(DialogButtonStyle(width: .hug))
            }
            Text(link.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Colors.inkSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(Theme.Spacing.xxl)
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
    var image: Image?

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
        VStack(spacing: Theme.Spacing.lg) {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }

            if let name = tweet.authorName, !name.isEmpty {
                Text(name).font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.inkPrimary)
            }
            Text(byline).font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkSecondary)

            if let text = tweet.text, !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if !tweet.media.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("^[\(tweet.media.count) media](inflect: true)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                    ForEach(tweet.media, id: \.url) { media in
                        if let mediaURL = URL(string: media.url) {
                            Link(destination: mediaURL) {
                                Label(media.url, systemImage: "photo")
                                    .font(Theme.Typography.caption)
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
                // See `LinkDetailView` — the accent-painted system button has no place
                // in a monochrome palette.
                .buttonStyle(DialogButtonStyle(width: .hug))
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: 520)
    }
}

/// The detail-page media view for a media-less `color` asset (003 · C1): a large
/// rounded swatch of the color with its canonical hex beneath, selectable.
private struct ColorDetailView: View {
    let hex: String

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                // An unparseable hex falls back to the app's raised grey, not to a
                // system label colour.
                .fill(Color(hexString: hex) ?? Theme.Colors.field)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420, maxHeight: 420)
            Text(hex.uppercased())
                .font(.system(.title2, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Zoomable image

/// A fit-to-view image with pinch-to-zoom and (once zoomed) drag-to-pan; a
/// double-click snaps back to fit. Zoom/pan are OWNED by the caller
/// (``ItemDetailView``) so the top-bar buttons + ⌘± / ⌘0 drive the same state the
/// pinch does; the caller resets them on navigation.
/// Adds the drag-out `.onDrag` when an ``AssetExportItem`` is present, else leaves
/// the content untouched (011 · Cluster A). A single `NSItemProvider(contentsOf:)`
/// vends the original blob file; `suggestedName` gives the drop the human filename
/// (shared with the grid via `AssetExport`). Passing `nil` (media-less, or zoomed
/// in) removes the drag entirely, so the zoom pan gesture is never contested.
private struct DetailDragOutModifier: ViewModifier {
    let item: AssetExportItem?
    /// Registered on the provider as `.assetIDs` so an in-app drop knows this
    /// drag is internal (192) — see `AssetExport.dragProvider`.
    let payload: AssetDragPayload

    func body(content: Content) -> some View {
        if let item {
            content.onDrag { AssetExport.dragProvider(item: item, payload: payload) }
        } else {
            content
        }
    }
}

private struct ZoomableImage: View {
    let image: Image
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    /// Ceiling so a huge pinch can't lose the image off-screen (passed in so it
    /// matches the button clamp).
    let maxZoom: CGFloat

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        image
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

/// The right-hand details column (041 · Figma `6:4`): three sections — **Data**
/// (saved + dimensions), **Source** (platform / author / title + Visit), and
/// **Details** (Name, Note, Collections, Tags). The former in-panel Actions block
/// moved to the top-bar overflow menu.
private struct DetailSidebar: View {
    let asset: Asset
    let source: Source?
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    let collections: [Collection]
    let allCollections: [Collection]
    let onAddToCollection: (Collection) -> Void
    let onRemoveFromCollection: (Collection) -> Void
    let onSetName: (String) -> Void
    let onSetNote: (String) -> Void
    let onOpenSource: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                DataSection(asset: asset)
                if let source {
                    SourceSection(source: source, onOpenSource: onOpenSource)
                }
                DetailsSection(
                    asset: asset, tags: tags, onAddTag: onAddTag, onRemoveTag: onRemoveTag,
                    collections: collections, allCollections: allCollections,
                    onAddToCollection: onAddToCollection,
                    onRemoveFromCollection: onRemoveFromCollection,
                    onSetName: onSetName, onSetNote: onSetNote)
            }
            .padding(Theme.Spacing.lg)
        }
    }
}

// MARK: - Sections

/// "Data" — saved date + dimensions only (041; the richer metadata rows moved
/// off the panel to match the Figma frame).
private struct DataSection: View {
    let asset: Asset

    var body: some View {
        DetailSection("Data") {
            DetailRow("Saved", DetailFormat.savedDate(asset.createdAt))
            if let w = asset.width, let h = asset.height {
                DetailRow("Dimensions", "\(w)px x \(h)px")
            }
        }
    }
}

/// "Source" — platform / author / title, then a full-width Visit button that
/// opens the original URL (041; the raw-URL + handle rows are gone).
private struct SourceSection: View {
    let source: Source
    let onOpenSource: (() -> Void)?

    /// "Name (@handle)" when both are present; whichever exists otherwise.
    private var author: String? {
        let name = source.authorName?.trimmingCharacters(in: .whitespaces)
        let handle = source.authorHandle?.trimmingCharacters(in: .whitespaces)
        switch (name?.isEmpty == false ? name : nil, handle?.isEmpty == false ? handle : nil) {
        case let (n?, h?): return "\(n) (\(h))"
        case let (n?, nil): return n
        case let (nil, h?): return h
        default: return nil
        }
    }

    var body: some View {
        DetailSection("Source") {
            DetailRow("Platform", DetailFormat.platform(source.platform))
            if let author { DetailRow("Author", author) }
            if let title = source.title, !title.isEmpty {
                DetailRow("Title", title)
            }
            if let onOpenSource {
                VisitButton(action: onOpenSource)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }
}

/// A full-width field-styled "Visit ↗" button (041 · Source / links).
private struct VisitButton: View {
    let action: () -> Void

    /// Owned here rather than taken from ``HoverHighlight`` for the reason
    /// ``topBarPill(hovered:)`` documents — the wash has to composite OVER this
    /// button's own opaque `field` fill.
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field)
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Visit").font(Theme.Typography.label)
                Image(systemName: "arrow.up.right").font(.system(size: 11))
            }
            .foregroundStyle(Theme.Colors.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xs + 2)
            .background {
                ZStack {
                    shape.fill(Theme.Colors.field)
                    if isHovering { shape.fill(Theme.Colors.hoverControl) }
                }
            }
            // The hairline every OTHER `field`-filled surface in this panel carries
            // (`DetailField`, `DetailChip`); this one was drawn fill-only.
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open the original source")
    }
}

/// "Details" — the item's editable surface: Name, Note, Collections, Tags (041).
private struct DetailsSection: View {
    let asset: Asset
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void
    let collections: [Collection]
    let allCollections: [Collection]
    let onAddToCollection: (Collection) -> Void
    let onRemoveFromCollection: (Collection) -> Void
    let onSetName: (String) -> Void
    let onSetNote: (String) -> Void

    var body: some View {
        DetailSection("Details", spacing: Theme.Spacing.lg) {
            // `.id(asset.id)` re-seeds the draft when prev/next swaps the item.
            DetailField(label: "Name", placeholder: "Name this item",
                        initial: asset.name, onCommit: onSetName)
                .id(asset.id)
            DetailField(label: "Note", placeholder: "Add a note",
                        initial: asset.note, onCommit: onSetNote)
                .id(asset.id)
            CollectionsField(
                collections: collections, allCollections: allCollections,
                onAdd: onAddToCollection, onRemove: onRemoveFromCollection)
            TagsField(tags: tags, onAddTag: onAddTag, onRemoveTag: onRemoveTag)
        }
    }
}

// MARK: - Details fields

/// A labelled, field-styled text input that seeds from `initial` and commits on
/// Return or focus loss (041 · Name / Note).
private struct DetailField: View {
    let label: String
    let placeholder: String
    let initial: String?
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            Text(label).font(Theme.Typography.label).foregroundStyle(Theme.Colors.inkSecondary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .background(Theme.Colors.field, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                    .stroke(Theme.Colors.hairline, lineWidth: 1))
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { onCommit(draft) }
                }
        }
        .onAppear { draft = initial ?? "" }
    }
}

/// The asset's collection memberships as removable chips, plus an "Add" menu of
/// the collections it is NOT yet in (041 · Details / Collections).
private struct CollectionsField: View {
    let collections: [Collection]
    let allCollections: [Collection]
    let onAdd: (Collection) -> Void
    let onRemove: (Collection) -> Void

    private var addable: [Collection] {
        let current = Set(collections.map(\.id))
        return allCollections.filter { !current.contains($0.id) }
    }

    /// A real collection is ALWAYS removable — dropping its last real membership
    /// re-homes the asset to Unsorted (handled in the store), so it never orphans.
    /// Only the Unsorted home itself is non-removable when it is the sole
    /// membership (there is nothing to fall back to).
    private func removable(_ c: Collection) -> Bool {
        c.id != Collection.unsortedID || collections.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            Text("Collections").font(Theme.Typography.label).foregroundStyle(Theme.Colors.inkSecondary)
            TagFlowLayout(spacing: Theme.Spacing.sm) {
                Menu {
                    if addable.isEmpty {
                        Text("No other collections")
                    } else {
                        ForEach(addable) { c in Button(c.name) { onAdd(c) } }
                    }
                } label: {
                    DetailAddChip()
                }
                // `.button` + `.plain` so the Menu adds NO chrome of its own — the
                // DetailChip defines the pill, aligning it with the membership chips
                // (borderlessButton added an inset that broke the alignment).
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Add to a collection")

                ForEach(collections) { c in
                    DetailChip(c.name, trailing: removable(c) ? .remove { onRemove(c) } : .none)
                }
            }
        }
    }
}

/// The item's tags as removable chips plus a manual add affordance (041 · the ✦
/// icon and the "Add" chip both reveal an inline field — user-driven tagging, no
/// auto-tag service). Agent-written tags keep a leading ✦ inside the chip.
private struct TagsField: View {
    let tags: [Tag]
    let onAddTag: (String) -> Void
    let onRemoveTag: (Tag) -> Void

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Tags").font(Theme.Typography.label).foregroundStyle(Theme.Colors.inkSecondary)
                Button(action: startAdding) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                }
                // Same bare-glyph trap as the chip's `×` (229): `.plain` gave this no
                // hover and no tooltip-tracking area, so `.help` never appeared.
                .buttonStyle(HoverButtonStyle(
                    cornerRadius: Theme.Radius.chip, padding: Theme.Spacing.xs))
                .help("Add a tag")
            }
            TagFlowLayout(spacing: Theme.Spacing.sm) {
                Button(action: startAdding) { DetailAddChip() }
                    .buttonStyle(.plain)
                    .help("Add a tag")
                ForEach(tags) { tag in
                    DetailChip(tag.name, sparkle: tag.source == .agent,
                               trailing: .remove { onRemoveTag(tag) })
                }
            }
            if adding {
                TextField("Add tag…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs + 2)
                    .background(Theme.Colors.field, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                        .stroke(Theme.Colors.hairline, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { adding = false; draft = "" }
                    }
            }
        }
    }

    private func startAdding() {
        adding = true
        focused = true
    }

    /// Commit on Return; the funnel trims + validates, so we only guard the
    /// trivially-empty case and clear the field.
    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onAddTag(name) }
        draft = ""
        adding = false
    }
}

// MARK: - Chip

/// A bordered rounded-6px pill (041 chip style) — the shared Collections / Tags
/// chip. Optional leading ✦ (agent tags) and a trailing `+`/`×` affordance.
private struct DetailChip: View {
    enum Trailing {
        case none
        case add
        case remove(() -> Void)
    }

    let text: String
    let sparkle: Bool
    let trailing: Trailing
    /// Lays the hover wash over the chip's opaque `field` fill — set by the chips that
    /// are themselves buttons (the Add affordances). See ``topBarPill(hovered:)``.
    let hovered: Bool

    init(
        _ text: String, sparkle: Bool = false, trailing: Trailing = .none,
        hovered: Bool = false
    ) {
        self.text = text
        self.sparkle = sparkle
        self.trailing = trailing
        self.hovered = hovered
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if sparkle {
                Image(systemName: "sparkles").font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            Text(text).font(Theme.Typography.label).foregroundStyle(Theme.Colors.inkSecondary)
            switch trailing {
            case .none:
                EmptyView()
            case .add:
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            case let .remove(action):
                Button(action: action) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                }
                // Was a bare `.plain` glyph: a 9.5×9.5 click target (measured) with no
                // hover and — per 229 — no tooltip either, since a template `Image`'s
                // only hit-testable area is its opaque pixels, so `.help` had nothing
                // to track. Matches the search token's remove `×`, the same control.
                .buttonStyle(HoverButtonStyle(cornerRadius: 4, padding: 2))
                .help("Remove")
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs + 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip)
            ZStack {
                shape.fill(Theme.Colors.field)
                if hovered { shape.fill(Theme.Colors.hoverControl) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

/// The "Add" affordance shared by the Collections and Tags fields: a ``DetailChip``
/// that owns its own pointer-over state, because the wash composites over the chip's
/// opaque fill rather than behind it (see ``topBarPill(hovered:)``).
private struct DetailAddChip: View {
    @State private var isHovering = false

    var body: some View {
        DetailChip("Add", trailing: .add, hovered: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A minimal left-to-right flow layout that wraps chips onto new rows when they
/// exceed the available width (the sidebar's fixed 298pt column).
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

/// A titled group in the detail sidebar (041 · 20pt ink title over its rows).
private struct DetailSection<Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(_ title: String, spacing: CGFloat = Theme.Spacing.sm, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.inkPrimary)
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
        }
    }
}

/// A label-on-the-left, selectable-value-on-the-right metadata row (041 · 12pt).
private struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.Colors.inkSecondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Theme.Typography.label)
    }
}

/// Value formatting for the detail sidebar.
private enum DetailFormat {
    /// `dd/MM/yyyy` — the Figma "Saved" format (041), locale-independent.
    static func savedDate(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d/%02d/%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
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
