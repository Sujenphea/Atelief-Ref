// AtelierRefsMobile — the companion's one screen and what pushes off it (092 · S5,
// drawn to 093 § 2).
//
// A single `NavigationStack` rooted at the grid. No tab bar, no collections list as
// root, no split view: 093 § 2 subtracts the Mac sidebar down to one survivor — the
// collections tree — and a navigation container built to hold one destination type is a
// picker, not a container. So the grid is the root, the title is its collection's name,
// and tapping the title presents the tree as a sheet. A subcollection and an item both
// push onto this same stack.
//
// This replaces the S4b-i placeholder that printed the App Group path. The one thing
// worth keeping from it is the failure it made visible: a missing App Group container
// is a typed fatal error by design (092 · S1 · decision 3), and 093 § 7 flags that
// nothing rendered it. ``LibraryStore.Phase.failed`` does now.

import AtelierBrowse
import AtelierCore
import AtelierIngestion
import AtelierTokens
import SwiftUI

/// Everything the stack can push. A small enum of IDs rather than the model objects
/// themselves — `CollectionItemDetail` is `Equatable` but not `Hashable`, and a
/// navigation value has to survive a state restore that the model object would not.
enum BrowseRoute: Hashable {
    case collection(UUID)
    /// A membership, named by the collection it belongs to as well as by its own id.
    /// The collection is not decoration: there is no library-wide read for a
    /// membership — `collectionItems(in:)` is the P14 joined read and it is
    /// collection-scoped by design (P16) — so the pair is what makes the item findable
    /// again after a push.
    case item(collection: UUID, item: UUID)
}

