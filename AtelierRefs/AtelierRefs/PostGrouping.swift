//
//  PostGrouping.swift
//  AtelierRefs
//
//  "Which of these came from the same post?" — the grouping behind the grid's
//  carousel badge, the sibling ring, and the "Select all from this post" action.
//
//  There is no `post` row to key on, and there deliberately isn't going to be:
//  the ingest funnel writes ONE `Source` per asset (`AppServices.ingest` inserts
//  a fresh `Source` on every non-dedup capture), so a four-image Instagram
//  carousel lands as four assets with four DISTINCT `source_id`s. What those four
//  rows DO share is the post permalink — the extension's saved-feed parser hands
//  every carousel child the post's own `originalURL` (`bulk-instagram.js`:
//  "Carousel children share the POST's permalink"), and the same holds for a
//  multi-image tweet or a Pinterest pin. So the grouping key is the source URL,
//  not the source id — grouping on `sourceId` would put every image in its own
//  group and silently do nothing.
//
//  Everything here is pure and view-free so the key normalization and the
//  sibling math are unit-tested without a grid.
//

import AtelierCore
import Foundation

// MARK: - The key

/// The "same post" key for a source, or `nil` when the source can't be grouped.
///
/// THREE producers feed this and they do not agree, so the normalization has to
/// reconcile them or one post silently becomes two groups:
///
///  • `extractors/base.js` (`cleanURL` = `origin + pathname`) — the live-page path.
///  • `bulk-instagram.js` — synthesises `https://<host>/<p|reel>/<code>/`, and its
///    own comment notes a reel resolves under BOTH `/reel/` and `/p/`.
///  • `AddLinkForm` → `LinkPayload.canonicalURL` — a hand-pasted share link, which
///    is where `?igsh=…` tracking params actually arrive.
///
/// So: drop the query and `#fragment`, lowercase the SCHEME and HOST only, drop a
/// leading `www.` / `m.`, canonicalise `/reel/<code>` to `/p/<code>`, and trim
/// trailing slashes.
///
/// The path keeps its case deliberately — an IG shortcode is case-sensitive
/// (`/p/AbCd` and `/p/abcd` are different posts), so lowercasing the whole URL
/// would fuse unrelated items. Over-normalizing is the dangerous direction here:
/// under-normalizing splits one carousel (visible, harmless), while
/// over-normalizing merges strangers into one post (invisible, and "select the
/// rest of this post" would then reach someone else's images).
///
/// `nil` for a source with no `originalURL` — a pasted image, a dragged file, an
/// imported folder. Those must NOT collapse into one giant "group of everything
/// local", which is exactly what keying on the empty string would do.
func postGroupKey(for source: Source) -> String? {
    guard let raw = source.originalURL?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return nil }

    // Strip the fragment and query by hand rather than via `URLComponents`, so an
    // unparseable string still gets the same treatment instead of falling through
    // raw (a malformed URL is a legitimate key — it just can't be host-normalized).
    var key = raw
    if let hash = key.firstIndex(of: "#") { key = String(key[key.startIndex..<hash]) }
    if let query = key.firstIndex(of: "?") { key = String(key[key.startIndex..<query]) }

    if var parts = URLComponents(string: key), let host = parts.host {
        parts.scheme = parts.scheme?.lowercased()
        var lowered = host.lowercased()
        for prefix in ["www.", "m."] where lowered.hasPrefix(prefix) {
            lowered.removeFirst(prefix.count)
            break
        }
        parts.host = lowered
        // Both paths resolve to the same post (`bulk-instagram.js`), and bulk
        // capture picks `/reel/` for clips while a live page may sit on `/p/`.
        if parts.path.hasPrefix("/reel/") {
            parts.path = "/p/" + parts.path.dropFirst("/reel/".count)
        }
        key = parts.string ?? key
    }

    while key.hasSuffix("/") { key.removeLast() }
    return key.isEmpty ? nil : key
}

