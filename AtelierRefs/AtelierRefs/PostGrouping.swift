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
/// The permalink, lightly normalized: trailing slashes and a `#fragment` are
/// noise (Instagram appends `/`, a shared link may carry an anchor), so two
/// captures of one post agree. Case is preserved deliberately — an IG shortcode
/// is case-sensitive (`/p/AbCd/` and `/p/abcd/` are different posts), so
/// lowercasing would merge unrelated items.
///
/// `nil` for a source with no `originalURL` — a pasted image, a dragged file, an
/// imported folder. Those must NOT collapse into one giant "group of everything
/// local", which is exactly what keying on the empty string would do.
func postGroupKey(for source: Source) -> String? {
    guard let raw = source.originalURL?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return nil }
    var key = raw
    if let hash = key.firstIndex(of: "#") { key = String(key[key.startIndex..<hash]) }
    while key.hasSuffix("/") { key.removeLast() }
    return key.isEmpty ? nil : key
}

// MARK: - The index

/// The feed's items bucketed by post, keyed by MEMBERSHIP id (`CollectionItem.id`)
/// — the same identity the selection reducer and the grid cells use, so no id
/// mapping is needed at any call site. (Search synthesizes `item.id == asset.id`,
/// so this works there unchanged.)
///
/// Scope is the LOADED FEED, not the library: a carousel half-filed into another
/// collection reports the two members that are actually on screen, because that is
/// what the badge count promises and what "select the others" can actually select.
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

    /// How many DISTINCT multi-item posts the selection touches — the singular /
    /// plural switch in ``selectSamePostTitle(siblingCount:postCount:)``.
    func groupCount(ofSelected selected: Set<UUID>) -> Int {
        var keys = Set<String>()
        for id in selected { if let key = keyByItem[id] { keys.insert(key) } }
        return keys.count
    }

    /// The UNSELECTED items sharing a post with something in `selected` — what the
    /// sibling ring draws and what "Select all from this post" would add. Empty
    /// when the selection has no grouped item, or when every sibling is already in.
    func siblings(ofSelected selected: Set<UUID>) -> Set<UUID> {
        guard !keyByItem.isEmpty, !selected.isEmpty else { return [] }
        var keys = Set<String>()
        for id in selected { if let key = keyByItem[id] { keys.insert(key) } }
        guard !keys.isEmpty else { return [] }
        var result = Set<UUID>()
        for key in keys {
            for id in membersByKey[key] ?? [] where !selected.contains(id) {
                result.insert(id)
            }
        }
        return result
    }
}

// MARK: - Action wording

/// The "select the rest of this post" row / button title for a selection whose
/// unselected siblings number `siblingCount`, spanning `postCount` distinct posts.
/// `nil` when there is nothing to add, which is the signal to hide the affordance
/// rather than offer a no-op.
func selectSamePostTitle(siblingCount: Int, postCount: Int) -> String? {
    guard siblingCount > 0 else { return nil }
    // Title Case, matching the app's other menu verbs ("Set as Cover", "Remove
    // from Collection") — this row sits among them in the same popover / NSMenu.
    let noun = postCount > 1 ? "These Posts" : "This Post"
    return "Select \(siblingCount) More from \(noun)"
}
