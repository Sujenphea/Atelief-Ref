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
    /// Post key → its member item ids in FEED order.
    private let membersByKey: [String: [UUID]]

    /// The empty index — no grouping (used before the first load).
    init() {
        keyByItem = [:]
        membersByKey = [:]
    }

    /// Bucket `items` by post, dropping every group of one.
    init(items: [CollectionItemDetail]) {
        var members: [String: [UUID]] = [:]
        for detail in items {
            guard let key = postGroupKey(for: detail.source) else { continue }
            members[key, default: []].append(detail.item.id)
        }
        members = members.filter { $0.value.count > 1 }
        var byItem: [UUID: String] = [:]
        byItem.reserveCapacity(members.values.reduce(0) { $0 + $1.count })
        for (key, ids) in members {
            for id in ids { byItem[id] = key }
        }
        keyByItem = byItem
        membersByKey = members
    }

    /// How many items of this feed came from `id`'s post — `0` when the item isn't
    /// part of a multi-item post (so the cell draws no badge). Never `1`.
    func memberCount(forItem id: UUID) -> Int {
        guard let key = keyByItem[id] else { return 0 }
        return membersByKey[key]?.count ?? 0
    }

    /// Every item from `id`'s post, in feed order (empty when ungrouped).
    func members(forItem id: UUID) -> [UUID] {
        guard let key = keyByItem[id], let ids = membersByKey[key] else { return [] }
        return ids
    }

    /// Whether `id` is the member that STANDS FOR its post in a collapsed feed —
    /// the first in feed order. Ungrouped items are always their own representative.
    func isRepresentative(_ id: UUID) -> Bool {
        guard let key = keyByItem[id] else { return true }
        return membersByKey[key]?.first == id
    }

    /// The display list for a collapsed grid: one tile per post, standing at its
    /// FIRST member's position, with every ungrouped item kept exactly as it is.
    ///
    /// This is what makes collapsing cheap. It returns a SHORTER `[CollectionItemDetail]`
    /// — not a cell holding several ids — so the grid keeps its one-item-one-cell-one-
    /// selectable-id invariant and every index-based subsystem (the layout's `aspects`,
    /// `nextGridIndex`, the marquee, reorder) is untouched.
    func collapsed(_ items: [CollectionItemDetail]) -> [CollectionItemDetail] {
        guard !keyByItem.isEmpty else { return items }
        return items.filter { isRepresentative($0.item.id) }
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