/// The item's position within its original carousel, or `nil` when the capture
/// didn't record one.
///
/// `bulk-instagram.js` stamps `rawMetadata.carouselIndex` on every child as it
/// walks `carousel_media[]`, and `raw_metadata` round-trips losslessly through
/// persistence — so the post's OWN sequence survives ingest even though nothing
/// read it until 309. It is the only producer that writes one, which is less of a
/// gap than it sounds: `bulk-twitter` and `bulk-pinterest` emit ONE item per
/// tweet/pin (a multi-image tweet becomes a single card asset carrying its media
/// in the payload), and the live-page extractors capture one image per capture.
/// A multi-asset post group is therefore a bulk-Instagram carousel in all but the
/// odd hand-captured case.
///
/// Tolerant of a quoted number: `raw_metadata` is a JSON escape hatch written by
/// JavaScript, and a producer that serialises `"0"` should not silently drop a
/// post out of ordered-ness.
func carouselIndex(for source: Source) -> Int? {
    guard case let .object(fields) = source.rawMetadata,
          let raw = fields["carouselIndex"] else { return nil }
    switch raw {
    case let .number(value): return Int(exactly: value.rounded())
    case let .string(value): return Int(value)
    default: return nil
    }
}

// MARK: - The index

/// The feed's items bucketed by post, keyed by MEMBERSHIP id (`CollectionItem.id`)
/// — the same identity the selection reducer and the grid cells use, so no id
/// mapping is needed at any call site. (Search synthesizes `item.id == asset.id`,
/// so this works there unchanged.)
///
/// Scope is the LOADED FEED, not the library — a deliberate contract, not an
/// accident of where this happens to be built. A carousel half-filed into another
/// collection collapses to ONE tile reporting the two members actually on screen,
/// and an action on that tile touches exactly those two. Everything the grid shows,
/// counts, and acts on therefore agrees, and none of it costs a query: this is a
/// pass over `CollectionItemDetail`s the feed had already loaded.
///
/// The alternative — a library-wide count — would need a per-post lookup (an N+1 in
/// waiting) and would promise a number the tile cannot act on. If that becomes
/// desirable, it belongs in ONE aggregate query, not here.
struct PostGroups {
    /// Item id → its post key. Only items in a group of 2+ appear — a lone item
    /// from a post is not "grouped", and leaving it out keeps every lookup a
    /// membership test rather than a count check.
    private let keyByItem: [UUID: String]
    /// Post key → its member item ids, in the post's OWN order where the capture
    /// recorded one (see the `init`), otherwise feed order.
    private let membersByKey: [String: [UUID]]
    /// Blob hash by MEMBER id, for grouped items only — what the detail page's fan
    /// needs to draw a post's other images (080 §2.1: the hash is the thumbnail
    /// cache's key, so a URL alone would re-decode every card).
    ///
    /// Recorded HERE rather than resolved at the call site because the `init` is
    /// already the one pass over the feed that has the details in hand. The
    /// alternative — handing ``detailPost(forItem:thumbnailURL:jump:)`` the whole
    /// `[CollectionItemDetail]` — would put an O(feed) index build inside a view
    /// body, which is exactly the cost 080 §4 exists to remove. Absent for a
    /// media-less member (003 · O1), which the factory carries through as a `nil`
    /// slot rather than compacting away — see ``ItemDetailPost/blobHashes``.
    private let blobHashByItem: [UUID: String]

    /// The empty index — no grouping (used before the first load).
    init() {
        keyByItem = [:]
        membersByKey = [:]
        blobHashByItem = [:]
    }