struct ContentView: View {
    @State private var store = LibraryStore()
    @State private var path: [BrowseRoute] = []
    @State private var isShowingSwitcher = false
    /// Created after the library root resolves, because the inbox hangs off it — and `nil`
    /// when it never does, which is the same state the failure screen is already showing.
    @State private var export: CaptureExport?
    /// The thing that drains this phone's inbox into this phone's library (096 · 4).
    /// Created beside the export, because the two share the inbox and one of them has to
    /// be able to take it from the other.
    @State private var inbox: InboxDrainScheduler?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: BrowseRoute.self) { route in
                    destination(route)
                }
        }
        // 093 § 6: dark only, stated twice — here and as `UIUserInterfaceStyle` in the
        // Info.plist, exactly as the Mac commits both in SwiftUI and in `NSApp`.
        .preferredColorScheme(.dark)
        .tint(MobileTheme.Colors.inkPrimary)
        .task {
            // The grid is not gated on the drain (096 · 4): `bootstrap()` opens the library
            // and the feed renders what is already in it, and only then is a pass started —
            // behind the screen the user launched for. A backlog of fifty shares costs the
            // first paint nothing.
            await store.bootstrap()
            startInbox()
        }
        // A share arrives while this app is in the background — the extension is another
        // process — so returning to the foreground is both when something may have landed
        // and when the user is looking for it. The scheduler decides whether that becomes a
        // pass; the count is re-read either way, because a pass that ingests nothing new
        // still has to show what the extension added.
        .onChange(of: scenePhase) { _, phase in
            inbox?.scenePhaseChanged(to: phase)
            if phase == .active { export?.refresh() }
        }
        .overlay(alignment: .bottom) { bottomNotice }
        .animation(MobileTheme.Motion.gentle, value: export?.phase)
        .animation(MobileTheme.Motion.gentle, value: export?.pendingFailure)
        .animation(MobileTheme.Motion.gentle, value: store.drainNotice)
        .sheet(isPresented: shareSheetBinding) {
            if case .ready(let url) = export?.phase {
                ShareSheet(url: url) { export?.finish() }
            }
        }
        .sheet(isPresented: $isShowingSwitcher) {
            CollectionSwitcher(
                nodes: store.collections,
                covers: store.collectionCovers,
                selectedID: store.rootCollectionID,
                onSelect: { id in
                    // Switching the ROOT collection, so the stack goes back to it —
                    // leaving a pushed item from the previous collection on top would
                    // be a screen belonging to a library view that is no longer there.
                    path.removeAll()
                    store.rootCollectionID = id
                })
        }
    }

    /// Build the two things that share the inbox, and start the drain (096 · 4).
    ///
    /// Runs after ``LibraryStore/bootstrap()``, so the root is resolved (and seeded, in a
    /// debug fixture run) and the database is open before anything reads the inbox or
    /// writes an asset. Idempotent on the scheduler, which is what a `task` that re-runs
    /// needs it to be; a library that never opened leaves both `nil`, which is the state
    /// the failure screen is already showing.
    ///
    /// **The scheduler is built first and handed to the export**, not the other way round:
    /// the export has to be able to take the inbox from a running pass, and the thing that
    /// owns the passes is the only thing that can give it away. The capture is strong —
    /// both live for the process, and an export whose scheduler had been collected would
    /// silently do nothing at all.
    private func startInbox() {
        guard let root = store.libraryRoot, let services = store.services else { return }
        guard inbox == nil else { return }

        let drain = MobileIngest.makeDrain(libraryRoot: root, services: services)
        // The store, not `self.store`: this closure outlives the body that made it, and a
        // long-lived closure over a `View` value is a subtlety nobody should have to
        // re-derive. The object is what it wants.
        let store = store
        let scheduler = InboxDrainScheduler(
            pass: { await drain.drainOnce() },
            // A pass reports counts, not outcomes, and it resolves each record's OWN target
            // collection — so the screens are told "something landed", not where. One
            // counter is the whole signal: each grid is keyed on it and re-reads itself,
            // and the root's reload is where the send control's count is refreshed too.
            onIngest: { store.noteIngest() },
            // And the one thing a pass can find that the user was told the opposite of
            // (098 · P6). `DrainSummary.userNotice` decides whether there is a sentence at
            // all, and says no for four of the six fields; this is where it lands.
            // Unconditional, `nil` included: the notice describes the LAST pass.
            onNotice: { store.noteDrain(notice: $0) })
        inbox = scheduler

        if export == nil {
            export = CaptureExport(
                libraryRoot: root, appVersion: Self.appVersion,
                exclusion: { body in await scheduler.exclusively(body) })
        }
        export?.refresh()
        scheduler.start()
    }

    /// The Info.plist key carrying the marketing version. Named rather than spelled at
    /// its one use site, following `FixtureLibrary.argument` and
    /// `LibraryLocation.appGroupIdentifierKey`: a plist key inline in an expression is a
    /// string nothing can find, and this one crosses to a Mac inside every manifest.
    static let shortVersionKey = "CFBundleShortVersionString"

    /// What the manifest records as the writing app — the same string the Mac's own
    /// exports carry, read from the bundle rather than spelled here.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: shortVersionKey) as? String ?? "0"
    }

    /// The share sheet is presented for exactly one phase, and dismissing it has to put the
    /// controller back to `.idle` — otherwise the sheet re-presents itself forever.
    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { if case .ready = export?.phase { true } else { false } },
            set: { if !$0 { export?.finish() } })
    }

    // MARK: - What is on top of the grid

    /// The one card the grid can be wearing (098 · P6). Four conditions, one at a time, in
    /// the order of how recently the user caused them.
    ///
    /// **One card and not a stack**, because a stack of warnings at the bottom of a phone
    /// screen is a screen. The export phases come first: they are the answer to a tap that
    /// happened seconds ago, and a person waiting for one must not have it hidden behind a
    /// standing condition. The inbox failure comes next because it is the reason the send
    /// control is not there. The drain's notice is last because it is the only one about
    /// something that happened behind the screen.
    @ViewBuilder
    private var bottomNotice: some View {
        if case .failed(let message) = export?.phase {
            WarningNotice(message: message, identifier: NoticeID.exportFailure)
                .transition(.opacity)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    export?.finish()
                }
        } else if case .sent(let count, let skipped) = export?.phase {
            // **No auto-dismiss timer here, unlike the failure notice above.** That one
            // reports something already true and needs no answer; this one asks a
            // question only the user can answer, and a question that vanishes after four
            // seconds is a question that gets answered by accident. It waits.
            ExportSentNotice(
                count: count, skipped: skipped,
                onClear: { Task { await export?.retire() } },
                onKeep: { export?.keep() })
                .transition(.opacity)
        } else if let failure = export?.pendingFailure {
            // **This one does not dismiss, and that is the design** (098 · P6). The other
            // three report an event; this reports a STATE — the inbox cannot be
            // enumerated, so the send control is not in the toolbar and there is no other
            // sign anything is wrong. A card that timed out would leave a phone that
            // silently cannot send its captures looking exactly like a phone with nothing
            // to send, which is the condition this whole change exists to remove. It goes
            // when the state does: `refresh()` runs on every activation and clears the
            // failure the moment the directory reads again.
            WarningNotice(message: failure, identifier: NoticeID.inboxUnreadable)
                .transition(.opacity)
        } else if let notice = store.drainNotice {
            // Six seconds rather than the export failure's four: nothing on this screen
            // prompted it, so the user has to notice it before they can read it.
            WarningNotice(message: notice, identifier: NoticeID.drain)
                .transition(.opacity)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    store.dismissDrainNotice()
                }
        }
    }

    // MARK: - Root

    private var root: some View {
        Group {
            switch store.phase {
            case .loading:
                LoadingNotice()
            case .failed(let message):
                FailureNotice(message: message)
            case .ready:
                CollectionScreen(
                    store: store,
                    collectionID: store.rootCollectionID,
                    isRoot: true,
                    onSwitchCollection: { isShowingSwitcher = true },
                    export: export)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **The app's ground, painted opaque** (093 § 4). Both other screens paint
        // `panel` for themselves; the loading and failure states painted nothing, so a
        // library that would not open drew an orange sentence on the navigation
        // controller's own `#000000` — a colour this app does not have.
        //
        // `canvasOuter` and not `panel`, and INSIDE the stack rather than on it: it is the
        // launch screen's colour (`Info.plist` · `UILaunchScreen`), so the first frame the
        // app draws is the tone the launch image already was, and only content brings
        // `panel` with it. On the `NavigationStack` it would be painted over — the
        // navigation controller's view is opaque, which is the whole reason the black was
        // showing in the first place.
        .background(MobileTheme.Colors.canvasOuter)
    }

    @ViewBuilder
    private func destination(_ route: BrowseRoute) -> some View {
        switch route {
        case .collection(let id):
            CollectionScreen(
                store: store, collectionID: id, isRoot: false, onSwitchCollection: nil,
                export: nil)
        case .item(let collectionID, let itemID):
            ItemScreen(store: store, collectionID: collectionID, itemID: itemID)
        }
    }
}

// MARK: - One collection's grid

/// A collection, as a grid. Used for the root and for every pushed subcollection, each
/// with its OWN ``CollectionFeed`` — see the note in `LibraryStore.swift` on why they
/// cannot share one.
struct CollectionScreen: View {
    let store: LibraryStore
    let collectionID: UUID
    let isRoot: Bool
    /// Present only on the root: the title is the switcher (093 § 2), and a pushed
    /// screen's title is where it came from, which is not a control.
    let onSwitchCollection: (() -> Void)?
    /// Also root-only: a subcollection is a place you are reading, not a place you send
    /// from. `nil` on every pushed screen, and on the root until the library root resolves.
    let export: CaptureExport?

    @State private var feed = CollectionFeed()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The panel's TONE crosses; its inset and corner arc do not — those exist
            // because the Mac's panel sits in a window beside a sidebar (093 § 4). The
            // phone paints it full-bleed.
            .background(MobileTheme.Colors.panel)
            .navigationTitle(feed.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onSwitchCollection {
                    ToolbarItem(placement: .principal) {
                        TitleSwitcherButton(
                            name: feed.name,
                            isEnabled: !store.collections.isEmpty,
                            action: onSwitchCollection)
                    }
                }
                // Only when there is something to send: an empty inbox shows the grid and
                // nothing else, which is 093 § 2's resting state.
                if let export, let pending = export.pending, pending > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        ExportButton(count: pending, phase: export.phase) {
                            Task { await export.export() }
                        }
                    }
                }
            }
            .toolbarBackground(MobileTheme.Colors.canvasOuter, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Keyed on the id so switching the root collection reloads in place, and on the
            // ingest counter so a capture the drain lands while this screen is up appears in
            // it (096 · 4). Every screen on the stack re-reads, not just the visible one:
            // the pass resolves each record's own target collection and reports only counts,
            // so "which grid changed" is not knowable here. That is a wasted query on the
            // screens the drain missed and the honest response to not knowing — the
            // alternative is a grid that silently omits a capture the user watched arrive,
            // which is the same trade `IngestionModel.refreshAfterIngest(touching:)` takes.
            .task(id: FeedReload(collection: collectionID, ingest: store.ingestGeneration)) {
                await feed.load(collectionID, from: store)
                if isRoot {
                    await store.refreshCollections()
                    // The union the send control counts changes when a pass quarantines or
                    // an extension writes, and this is the one reload every such moment
                    // already runs through.
                    export?.refresh()
                }
            }
    }

    /// What a reload is keyed on: the collection being shown, and how many times the drain
    /// has changed the library under it.
    private struct FeedReload: Hashable {
        let collection: UUID
        let ingest: Int
    }

    @ViewBuilder
    private var content: some View {
        if let error = feed.error {
            FailureNotice(message: error)
        } else if !feed.hasLoaded {
            LoadingNotice()
        } else {
            VStack(spacing: 0) {
                // Above the emptiness test, not inside it: a collection holding only
                // subfolders has chips AND nothing to draw under them, and that pair is
                // the case the old condition could not express (098 · P6).
                if !feed.subcollections.isEmpty {
                    SubcollectionBar(collections: feed.subcollections)
                }
                if let empty = emptyState {
                    EmptyNotice(state: empty)
                } else {
                    MasonryGridView(
                        items: feed.items,
                        collectionID: collectionID,
                        thumbnailURL: { store.gridThumbnailURL(for: $0) })
                }
            }
        }
    }

    /// Which kind of nothing this grid is showing, or `nil` when it is showing something.
    ///
    /// **`isUnsorted` and not `isRoot`.** The root screen's collection is whatever the
    /// switcher last chose, so `isRoot` answers a question about the navigation stack; the
    /// sentence "anything you share arrives here" is true of Unsorted and of no other
    /// collection (092 · S3). The two used to be the same thing and stopped being one the
    /// moment the switcher landed.
    private var emptyState: BrowseEmptyState? {
        BrowseEmptyState.resolve(
            isUnsorted: collectionID == BrowseLibrary.rootCollectionID,
            itemCount: feed.items.count,
            subcollectionCount: feed.subcollections.count,
            libraryCollectionCount: store.collectionCount)
    }
}

