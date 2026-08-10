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

/// The post this item belongs to (307/309): its members in post order, the open
/// item's place in them, and a jump. `nil` for an ungrouped item, or a host with
/// no grouping context (the Space board) — so the page is unchanged for the
/// overwhelming majority of items.
///
/// Assembled by ONE pure factory, ``PostGroups/detailPost(forItem:thumbnailURL:jump:)``,
/// rather than per host: the two grid-backed hosts reach post data differently
/// (`CollectionView` reads `model.postGroups`, `LibrarySearch` builds its own), so
/// "plumb it through both hosts" would mean writing the same derivation twice
/// against different sources — the shape 316 was written to fix. Each host supplies
/// only its own `jump`.
struct ItemDetailPost {
    /// 0-based, within the post — NOT within the feed. The pager beside it counts
    /// the feed; this counts the post, and 070 §3.2 wants both said out loud.
    let index: Int
    /// Never `1`: ``PostGroups`` drops every group of one (`PostGrouping.swift:170`),
    /// so a would-be single is simply ungrouped and this whole value is `nil`.
    let memberCount: Int
    /// The members' blob hashes in post order, **index-aligned with ``index``**:
    /// `blobHashes[i]` is member `i`'s artwork, and `nil` is a MEDIA-LESS member (003 · O1
    /// — since 310 a post's members can be a mix of kinds), which draws a placeholder card
    /// rather than a gap.
    ///
    /// It began life compacted, with a doc that said the non-alignment was deliberate. That
    /// was a trap: ``jump`` takes a POST-RELATIVE index, and the spread calls it with the
    /// position of the card it drew — so one media-less member anywhere in a post silently
    /// shifted every card after it onto the wrong image. Alignment is the invariant that
    /// makes "the i-th card is member i" true by construction instead of by luck, and
    /// `[String?]` is how the compiler is told about it.
    let blobHashes: [String?]
    /// Resolve a blob hash to its on-disk thumbnail URL — the shape ``FanCard`` takes,
    /// and for its reason (080 §2.1): `AsyncThumbnail` keys its cache on the HASH, so
    /// a bare `[URL?]` would miss the shared cache and re-decode every card.
    let thumbnailURL: (String) -> URL?
    /// The post's representative id — the same `detail.item.id` the collapsed tile
    /// seeds its fan with (`MasonryGridItem.swift:731`), so the page's pile is the
    /// pile the user clicked whenever the grid drew one.
    let seed: UUID
    /// Jump to the member at a post-relative index. **Clamped by the callee**, not the
    /// caller: a reload can shrink the post while the page is open (080 §5 · T4.3).
    let jump: (Int) -> Void
}

/// Whether the page states the item's place in its post — the sidebar's "Post" row.
/// The mirror of the cell's own ``MasonryGridItem/showsPostChip``
/// (`MasonryGridItem.swift:686`), pure so the rule is pinned without a view harness
/// (080 §3.4 · "Visibility").
///
/// Named for the FACT, not the chrome: the position began life as a chip beside the
/// pager and moved into the sidebar (see ``SourceSection``), and the rule that decides
/// whether there is a position worth stating did not change when its drawing did.
///
/// `> 1` rather than `> 0` even though ``PostGroups`` never reports 1: it is the
/// rule the cell states, and stating it the same way twice is the point.
nonisolated func showsPostPosition(memberCount: Int) -> Bool { memberCount > 1 }

/// Whether the page draws its resting pile — the two blank cards behind the artwork —
/// the mirror of the cell's own ``MasonryGridItem/showsFan`` (`MasonryGridItem.swift:627`)
/// in name and shape, and pure for the same reason the chip's predicate is (080 §3.4).
///
/// The cell's second clause is `!postExpanded`; the page's is the zoom, and it is
/// deliberately NOT `zoom == 1`. 070 §5.2 proposed that gate as *"the same gate the
/// drag-out already uses"*, but `zoom` is `@State` that only moves at a settle point —
/// the live magnification is `ZoomableImage`'s `@GestureState pinch`, folded into `zoom`
/// in `MagnifyGesture.onEnded`. Gated on `zoom` alone the pile keeps drawing at FIT
/// geometry through every pinch, while the artwork scales away from underneath it, and
/// then vanishes when the fingers lift. So the caller hands in `zoom * pinch` (080 §2.3).
///
/// The tolerance rather than `== 1`: the scale is a product of two `CGFloat`s that a
/// gesture returns to fit by clamping, and a pile that failed to come back because the
/// last multiply landed on `0.9999999` would be a bug no one could reproduce.
nonisolated func showsFanPile(memberCount: Int, effectiveScale: CGFloat) -> Bool {
    memberCount > 1 && abs(effectiveScale - 1) < 0.001
}

/// Which members the spread actually draws, and how many it cannot (080 §3.5).
struct FanSpreadWindow: Equatable {
    /// Member indices in POST order — a contiguous run, so the spread reads as a slice of
    /// the carousel rather than a sample of it.
    let indices: [Int]
    /// The members outside the window: the `+N`. Zero when the whole post fits.
    let hidden: Int
}

/// The slice of a post the spread shows, centred on the open item.
///
/// A rednote note runs to 15 images ([020](../.docs/feature-todo/020-capture-rednote.md))
/// and a 15-card arc is a layout problem before it is a performance one — the cards would
/// be too small to recognise and the sweep too wide to sit under the picture. So the arc
/// is capped and the remainder is SAID, as `+N`, never silently dropped.
///
/// Centred on `currentIndex` and then clamped to the ends, which is the load-bearing part:
/// the open item must be inside the window at every position, including the last few of a
/// long post, or the spread would show you a slice you are not in. Walking a 15-post to
/// image 12 with a cap of 7 slides the window to `8…14` rather than leaving it at `0…6`.
///
/// Pure so the arithmetic is pinned without a view (080 §5) — this is where the
/// off-by-ones live, exactly as `DetailStep` documents for the pager's own clamp.
nonisolated func fanSpreadWindow(
    memberCount: Int, currentIndex: Int, cap: Int
) -> FanSpreadWindow {
    guard memberCount > 0, cap > 0 else { return FanSpreadWindow(indices: [], hidden: 0) }
    guard memberCount > cap else {
        return FanSpreadWindow(indices: Array(0..<memberCount), hidden: 0)
    }
    // Defensive: a reload can shrink a post while the page is open (080 §5 · T4.2), and a
    // stale index must not produce a window off the end of the list.
    let current = min(max(currentIndex, 0), memberCount - 1)
    // `cap / 2` before the item, the rest after — an even cap therefore leans one card
    // FORWARD, which is the direction → is walking.
    let start = min(max(current - cap / 2, 0), memberCount - cap)
    return FanSpreadWindow(indices: Array(start..<(start + cap)), hidden: memberCount - cap)
}