    /// Bucket `items` by post, dropping every group of one, and put each group in
    /// the POST's own order where the capture recorded one (309).
    ///
    /// Feed order is not the carousel's order: a manual reorder, a partial move or
    /// a re-file shuffles the images, and opening the post then reads 3-1-4-2.
    /// ``carouselIndex(for:)`` recovers the real sequence.
    ///
    /// ALL-OR-NOTHING: a group is only sorted when every member carries an index.
    /// A half-indexed post (a bulk-captured carousel plus one image of the same
    /// post grabbed live) would otherwise interleave two provenance stories into
    /// one sequence with no way to tell which half is trustworthy; leaving it in
    /// feed order is at least an order the user can see and change.
    ///
    /// The sort is keyed on `(index, feed position)` rather than the index alone —
    /// `sorted(by:)` is not guaranteed stable, and two members sharing an index
    /// (a duplicate capture) must not be free to swap between derivations, or the
    /// representative — and with it the tile's identity and slot — would flicker.
    init(items: [CollectionItemDetail]) {
        var members: [String: [UUID]] = [:]
        var carouselIndexByItem: [UUID: Int] = [:]
        var feedPositionByItem: [UUID: Int] = [:]
        var hashByItem: [UUID: String] = [:]
        for (position, detail) in items.enumerated() {
            guard let key = postGroupKey(for: detail.source) else { continue }
            let id = detail.item.id
            members[key, default: []].append(id)
            feedPositionByItem[id] = position
            if let index = carouselIndex(for: detail.source) { carouselIndexByItem[id] = index }
            if let hash = detail.asset.blobHash { hashByItem[id] = hash }
        }
        members = members.filter { $0.value.count > 1 }
        for (key, ids) in members where ids.allSatisfy({ carouselIndexByItem[$0] != nil }) {
            members[key] = ids.sorted {
                (carouselIndexByItem[$0] ?? 0, feedPositionByItem[$0] ?? 0)
                    < (carouselIndexByItem[$1] ?? 0, feedPositionByItem[$1] ?? 0)
            }
        }
        var byItem: [UUID: String] = [:]
        byItem.reserveCapacity(members.values.reduce(0) { $0 + $1.count })
        for (key, ids) in members {
            for id in ids { byItem[id] = key }
        }
        keyByItem = byItem
        membersByKey = members
        // Only GROUPED items can ever be asked for a hash, and the ungrouped ones are
        // the overwhelming majority — pruning here keeps the map the size of the
        // carousels in the feed rather than the size of the feed.
        blobHashByItem = hashByItem.filter { byItem[$0.key] != nil }
    }

    /// How many items of this feed came from `id`'s post — `0` when the item isn't
    /// part of a multi-item post (so the cell draws no badge). Never `1`.
    func memberCount(forItem id: UUID) -> Int {
        guard let key = keyByItem[id] else { return 0 }
        return membersByKey[key]?.count ?? 0
    }

    /// Every item from `id`'s post, in post order (empty when ungrouped).
    func members(forItem id: UUID) -> [UUID] {
        guard let key = keyByItem[id], let ids = membersByKey[key] else { return [] }
        return ids
    }

    /// The detail page's view of `id`'s post (080 §3.1) — `nil` when `id` is
    /// ungrouped, which is the page's "draw nothing" answer.
    ///
    /// ONE factory rather than a derivation per host. Both grid-backed hosts want the
    /// same four facts and reach post data by different routes, so writing it twice
    /// is the "two lists, one of them unseen" shape 316 was written to fix. It lives
    /// HERE, on the type that already owns post semantics and carries this area's
    /// heaviest test suite, so the one thing that can silently rot — that ``index``
    /// agrees with the position ← / → actually walks in ``fullRun(_:)`` — is pinned
    /// by a unit test rather than by eye on the page.
    ///
    /// The caller supplies only the two things ``PostGroups`` cannot know: how to turn
    /// a blob hash into a thumbnail URL, and what a jump means on its surface.
    func detailPost(
        forItem id: UUID,
        thumbnailURL: @escaping (String) -> URL?,
        jump: @escaping (Int) -> Void
    ) -> ItemDetailPost? {
        let ids = members(forItem: id)
        // `index` before `count`: an id that is somehow keyed but missing from its own
        // member list must yield nothing rather than a chip reading "1 of N".
        guard let index = ids.firstIndex(of: id), let seed = ids.first else { return nil }
        return ItemDetailPost(
            index: index,
            memberCount: ids.count,
            // `map`, NOT `compactMap`: one slot per member, in post order, so
            // `blobHashes[i]` is member `i`. A media-less member (003 · O1) has no blob
            // and lands as `nil` — a placeholder card, not a missing one. Compacting
            // here would silently renumber every card after such a member, and `jump`
            // takes a POST-RELATIVE index, so the spread would send you to the wrong
            // image. 080 §7 still defers what a mixed-kind post should DRAW; this only
            // fixes where each member SITS.
            blobHashes: ids.map { blobHashByItem[$0] },
            thumbnailURL: thumbnailURL,
            seed: seed,
            jump: jump)
    }

    /// Whether `id` is the member that STANDS FOR its post in a collapsed feed —
    /// the first in POST order, which for an indexed carousel is image #1 (309), so
    /// the collapsed tile shows the post's own cover rather than whichever image
    /// happens to sit earliest in the feed. Ungrouped items are always their own
    /// representative.
    func isRepresentative(_ id: UUID) -> Bool {
        guard let key = keyByItem[id] else { return true }
        return membersByKey[key]?.first == id
    }