// MARK: - One item

/// An item, resolved from its ids against the library rather than carried through the
/// navigation value — so a push survives the feed it came from being reloaded, and so
/// the route stays a pair of `UUID`s rather than a model object.
struct ItemScreen: View {
    let store: LibraryStore
    let collectionID: UUID
    let itemID: UUID

    @State private var detail: CollectionItemDetail?
    /// Every collection the asset is in (098 · P6). A SECOND read, keyed on the asset id,
    /// which only exists once the first has answered — so it cannot be concurrent with it
    /// and deliberately does not try to be.
    @State private var collections: [Collection] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let detail {
                ItemDetailScreen(
                    detail: detail, imageURL: store.detailImageURL(for: detail.asset),
                    collections: collections)
            } else if let error {
                FailureNotice(message: error)
            } else {
                LoadingNotice()
            }
        }
        .background(MobileTheme.Colors.panel)
        .task(id: itemID) {
            do {
                // ONE row, by the pair of ids the route carries. This used to be
                // `store.items(in:).first { }` — the whole P14 join, 0.293 s at 5,000
                // rows (450), paid per tap to keep one of them (098 · finding 13).
                let found = try await store.item(itemID, in: collectionID)
                detail = found
                guard let found else {
                    error = "That item is no longer in the library."
                    return
                }
                // After the assignment above, so the picture is on screen while this runs.
                // A row that appears a frame late is better than a picture that arrives a
                // read late, which is the same trade the whole of finding 13 was about.
                //
                // `try?`: the memberships are ONE row of a screen whose other eight facts
                // have already rendered. A read that fails here draws no Collections row,
                // exactly as an item in no collection would — it must not be able to
                // replace the item with an error screen.
                collections = (try? await store.memberships(of: found.asset.id)) ?? []
            } catch {
                self.error = BrowseFailure.message(for: error)
            }
        }
    }
}