/// Where a `.aspectRatio(contentMode: .fit)` image of `contentWidth × contentHeight`
/// actually lands inside a `pane`-sized box, in that box's own coordinates (080 §3.2).
/// `nil` when the content has no intrinsic size to fit, or the box no room to fit it in.
///
/// The page measures the PANE (`onGeometryChange`, `:195`) and nothing anywhere computed
/// where the picture inside it ends up, so anything laid against the pane floats detached
/// on the long axis for every image whose aspect ratio differs from the pane's — which is
/// [313](313-a-carousel-outlined-in-black.md) reappearing on a new surface.
///
/// Fed from ``Asset/width`` / ``Asset/height`` (`Int?`, *"Intrinsic … layout without
/// decoding"*), so the answer is known before a single byte is decoded and does not
/// change when the 1280 preview swaps for the full-resolution image. `nil` dimensions are
/// a media-less kind (003 · O1) and mean no pile; zero or negative would be a corrupt row,
/// and returning `nil` for those keeps every consumer from having to divide by them.
///
/// Reporting the true drawn rect out of `ZoomableImage` was considered and rejected: it
/// would add a geometry → `@State` → layout loop to the one view already doing
/// state-driven geometry work (`reportDisplayTarget`), to buy a fraction of a point that
/// is invisible under a tilted card. Purity is the same argument ``fanPileGeometry``
/// already makes about itself — the "no card is ever clipped" invariant is testable across
/// aspect ratios instead of being eyeballed at one window size.
nonisolated func fitRect(contentWidth: Int?, contentHeight: Int?, in pane: CGSize) -> CGRect? {
    guard let contentWidth, let contentHeight, contentWidth > 0, contentHeight > 0,
          pane.width > 0, pane.height > 0
    else { return nil }
    let scale = min(pane.width / CGFloat(contentWidth), pane.height / CGFloat(contentHeight))
    let size = CGSize(width: CGFloat(contentWidth) * scale, height: CGFloat(contentHeight) * scale)
    return CGRect(
        x: (pane.width - size.width) / 2, y: (pane.height - size.height) / 2,
        width: size.width, height: size.height)
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
    /// Set the item's favorite flag (011 · U5). `nil` on a host with no writer
    /// wired, which hides the star entirely rather than drawing a dead control.
    var setFavorite: ((Bool) -> Void)?
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
    /// The post this item came from (307/309), or `nil` — an ungrouped item, a host
    /// with no grouping context, or grouping switched off. Defaulted so the Space
    /// board's call site is untouched.
    var post: ItemDetailPost? = nil
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

    /// The artwork's scale RIGHT NOW — `zoom` folded together with `ZoomableImage`'s
    /// transient pinch into one scalar (080 §2.3). ``zoom`` alone is a settle-point value
    /// and says `1` for the whole of a pinch out from fit; anything laid against the FIT
    /// geometry has to watch this instead or it sits still while the picture moves.
    /// Written by `ZoomableImage` from `onChange`, never during a body pass.
    @State private var effectiveZoom: CGFloat = 1

    /// The drag-out export item (011 · Cluster A) — the original blob + human
    /// filename this item drops as. Computed ONCE per asset in `loadMedia` (not per
    /// body pass, so no repeated `stat` during zoom/pan), `nil` for a media-less
    /// kind or a missing blob. Consumed by the media area's `.onDrag` at fit.
    @State private var exportItem: AssetExportItem?

    /// Whether the pointer is in the strip of artwork that opens the spread (080 §3.5).
    /// Hover alone, deliberately: a click there belongs to the artwork's own drag-out.
    @State private var isSpreadHovered = false

    /// The media area's size in POINTS, measured via `onGeometryChange` (036 §3 B3).
    /// `.zero` until the first layout measures it.
    ///
    /// Its long side feeds the FIT pixel size reported through ``onDisplayTarget``; both
    /// sides feed ``fitRect`` for the pile (080 §3.2), which is why the whole size is
    /// kept now rather than the one number B3 needed.
    @State private var mediaPaneSize: CGSize = .zero

    /// The media area's long side in POINTS. Combined with ``displayScale`` into the FIT
    /// pixel size reported through ``onDisplayTarget``.
    private var mediaLongSidePt: CGFloat { max(mediaPaneSize.width, mediaPaneSize.height) }

    /// Bumped by a click on the artwork to hand the keyboard back to the page (316).
    /// The ``DetailKeyCatcher`` claims focus once, when the page opens, and must not
    /// re-claim it on every redraw — that would pull the caret out of the sidebar's
    /// Name / Note field mid-word. So the field keeps the arrows for as long as it is
    /// being edited, and a click back on the picture is the "done editing" signal that
    /// returns them. A counter rather than a Bool: every click is a fresh request, and
    /// two in a row must both arrive.
    @State private var keyFocusToken = 0

    /// The star's live state (011 · U5). Local, and seeded from `asset.isFavorite`
    /// whenever the shown asset changes, for the same reason the Name / Note fields
    /// keep a local draft: the hosts hand this view an `Asset` VALUE captured when
    /// the page was presented, so a write that lands afterwards does not flow back
    /// into it. Optimistic — the funnel's `setFavorite` is idempotent and the grid
    /// behind reloads from the database, so the only thing this state can be wrong
    /// about is a write that failed, which surfaces on the model's alert.
    @State private var isFavorite = false

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
                    // The resting pile (080 §3.4), BEHIND the artwork and ABOVE the
                    // backdrop — hence between the two `.background`s, since each one
                    // stacks under the last. It is laid against the FITTED rect, not the
                    // pane: against the pane it would float detached on the long axis for
                    // every image whose aspect ratio isn't the window's (313).
                    .background(alignment: .center) { fanPile }
                    .background(Theme.Colors.mediaBackdrop)
                    // The spread sits OVER the artwork — it is the one piece of this
                    // feature you click, so it cannot be a background like the pile.
                    .overlay(alignment: .center) { fanSpread }
                    // B3: measure the media area and report its FIT size + zoom up to
                    // the `DetailSession`, which picks the decode tier. `zoom` (the
                    // @State, not the transient pinch) only changes at a settle point
                    // — button press or gesture end — so reporting on it decodes at
                    // zoom SETTLE, never per pinch tick; the loader's bucket
                    // quantization is the second line of defence against a decode storm.
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        mediaPaneSize = size
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
                    asset: asset, source: source, post: post, tags: tags,
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
        // ← / → (069). A keyboard-only view that holds first responder while the page is
        // up — see `DetailKeyCatcher` for why a `.keyboardShortcut` on the chevrons was
        // never going to arrive. Only when there is something to step: a Space board's
        // detail has no ordered set behind it, and must not take focus from the canvas.
        .background {
            if let navigator {
                // ⌫ / ⌘⌫ ride the same catcher (022 · D4): whichever host wired the
                // overflow menu's two verbs gets them on the keyboard too, and a host
                // that wired neither (Space, search) binds neither key.
                DetailKeyCatcher(
                    armToken: keyFocusToken, onStep: navigator.step,
                    onRemove: actions.removeFromFolder, onDestroy: actions.requestDelete)
            }
        }
        // Reload media whenever the shown asset changes (open + prev/next).
        .task(id: asset.id) { await loadMedia() }
        // Re-seed the star on open AND on every prev/next step — the page is one
        // view walking a run, so without `initial` + the id key it would show the
        // first item's state for the whole run.
        .onChange(of: asset.id, initial: true) { _, _ in isFavorite = asset.isFavorite }
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
            HStack(spacing: Theme.Spacing.sm) {
                backButton
                Spacer()
                if let setFavorite = actions.setFavorite { favoriteButton(setFavorite) }
                overflowMenu
            }
            if let navigator { pager(navigator) }
        }
        .padding(Theme.Spacing.md)
    }

    /// The favorite star (011 · U5) — a top-bar pill beside the overflow menu, so
    /// the state is visible without opening a menu and one click flips it. Filled
    /// when starred, outlined when not; the two glyphs share a metric, so toggling
    /// does not resize the pill and shove the menu sideways.
    ///
    /// The help text does NOT advertise ⌘D. That shortcut acts on the GRID's
    /// selection / lead, and prev-next stepping deliberately keeps the model's lead
    /// where it was (036 §3 B1 — the lead is synced once on close), so after a few
    /// steps ⌘D and this button would be aimed at different items. Naming the
    /// shortcut here would promise something the page cannot keep.
    private func favoriteButton(_ setFavorite: @escaping (Bool) -> Void) -> some View {
        Button {
            isFavorite.toggle()
            setFavorite(isFavorite)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.horizontal, Theme.Spacing.xs)
        }
        .buttonStyle(TopBarPillButtonStyle())
        .help(isFavorite ? "Remove from Favorites" : "Favorite")
        .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Favorite")
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
    /// rest, the same trade ``floatingBarChrome(leading:trailing:vertical:)`` makes on
    /// its trailing edge.
    ///
    /// These are the app's only NESTED bar glyphs, so they take ``CompactBarIcon``
    /// rather than the 30×28 unit: this pill is 28pt tall, which a 28pt glyph would
    /// fill edge to edge. That is the whole of the rule — standalone bar or nested in
    /// a pill — and it replaces four sizes arrived at by four different
    /// `HoverButtonStyle` paddings.
    private func pager(_ navigator: ItemDetailNavigator) -> some View {
        HStack(spacing: 2) {
            // No `.keyboardShortcut` on either chevron: the arrows are handled by
            // `DetailKeyCatcher`, which is the only path that actually receives them,
            // and a second registration here would risk stepping twice per press.
            Button { navigator.step(-1) } label: { CompactBarIcon(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .disabled(navigator.index <= 0)
                .help("Previous item (←)")

            Text("\(navigator.index + 1) / \(navigator.count)")
                .font(Theme.Typography.row).monospacedDigit()

            Button { navigator.step(1) } label: { CompactBarIcon(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(navigator.index >= navigator.count - 1)
                .help("Next item (→)")
        }
        // ONE ink for the whole pill. The numerals were tokenized and the chevrons
        // were not, so a single pill drew its text in two different whites.
        .foregroundStyle(Theme.Colors.inkPrimary)
        .padding(.horizontal, Theme.Spacing.xs)
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
    /// Wears the app's floating-bar chrome by CALLING it —
    /// ``floatingBarChrome(leading:trailing:vertical:)`` — rather than restating the
    /// recipe. An OPAQUE `field` capsule on a `hairlineStrong` border, lifted by
    /// ``Theme/Elevation/floating``. Opaque is the load-bearing word. These buttons
    /// carried NO style at all, so they got macOS's default bezel, which is a
    /// TRANSLUCENT vibrant material: over bright artwork the picture read straight
    /// through them and the bar looked like it sat UNDER the image. It never did — an
    /// `.overlay` always composites above its content, and the glyphs drew on top the
    /// whole time. The bezel was simply see-through.
    ///
    /// The fix that followed re-declared those four lines locally, which is how this
    /// bar came to be 29pt tall next to a 40pt selection bar: its glyphs were
    /// `HoverButtonStyle` at intrinsic size, not the app's 30×28 unit. Both are the
    /// shared ones now. Icon-only, so it takes the balanced `trailing: 16` the board's
    /// action bar takes — the percentage reads as a value, not as a leading label.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            SelectionBarButton("minus.magnifyingglass", help: "Zoom out (⌘−)") {
                zoomBy(1 / zoomStep)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1)

            Button {
                resetZoom()
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(Theme.Typography.row)
                    .monospacedDigit()
                    // The one non-glyph item in the row, so it claims the glyph's
                    // HEIGHT and only widens for its digits — a 42pt minimum that
                    // "100%" fills and "8%" does not, so the bar never twitches.
                    .frame(minWidth: 42, minHeight: SelectionBarIcon.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.inkPrimary)
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit to view (⌘0)")

            SelectionBarButton("plus.magnifyingglass", help: "Zoom in (⌘+)") {
                zoomBy(zoomStep)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(zoom >= maxZoom)
        }
        .floatingBarChrome(trailing: Theme.Spacing.lg)
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

    /// The box the artwork is actually fitted into: the measured pane less ``mediaArea``'s
    /// own `lg` padding on every side. `fitRect` is fed THIS, not `mediaPaneSize`, or the
    /// pile would sit 16pt proud of the picture on the constraining axis.
    private var mediaContentSize: CGSize {
        CGSize(
            width: max(0, mediaPaneSize.width - 2 * Theme.Spacing.lg),
            height: max(0, mediaPaneSize.height - 2 * Theme.Spacing.lg))
    }

    /// The resting pile: two blank tilted cards behind the fitted artwork, saying *"this
    /// item belongs to a post"* in the grid's own vocabulary (080 §3.4).
    ///
    /// Drawn for ANY grouped item, including one opened out of an already-EXPANDED post
    /// whose tile drew no pile at all. 070 §2 justified the seed as making this
    /// "geometrically the same pile the user just clicked", and that claim does not hold
    /// in general — the grid fans only a COLLAPSED post (`MasonryGridItem.swift:627`), and
    /// since 316 made every member reachable, opening from an expanded post is ordinary.
    /// The pile is not a promise about the transition; suppressing it would leave the page
    /// silent in exactly the case the grid was silent too, and would drag grid view state
    /// across this view's presentation-only contract (`:10-15`).
    ///
    /// The image branch only. A media-less kind has no intrinsic size to fit (`fitRect`
    /// returns `nil` for it anyway) and video's fitted rect belongs to `AVPlayerView`'s
    /// own layout, controls included — 080 §7 defers what a non-image member should draw.
    @ViewBuilder
    private var fanPile: some View {
        if isImage, let post,
           let fitted = fitRect(
               contentWidth: asset.width, contentHeight: asset.height, in: mediaContentSize),
           min(fitted.width, fitted.height) >= DetailFanPileMetrics.minFittedSide {
            DetailFanPile(fitted: fitted.size, seed: post.seed)
                // Present but transparent while zoomed, rather than removed: the pile is
                // two rounded rectangles, and fading is what keeps a double-tap back to
                // fit (which snaps `zoom` to 1 instantly, then springs the picture home)
                // from popping the cards in a beat before the artwork arrives.
                .opacity(
                    showsFanPile(memberCount: post.memberCount, effectiveScale: effectiveZoom)
                        ? 1 : 0)
                .animation(Theme.Motion.gentle, value: effectiveZoom)
                // Decoration. The artwork's drag-out and the pan gesture own this area.
                .allowsHitTesting(false)
        }
    }

    /// The spread, and the strip of artwork that opens it (080 §3.5).
    ///
    /// **Why a hover ZONE and not the pile.** 070 §3.3 says "hovering the pile spreads
    /// it", but on the page the pile is BEHIND the artwork — only a few points of tilted
    /// corner ever show, which is a mean target, and the pile is deliberately
    /// hit-transparent so it cannot steal the drag-out. So the trigger is the bottom strip
    /// of the fitted artwork instead: where a filmstrip would live, big enough to find, and
    /// nowhere near the middle of the picture, so looking at an image never summons chrome
    /// over it.
    ///
    /// Gated on the same effective scale as the pile — one rule, not two: a zoomed page is
    /// for looking at ONE image, and a spread inviting you elsewhere is noise there.
    @ViewBuilder
    private var fanSpread: some View {
        if isImage, let post, showsPostPosition(memberCount: post.memberCount),
           let fitted = fitRect(
               contentWidth: asset.width, contentHeight: asset.height, in: mediaContentSize),
           min(fitted.width, fitted.height) >= DetailFanPileMetrics.minFittedSide {
            let open = isSpreadHovered
                && showsFanPile(memberCount: post.memberCount, effectiveScale: effectiveZoom)
            VStack {
                Spacer(minLength: 0)
                DetailFanSpread(post: post, fitted: fitted.size)
                    .opacity(open ? 1 : 0)
                    // Slides up out of the picture's edge rather than fading in place, so
                    // the pile behind the artwork reads as the thing that opened.
                    .offset(y: open ? 0 : DetailFanSpreadMetrics.raise * 2)
                    .allowsHitTesting(open)
                    .padding(.bottom, Theme.Spacing.md)
            }
            .frame(
                width: fitted.width,
                height: min(fitted.height, DetailFanSpreadMetrics.hoverZoneHeight),
                alignment: .bottom)
            // The zone is positioned on the ARTWORK's bottom edge, which is not the pane's
            // whenever the picture is letterboxed.
            .offset(y: (mediaContentSize.height - fitted.height) / 2)
            .contentShape(Rectangle())
            .onHover { isSpreadHovered = $0 }
            .animation(Theme.Motion.gentle, value: open)
        }
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
                    ZoomableImage(
                        image: image, zoom: $zoom, pan: $pan, maxZoom: maxZoom,
                        effectiveScale: $effectiveZoom)
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
        // A click on the picture takes the keyboard back from the sidebar's Name / Note
        // field (316) — otherwise ← / → stayed caret keys for the rest of the page's
        // life, because nothing hands focus back when a field is done with it.
        // `simultaneousGesture` so it never competes with the zoom/pan gesture or the
        // drag-out; a TapGesture only fires on a click that did NOT become a drag, so
        // dragging the image out is untouched. Scoped to the media area on purpose: the
        // same gesture over the sidebar would steal focus from the very field the user
        // just clicked into, on mouse-UP, and make it impossible to type in.
        .simultaneousGesture(TapGesture().onEnded { keyFocusToken &+= 1 })
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
        // And its live twin, which a media-less next item would otherwise leave holding
        // the previous picture's pinch — there is no `ZoomableImage` there to reset it.
        effectiveZoom = 1
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
    /// The shared pill container: the app's floating-bar surface, at
    /// ``TopBarPill/height``.
    ///
    /// It used to be a `filmstrip` capsule (#1A1A1C) on a **1.0pt** border with NO
    /// shadow — three departures from the floating recipe at once, on the one bar in
    /// the app that floats over full-bleed artwork. The zoom controls a few inches
    /// below carry a long comment about why an opaque, ELEVATED capsule is required
    /// there; this bar never got the same fix, so it read as printed onto the picture
    /// rather than lifted off it. Same tokens as every other bar now: `field`,
    /// `hairlineStrong` at 0.5, `Elevation.floating`.
    ///
    /// `hovered` lays the `hoverControl` wash OVER the pill's opaque fill, for a pill
    /// that is itself the button. It has to be composited on this side because the
    /// shared ``HoverHighlight`` draws into a `.background` — which would land BEHIND
    /// the opaque fill and never show. Same token, other side of the fill. A pill that
    /// merely CONTAINS buttons (the pager) leaves this false and lets its glyphs own
    /// the hover.
    func topBarPill(hovered: Bool = false) -> some View {
        frame(height: TopBarPill.height)
            .background {
                ZStack {
                    Capsule().fill(Theme.Colors.field)
                    if hovered { Capsule().fill(Theme.Colors.hoverControl) }
                }
            }
            .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
            .elevation(.floating)
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
    /// The scale the artwork is drawn at RIGHT NOW — `zoom × pinch`, published upward so
    /// anything laid against the FIT geometry can gate on it (080 §2.3). One scalar, not
    /// the pinch itself: `pinch` is meaningless without the `zoom` it multiplies, and the
    /// caller having to recombine them is how the wrong variable got read the first time.
    ///
    /// Written from `onChange`, never mid-body — a `@GestureState` moves on every tick of
    /// a magnification, and a binding written during a body pass is a state mutation
    /// inside view update.
    @Binding var effectiveScale: CGFloat

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(zoom * pinch)
            // `initial` so the first frame publishes fit rather than whatever the previous
            // item left behind, and so the gesture-end reset of `pinch` to 1 is reported
            // like any other change. Double-tap-to-reset rides this too: it sets `zoom`,
            // and `zoom` is half of the product.
            .onChange(of: zoom * pinch, initial: true) { _, scale in effectiveScale = scale }
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

// MARK: - The resting pile (307 · carousel grouping, 080 §3.4)

/// The page's pile in numbers. Internal rather than private so 080 §5 · T1 composes the
/// values the page actually uses — a test that re-typed `5, 12, 5` would keep passing
/// after someone retuned them here.
enum DetailFanPileMetrics {
    /// The deepest card's ideal tilt, matching the grid cell's. At page scale
    /// ``fanPileGeometry`` almost always reduces it (its cap is `2 · maxInset / longest
    /// side`, and the page's longest side is measured in hundreds of points), so this is
    /// the ceiling for a small window rather than the number usually drawn.
    static let maxDegrees: Double = 5
    /// The most the pile may swing out past the artwork — see ``DetailFanPile`` for why
    /// the cell's inset becomes an outset here, and why this stays under
    /// `Theme.Spacing.lg` (16), the padding it swings into.
    static let maxInset: CGFloat = 12
    /// A visible minimum, so the cards still read as cards behind a small picture.
    static let minInset: CGFloat = 5
    /// The cards' own corner rounding — `card`, not the grid's `tile`: this pile sits at
    /// picture scale, where the tile's 8pt reads as a sharp corner.
    static let cornerRadius: CGFloat = Theme.Radius.card
    /// Two, exactly as the grid tile draws two. The post's real size is said in words by
    /// the chip; a card per member is the spread's job (080 §3.5), if it ships.
    static let cardCount = 2
    /// The smallest fitted artwork worth putting a pile behind. A tall-and-thin asset
    /// (080 §5 · T1's `1 × 20000`) fits to a sliver a fraction of a point wide, where two
    /// tilted cards are not a pile but a smear — and where ``fanPileGeometry``'s "never
    /// eat more than half" ceiling starts governing its own answer.
    static let minFittedSide: CGFloat = 48
}

/// The spread's numbers (080 §3.5). Internal for the same reason as
/// ``DetailFanPileMetrics``: the tests compose the values the page actually draws with.
enum DetailFanSpreadMetrics {
    /// The most cards the arc will draw. Seven is odd on purpose — an odd cap puts the
    /// open item dead centre at every position except the two ends.
    static let cap = 7
    /// A card's long side in POINTS. Small enough that seven sit under the picture without
    /// crowding it, large enough to recognise a photo in.
    static let cardSide: CGFloat = 64
    /// The whole arc's sweep. Shallow — 070 §3.3 asks for "a shallow arc", and past about
    /// this the end cards lie on their sides and stop reading as a row.
    static let sweepDegrees: Double = 24
    /// How far apart neighbouring cards sit along the arc.
    static let cardSpacing: CGFloat = 52
    /// How far the current card lifts out of the arc, so "you are here" needs no marker.
    static let raise: CGFloat = 10
    /// The card's corner rounding — the pile's, so the two read as one family.
    static let cornerRadius: CGFloat = Theme.Radius.card
    /// The strip of the fitted artwork that opens the spread on hover, measured up from
    /// its bottom edge. A zone rather than the whole picture: the artwork is the thing you
    /// move the pointer across, and a spread that appeared on any hover would be in the way
    /// of looking at the image — which is the page's actual job.
    static let hoverZoneHeight: CGFloat = 96

    /// The pixel bucket a card decodes at, from its own point size.
    ///
    /// The pipeline requires the caller to size itself — *"the cell never guesses its own
    /// size (036 §4 C3)"* — and ``AsyncThumbnail/bucket`` defaults to the 512 ceiling,
    /// which for a 64pt card is sixteen times the pixels it can show, per card, on every
    /// spread of a cold post.
    static func bucket(scale: CGFloat) -> Int {
        thumbnailPixelBucket(pointLongSide: cardSide, scale: scale)
    }
}

/// Two blank tilted cards behind the fitted artwork — the third of the app's fanned piles
/// (080 §3.4 · *"Three fan implementations, and that is fine"*): SwiftUI like ``FanCard``,
/// aspect-sized and artwork-free like ``MasonryGridItem``'s, and neither one's code.
///
/// **Blank on purpose.** 080 §2.2 settled a contradiction in 070: these carry NO
/// thumbnails, exactly as the grid tile's do — *"they stand for 'more behind this', not
/// for any particular image"* — so the resting state costs two rounded rectangles rather
/// than a decode per member. Cards with artwork are the spread's job (§3.5).
///
/// **Why the cell's inset becomes an outset.** The tile pulls its ARTWORK in by
/// ``fanPileGeometry``'s inset to make room for the tilt inside a cell that clips. The
/// page cannot: the artwork is already at fit, and shrinking it would be a visible lurch
/// on every post you open. So the same inset is spent the other way round — the cards are
/// the fitted rect's own size and their corners swing OUT by (at most) that inset, into
/// `mediaArea`'s `lg` padding. The invariant is the same one either way, and 080 §5 · T1
/// pins it on this rectangle: an inset card fits the fitted rect ⟺ a fitted-size card
/// overhangs it by no more than the inset.
private struct DetailFanPile: View {
    /// The artwork's own rect, from ``fitRect`` — the pile is concentric with it.
    let fitted: CGSize
    /// The post's representative id. Stable across launches because ``fanRotations`` reads
    /// raw uuid bytes rather than `hashValue`, so this pile does not re-jitter per process
    /// — and it is the same seed the collapsed tile used, so it is the same pile whenever
    /// the grid drew one.
    let seed: UUID

    var body: some View {
        let (inset, degrees) = fanPileGeometry(
            in: fitted, maxDegrees: DetailFanPileMetrics.maxDegrees,
            maxInset: DetailFanPileMetrics.maxInset, minInset: DetailFanPileMetrics.minInset,
            cornerRadius: DetailFanPileMetrics.cornerRadius)
        // The tilt the geometry ACTUALLY allows at this size, not the ideal — a wide
        // panorama and a tall screenshot get different angles for the same reason a
        // masonry cell does.
        let angles = fanBackingRotations(
            seed: seed, cardCount: DetailFanPileMetrics.cardCount, maxDegrees: degrees)
        ZStack {
            ForEach(Array(angles.enumerated()), id: \.offset) { _, tilt in
                RoundedRectangle(cornerRadius: DetailFanPileMetrics.cornerRadius)
                    .fill(Theme.Colors.selection)
                    .overlay {
                        RoundedRectangle(cornerRadius: DetailFanPileMetrics.cornerRadius)
                            .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .rotationEffect(.degrees(tilt))
            }
        }
        // A rotation draws outside its layout bounds, so the box is claimed explicitly —
        // the pile RESERVES at least what it covers, for anything that later measures or
        // clips this background. (`inset` carries `fanPileGeometry`'s rounded-corner
        // allowance, which the swing itself does not spend, so the claim is a few points
        // generous rather than exact.)
        .frame(width: fitted.width + 2 * inset, height: fitted.height + 2 * inset)
    }
}

// MARK: - The spread (080 §3.5)

/// The pile opened: a shallow arc of the post's members with the current one raised,
/// click to jump (070 §3.3, 080 §3.5).
///
/// **What it adds over the arrows.** Since [316](316-detail-arrows-walk-the-post.md) a
/// post is contiguous in the run, so ← / → already walks it. The spread does not make the
/// walk possible; it makes it VISIBLE, and adds random access to a member four steps away.
///
/// **Cold by construction.** A collapsed post renders only its representative in the grid,
/// so every other member is absent from ``ThumbnailPipeline``'s cache — the spread is
/// coldest on exactly the posts it is most wanted for, and may open while ``DetailSession``
/// still has a full-res decode in flight. ``DetailFanSpreadMetrics/cap`` is the bound on
/// that, and the reason there is no prefetch here: the cheapest decode is the one a closed
/// spread never asks for.
private struct DetailFanSpread: View {
    let post: ItemDetailPost
    /// The artwork's own rect, so the arc sits under the PICTURE rather than the pane —
    /// the same rule the pile follows, and for [313](313-a-carousel-outlined-in-black.md)'s
    /// reason.
    let fitted: CGSize

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let window = fanSpreadWindow(
            memberCount: post.memberCount, currentIndex: post.index,
            cap: DetailFanSpreadMetrics.cap)
        HStack(spacing: DetailFanSpreadMetrics.cardSpacing
            - DetailFanSpreadMetrics.cardSide) {
            ForEach(window.indices, id: \.self) { member in
                card(member: member, window: window)
            }
            if window.hidden > 0 { overflowLabel(window.hidden) }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: fitted.width)
    }

    /// One member's card. A `Button`, not a tap gesture: the spread's whole point is that
    /// the cards are targets, and a button carries the focus ring and the accessibility
    /// action a bare gesture does not.
    private func card(member: Int, window: FanSpreadWindow) -> some View {
        let isCurrent = member == post.index
        // The card's place along the sweep, -1…1 across the drawn window, so the arc is
        // the same shape whether it holds three cards or seven.
        let span = max(window.indices.count - 1, 1)
        let position = Double(member - (window.indices.first ?? 0)) / Double(span)
        let tilt = (position - 0.5) * DetailFanSpreadMetrics.sweepDegrees
        return Button {
            // Post-relative, and the callee clamps (080 §5 · T4.3) — a reload can shrink
            // the post between this card being drawn and the click landing.
            post.jump(member)
        } label: {
            thumbnail(member: member)
                .frame(
                    width: DetailFanSpreadMetrics.cardSide,
                    height: DetailFanSpreadMetrics.cardSide)
                .clipShape(RoundedRectangle(cornerRadius: DetailFanSpreadMetrics.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: DetailFanSpreadMetrics.cornerRadius)
                        .strokeBorder(
                            isCurrent ? Theme.Colors.selectionMark : Theme.Colors.hairlineStrong,
                            lineWidth: isCurrent ? 2 : 1)
                }
                .rotationEffect(.degrees(tilt))
                // The raise IS the "you are here" marker — no badge, no dot.
                .offset(y: isCurrent ? -DetailFanSpreadMetrics.raise : 0)
                .zIndex(isCurrent ? 1 : 0)
        }
        .buttonStyle(.plain)
        .help("Image \(member + 1) of \(post.memberCount)")
        .accessibilityLabel("Image \(member + 1) of \(post.memberCount)")
    }

    /// A member's artwork, or the placeholder a media-less one draws (359). `nil` is a
    /// SLOT, not a gap: the member is real, it is counted, and it can be jumped to.
    @ViewBuilder
    private func thumbnail(member: Int) -> some View {
        if let hash = post.blobHashes[member] {
            AsyncThumbnail(
                hash: hash, url: post.thumbnailURL(hash),
                cornerRadius: DetailFanSpreadMetrics.cornerRadius,
                // Sized from the CARD, not defaulted — see `DetailFanSpreadMetrics.bucket`.
                bucket: DetailFanSpreadMetrics.bucket(scale: displayScale))
        } else {
            RoundedRectangle(cornerRadius: DetailFanSpreadMetrics.cornerRadius)
                .fill(Theme.Colors.mediaBackdrop)
                .overlay {
                    Image(systemName: "doc")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                }
        }
    }

    /// `+N` — the members the cap could not draw, said rather than dropped.
    private func overflowLabel(_ hidden: Int) -> some View {
        Text("+\(hidden)")
            .font(Theme.Typography.caption).monospacedDigit()
            .foregroundStyle(Theme.Colors.inkSecondary)
            .padding(.leading, DetailFanSpreadMetrics.cardSide
                - DetailFanSpreadMetrics.cardSpacing + Theme.Spacing.sm)
            .help("\(hidden) more in this post — walk to them with the arrow keys")
    }
}

/// The right-hand details column (041 · Figma `6:4`): three sections — **Data**
/// (saved + dimensions), **Source** (platform / author / title + Visit), and
/// **Details** (Name, Note, Collections, Tags). The former in-panel Actions block
/// moved to the top-bar overflow menu.
private struct DetailSidebar: View {
    let asset: Asset
    let source: Source?
    /// The post this item belongs to, for ``SourceSection``'s "Post" row. `nil` for an
    /// ungrouped item or a host with no grouping context.
    let post: ItemDetailPost?
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
                    SourceSection(source: source, post: post, onOpenSource: onOpenSource)
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

/// "Source" — platform / author / title / post, then a full-width Visit button that
/// opens the original URL (041; the raw-URL + handle rows are gone).
private struct SourceSection: View {
    let source: Source
    /// The post this item came out of (080 §3.3). It lives HERE, in Source, rather
    /// than in a section of its own: post grouping is derived from the source
    /// (`postGroupKey(for:)`), so an item that has a post always has this section,
    /// and "which image of the post" is provenance — the same kind of fact as the
    /// platform and the author, and read in the same glance.
    let post: ItemDetailPost?
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
            // "Image 2 of 4" — the item's place inside its carousel (307/309), which
            // the pager cannot express: that one counts the FEED. The pile behind the
            // artwork says a post is there; this row says which of it you are on.
            if let post, showsPostPosition(memberCount: post.memberCount) {
                DetailRow("Post", "Image \(post.index + 1) of \(post.memberCount)")
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

    @State private var showAdd = false

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
                // 026 · I1 — the shared indented destination tree, not the flat
                // alphabetical dump of `listCollections()` this used to filter.
                // A POPOVER, not a `Menu`: the shared list scrolls under a 240pt cap,
                // and a `Menu`'s content becomes `NSMenu` items, which cannot host a
                // `ScrollView`. The chrome discipline behind the old `.menuStyle(.button)`
                // survives as `.buttonStyle(.plain)` + `.fixedSize()` — the DetailChip
                // defines the pill, the trigger adds NO chrome of its own, so it stays
                // aligned with the membership chips beside it.
                Button { showAdd.toggle() } label: {
                    DetailAddChip()
                }
                .buttonStyle(.plain).fixedSize()
                .help("Add to a collection")
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    CollectionDestinationList(
                        folders: allCollections, unsortedID: Collection.unsortedID,
                        // The asset's OWN memberships are excluded rather than greyed:
                        // they are already chips beside this trigger, so a greyed row
                        // would say the same thing twice.
                        excluded: Set(collections.map(\.id)),
                        emptyTitle: "No other collections"
                    ) { id in
                        if let c = allCollections.first(where: { $0.id == id }) { onAdd(c) }
                        showAdd = false
                    }
                    .selectionMenuChrome()
                }

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

// MARK: - Keyboard (069)

/// ← / → → a pager step, or `nil` for every other key. The detail page's whole key map,
/// pure so it is tested without a window (the shape ``gridKeyCommand(characters:modifiers:)``
/// uses for the grid's).
///
/// Bare means bare: ⌘ / ⌥ / ⌃ disqualify, so ⌘← stays whatever the system does with it
/// and ⌥← stays a word jump in a text field. ⇧ is tolerated — the page has no range to
/// extend, so ⇧← can only have meant ←.
func detailStepDelta(characters: String, modifiers: NSEvent.ModifierFlags) -> Int? {
    guard !modifiers.contains(.command), !modifiers.contains(.option),
          !modifiers.contains(.control),
          let scalar = characters.unicodeScalars.first.map({ Int($0.value) })
    else { return nil }
    switch scalar {
    case NSLeftArrowFunctionKey: return -1
    case NSRightArrowFunctionKey: return 1
    default: return nil
    }
}

/// The detail page's arrow keys, delivered where AppKit will actually deliver them.
///
/// The page is an OVERLAY over the collection grid, and the grid's `NSCollectionView`
/// keeps first responder behind it: it takes focus on the very click that opens the page
/// ("focus follows the click"), and nothing resigns for it. Its `keyDown` consumes arrows
/// unconditionally — so the pager's `.keyboardShortcut(.leftArrow)` was never what ran,
/// and every press walked and scrolled a grid the user could not see while the page sat
/// still. `close()` then overwrote that cursor, which is why it read as a dead key.
///
/// 269 already wrote the conclusion this rests on: "`keyDown` only reaches a first
/// responder … so the canvas's own focus is the gate." A sibling `keyboardShortcut` is
/// not a gate. So the page gets a focus of its own — a keyboard-only view that borrows
/// first responder while the page is up and hands it back on the way out.
private struct DetailKeyCatcher: NSViewRepresentable {
    /// Bumped by a click on the artwork — take the keyboard back from a sidebar field
    /// (316). See ``ItemDetailView/keyFocusToken``.
    let armToken: Int
    /// Step the pager by ±1. The navigator bounds-checks, so both ends are no-ops.
    let onStep: (Int) -> Void
    /// ⌫ — remove this item from the collection the page was opened FROM (022 · D4).
    /// `nil` on a host with no membership context (a Space board, a search hit), which
    /// simply leaves the key unbound — the right answer there, not a gap.
    var onRemove: (() -> Void)?
    /// ⌘⌫ — delete this item from the library (stages the shared confirmation).
    var onDestroy: (() -> Void)?

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onStep = onStep
        view.onRemove = onRemove
        view.onDestroy = onDestroy
        view.armToken = armToken
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onStep = onStep
        view.onRemove = onRemove
        view.onDestroy = onDestroy
        // A click on the picture is an explicit request, so it reclaims focus even from
        // a text field. Anything else only arms if nothing else wanted the keyboard.
        if view.armToken != armToken {
            view.armToken = armToken
            view.reclaimFocus()
        } else {
            // Arm ONCE per presentation. This runs on every step and every zoom tick,
            // and a view that re-took first responder on each of those would rip focus
            // out of the sidebar's Name / Note field mid-word.
            view.armIfNeeded()
        }
    }

    final class KeyView: NSView {
        var onStep: ((Int) -> Void)?
        var onRemove: (() -> Void)?
        var onDestroy: (() -> Void)?
        /// The last artwork-click token acted on, so one click reclaims focus once.
        var armToken = 0
        /// Who the page borrowed focus from (the grid), so it can be given back.
        private weak var previousResponder: NSResponder?
        private var armed = false

        override var acceptsFirstResponder: Bool { true }

        /// Keyboard only. Returning `nil` keeps this out of mouse routing entirely, so a
        /// full-bleed background view can never shadow the media area's drag-out or the
        /// zoom gestures.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            armIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Leaving the window IS the page closing — give the grid its focus back, or
            // its own arrows would stay dead until the next click.
            if newWindow == nil { restoreResponder() }
        }

        /// Take first responder for the page, once, remembering who had it.
        ///
        /// Never steals from a text view: the sidebar's Name / Note fields are the one
        /// place on this page where ← / → legitimately mean "move the caret", and their
        /// field editor takes focus long after this has armed.
        func armIfNeeded() {
            guard !armed, let window else { return }
            guard !(window.firstResponder is NSText) else { return }
            armed = true
            previousResponder = window.firstResponder
            // A hop, like the canvas host's (269): this can fire from
            // `viewDidMoveToWindow`, mid-installation.
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        /// Take the keyboard back from whatever holds it — including a text field (316).
        ///
        /// `endEditing(for:)` first, so the field editor resigns through AppKit's own
        /// path: that is what makes `DetailField`'s focus-loss commit fire, so clicking
        /// the picture SAVES the name being typed rather than dropping it.
        func reclaimFocus() {
            guard let window, window.firstResponder !== self else { return }
            window.endEditing(for: nil)
            armed = true
            window.makeFirstResponder(self)
        }

        private func restoreResponder() {
            guard armed, let window, window.firstResponder === self else { return }
            armed = false
            window.makeFirstResponder(previousResponder)
        }

        override func keyDown(with event: NSEvent) {
            let characters = event.charactersIgnoringModifiers ?? ""
            if let delta = detailStepDelta(
                characters: characters, modifiers: event.modifierFlags) {
                onStep?(delta)
                return
            }
            // ⌫ removes from the collection this page was opened from, ⌘⌫ leaves the
            // library (022 · D4). They go HERE and not on a `.keyboardShortcut` for the
            // reason this whole view exists: a key equivalent fires before `keyDown`
            // reaches the first responder and cannot see that the responder is the
            // sidebar's Name or Note field. `armIfNeeded` declining to steal from
            // `NSText` is what makes this safe, and it is load-bearing for these two in
            // a way it never was for the arrows — a swallowed ← is an annoyance, a
            // swallowed ⌫ eats the word you were correcting AND deletes a picture.
            if let intent = deleteIntent(
                characters: characters, modifiers: event.modifierFlags) {
                let handler = intent == .remove ? onRemove : onDestroy
                if let handler { handler(); return }
                // Unbound on this host — fall through rather than swallowing the key.
            }
            // Everything else — Escape included — carries on down the responder chain,
            // so the Back button's `.cancelAction` still closes the page.
            super.keyDown(with: event)
        }
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
        case .rednote: "rednote"
        case .web: "Web"
        case .clipboard: "Clipboard"
        case .localPaste: "Pasted"
        case .localDrag: "Dragged in"
        }
    }
}