    /// The display list for a collapsed grid: one tile per post, standing at the
    /// feed position of its representative — the post's cover (309) — with every
    /// ungrouped item kept exactly as it is. For a freshly-captured feed that is
    /// the same slot it always was, since feed order and carousel order agree
    /// until something reorders them.
    ///
    /// This is what makes collapsing cheap. It returns a SHORTER `[CollectionItemDetail]`
    /// — not a cell holding several ids — so the grid keeps its one-item-one-cell-one-
    /// selectable-id invariant and every index-based subsystem (the layout's `aspects`,
    /// `nextGridIndex`, the marquee, reorder) is untouched.
    /// `expanding` holds the REPRESENTATIVE ids of posts the user has opened in
    /// place: those posts contribute all their members instead of one tile, so a
    /// carousel can be looked through without leaving the grid. Representative ids
    /// rather than post keys, because that is the identity a click on a tile
    /// already has.
    ///
    /// An opened post's members are emitted CONTIGUOUSLY at the representative's
    /// slot, in feed order — not each at its own feed position. Nothing keeps a
    /// carousel's images adjacent in `items`: a manual reorder, a partial move, or
    /// a re-file interleaves them with everything else, so position-faithful
    /// splicing scattered the images across the grid and opening a post read as
    /// "N unrelated tiles appeared somewhere". The point of opening is to look
    /// through ONE post, so the tiles that appear are the ones that were behind the
    /// chip, together, where the chip was.
    ///
    /// This is the one place the display list stops being a subsequence of `items`.
    /// Everything downstream is index-based over the DISPLAY list — the layout's
    /// `aspects`, the selection store's `order`, the marquee, the reorder solve —
    /// so display order is the order they all mean; nothing resolves a tile through
    /// its index in `items`.
    func collapsed(
        _ items: [CollectionItemDetail], expanding: Set<UUID> = []
    ) -> [CollectionItemDetail] {
        guard !keyByItem.isEmpty else { return items }
        // Only an OPEN post needs its members looked up by id, and the common case
        // is none open — so the index is built lazily rather than on every derivation.
        let detailByID: [UUID: CollectionItemDetail] = expanding.isEmpty
            ? [:]
            : Dictionary(items.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [CollectionItemDetail] = []
        result.reserveCapacity(items.count)
        for detail in items {
            let id = detail.item.id
            guard let key = keyByItem[id], let members = membersByKey[key] else {
                result.append(detail)  // ungrouped — kept exactly where it is
                continue
            }
            // A non-representative member is never emitted in place: it either stays
            // hidden behind the tile, or it was already emitted beside its lead below.
            guard members.first == id else { continue }
            result.append(detail)
            guard expanding.contains(id) else { continue }
            for memberID in members.dropFirst() {
                if let member = detailByID[memberID] { result.append(member) }
            }
        }
        return result
    }

    /// The run the DETAIL page steps through: every item, but with each post's members
    /// gathered contiguously at the representative's slot, in POST order.
    ///
    /// The page's prev/next used to walk `items` raw (309 fixed the grid's order and
    /// left the overlay behind), so → out of a carousel's cover wandered into whichever
    /// siblings happened to sit later in the feed, in feed order, and came back to the
    /// rest of the post further along. This is the grid's own display list with every
    /// post opened — the same rule, one code path, so what the page walks and what the
    /// grid draws can no longer disagree.
    ///
    /// Deliberately NOT a subsequence of `items`, for the reason ``collapsed(_:expanding:)``
    /// gives: the point of opening a post is to look through ONE post, so its images are
    /// adjacent, where its tile was.
    func fullRun(_ items: [CollectionItemDetail]) -> [CollectionItemDetail] {
        collapsed(items, expanding: Set(membersByKey.values.compactMap(\.first)))
    }

    /// Every member of the posts `selected` touches — the ACTION boundary.
    ///
    /// A collapsed tile is one thing to click and N things to act on: the selection
    /// holds only representatives (so the grid's index math stays 1:1), and an action
    /// widens to the real members right before it runs. An ungrouped id widens to
    /// itself, so callers can route EVERY action through this without special-casing.
    func expand(_ selected: Set<UUID>) -> Set<UUID> {
        guard !keyByItem.isEmpty else { return selected }
        var result = Set<UUID>()
        result.reserveCapacity(selected.count)
        for id in selected {
            if let key = keyByItem[id], let members = membersByKey[key] {
                result.formUnion(members)
            } else {
                result.insert(id)
            }
        }
        return result
    }
}