// MARK: - Chrome

/// The title IS the switcher (093 § 2). A chevron so it reads as a control rather than
/// as a label that happens to be tappable.
private struct TitleSwitcherButton: View {
    let name: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.xs) {
                Text(name)
                    .font(MobileTheme.Typography.bodyEmphasis)
                    .foregroundStyle(MobileTheme.Colors.inkPrimary)
                Image(systemName: "chevron.down")
                    .font(MobileTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(MobileTheme.Colors.inkSecondary)
            }
            // 093 § 5: the label keeps its token size and the hit area is stated
            // separately at Apple's minimum.
            .frame(minHeight: MobileTheme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : MobileTheme.disabledOpacity)
        .accessibilityLabel("Switch collection")
    }
}

/// The current collection's immediate subfolders, as a row of chips above the grid —
/// decision F5's "direct items plus immediate subfolders", with the folders kept out of
/// the grid because the grid is pictures.
private struct SubcollectionBar: View {
    let collections: [Collection]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                ForEach(collections) { collection in
                    NavigationLink(value: BrowseRoute.collection(collection.id)) {
                        Text(collection.name)
                            .font(MobileTheme.Typography.label)
                            .foregroundStyle(MobileTheme.Colors.inkPrimary)
                            .padding(.horizontal, MobileTheme.Spacing.md)
                            .frame(minHeight: MobileTheme.touchTarget)
                            .fieldChrome(cornerRadius: MobileTheme.Radius.chip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.sm)
        }
        .scrollIndicators(.hidden)
    }
}

