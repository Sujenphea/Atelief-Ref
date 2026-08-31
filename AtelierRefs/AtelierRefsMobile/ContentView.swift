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
        .overlay(alignment: .bottom) {
            if case .failed(let message) = export?.phase {
                ExportFailureNotice(message: message)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        export?.finish()
                    }
            } else if case .sent(let count) = export?.phase {
                // **No auto-dismiss timer here, unlike the failure notice above.** That one
                // reports something already true and needs no answer; this one asks a
                // question only the user can answer, and a question that vanishes after four
                // seconds is a question that gets answered by accident. It waits.
                ExportSentNotice(
                    count: count,
                    onClear: { Task { await export?.retire() } },
                    onKeep: { export?.keep() })
                    .transition(.opacity)
            }
        }
        .animation(MobileTheme.Motion.gentle, value: export?.phase)
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
            onIngest: { store.noteIngest() })
        inbox = scheduler

        if export == nil {
            export = CaptureExport(
                libraryRoot: root, appVersion: Self.appVersion,
                exclusion: { body in await scheduler.exclusively(body) })
        }
        export?.refresh()
        scheduler.start()
    }

    /// What the manifest records as the writing app — the same string the Mac's own
    /// exports carry, read from the bundle rather than spelled here.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The share sheet is presented for exactly one phase, and dismissing it has to put the
    /// controller back to `.idle` — otherwise the sheet re-presents itself forever.
    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { if case .ready = export?.phase { true } else { false } },
            set: { if !$0 { export?.finish() } })
    }

    // MARK: - Root

    @ViewBuilder
    private var root: some View {
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
        } else if feed.items.isEmpty && feed.subcollections.isEmpty {
            EmptyNotice()
        } else {
            VStack(spacing: 0) {
                if !feed.subcollections.isEmpty {
                    SubcollectionBar(collections: feed.subcollections)
                }
                MasonryGridView(
                    items: feed.items,
                    collectionID: collectionID,
                    thumbnailURL: { store.gridThumbnailURL(for: $0) })
            }
        }
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
    @State private var error: String?

    var body: some View {
        Group {
            if let detail {
                ItemDetailScreen(
                    detail: detail, imageURL: store.detailImageURL(for: detail.asset))
            } else if let error {
                FailureNotice(message: error)
            } else {
                LoadingNotice()
            }
        }
        .background(MobileTheme.Colors.panel)
        .task(id: itemID) {
            do {
                detail = try await store.items(in: collectionID)
                    .first { $0.item.id == itemID }
                if detail == nil { error = "That item is no longer in the library." }
            } catch {
                self.error = LibraryStore.message(for: error)
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
                            .background(
                                RoundedRectangle(
                                    cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                                    .fill(MobileTheme.Colors.field))
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                                    .strokeBorder(MobileTheme.Colors.hairline, lineWidth: 1))
                            .contentShape(
                                RoundedRectangle(cornerRadius: MobileTheme.Radius.chip))
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

private struct LoadingNotice: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(MobileTheme.Colors.inkSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A collection with nothing in it.
///
/// Worth one sentence rather than a blank screen. The sentence used to carry a fact the
/// Mac's equivalent never had to — that a capture made on the phone stayed invisible here
/// until a Mac had ingested it and synced it back — and 096 · 4 made that false: the phone
/// drains its own inbox now, so a share appears in this grid on its own. What is left to
/// say is the ordinary thing, which is that shares land in Unsorted.
private struct EmptyNotice: View {
    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Text("Nothing here yet")
                .font(MobileTheme.Typography.bodyEmphasis)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
            Text("Anything you share arrives in Unsorted.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The library could not be opened or read. `warning` is the app's single alarm colour
/// and its one deliberate exception to monochrome (`Tokens.Colors.warning`).
private struct FailureNotice: View {
    let message: String

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(MobileTheme.Colors.warning)
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.warning)
                .multilineTextAlignment(.center)
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
