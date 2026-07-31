//
//  PostGroupingTests.swift
//  AtelierRefsTests
//
//  307 · carousel grouping — the pure grouping behind the grid's carousel badge,
//  the collapsed one-tile-per-post display list, and the action-boundary widening
//  that makes delete / move / drag act on a whole post.
//
//  The load-bearing fact these pin is the one that is easy to get wrong: a
//  carousel's images do NOT share a `source_id` (the ingest funnel writes one
//  `Source` row per asset), they share the post's `original_url`. A regression
//  that "fixes" the grouping onto `sourceId` would leave every image in a group
//  of one and make the whole feature silently inert — `carouselSharesURLNotSourceID`
//  is the test that catches exactly that.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// One feed item from a post at `url` (nil = an ungroupable local capture). Each
/// gets its OWN `Source` row, exactly as the ingest funnel writes them.
private func item(url: String?, platform: Platform = .instagram) -> CollectionItemDetail {
    let sourceID = UUID(), assetID = UUID()
    let source = Source(
        id: sourceID, platform: platform, originalURL: url, capturedAt: Date())
    let asset = Asset(
        id: assetID, kind: .image, blobHash: UUID().uuidString, mimeType: "image/jpeg",
        width: 100, height: 100, fileSize: 100, downloadState: .downloaded,
        createdAt: Date(), sourceId: sourceID)
    return CollectionItemDetail(
        item: CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
        asset: asset, source: source)
}

private func source(_ url: String?) -> Source {
    Source(id: UUID(), platform: .instagram, originalURL: url, capturedAt: Date())
}

// MARK: - The key

@Suite("Post grouping: the key")
struct PostGroupKeyTests {

    @Test("a permalink is the key, in its normalized form")
    func permalinkIsTheKey() {
        // `www.` is dropped so the bulk mapper's host and a live page's host agree
        // (see `PostGroupKeyNormalizationTests`); the SHORTCODE keeps its case.
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd")) ==
            "https://instagram.com/p/AbCd")
    }

    @Test("a trailing slash is normalized away — IG appends one, a share may not")
    func trailingSlashNormalized() {
        let withSlash = postGroupKey(for: source("https://www.instagram.com/p/AbCd/"))
        let without = postGroupKey(for: source("https://www.instagram.com/p/AbCd"))
        #expect(withSlash == without)
    }

    @Test("a #fragment is dropped")
    func fragmentDropped() {
        #expect(postGroupKey(for: source("https://x.com/a/status/1#m")) ==
            postGroupKey(for: source("https://x.com/a/status/1")))
    }

    @Test("case is PRESERVED — IG shortcodes are case-sensitive")
    func caseIsPreserved() {
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd/")) !=
            postGroupKey(for: source("https://www.instagram.com/p/abcd/")))
    }

    @Test("a source with no URL has no key — local captures must not all group")
    func noURLNoKey() {
        #expect(postGroupKey(for: source(nil)) == nil)
        #expect(postGroupKey(for: source("")) == nil)
        #expect(postGroupKey(for: source("   ")) == nil)
        #expect(postGroupKey(for: source("/")) == nil)
    }
}

// MARK: - The index

@Suite("Post grouping: the index")
struct PostGroupsTests {

    @Test("a carousel groups on the shared URL even though every source id differs")
    func carouselSharesURLNotSourceID() {
        let post = "https://www.instagram.com/p/AbCd/"
        let a = item(url: post), b = item(url: post), c = item(url: post)
        // The premise: the funnel wrote three DISTINCT sources for one post.
        #expect(Set([a, b, c].map(\.asset.sourceId)).count == 3)

        let groups = PostGroups(items: [a, b, c])
        #expect(groups.memberCount(forItem: a.item.id) == 3)
        #expect(Set(groups.members(forItem: b.item.id)) ==
            Set([a, b, c].map(\.item.id)))
    }

    @Test("members are returned in feed order")
    func membersInFeedOrder() {
        let post = "https://x.com/a/status/1"
        let a = item(url: post, platform: .twitter)
        let b = item(url: post, platform: .twitter)
        let groups = PostGroups(items: [a, b])
        #expect(groups.members(forItem: b.item.id) == [a.item.id, b.item.id])
    }

    @Test("a single-image post is not a group — no badge, no ring")
    func loneItemIsNotAGroup() {
        let lone = item(url: "https://www.instagram.com/p/Solo/")
        let groups = PostGroups(items: [lone])
        #expect(groups.memberCount(forItem: lone.item.id) == 0)
        #expect(groups.members(forItem: lone.item.id).isEmpty)
    }

    @Test("URL-less local captures never group together")
    func localCapturesNeverGroup() {
        let a = item(url: nil, platform: .localPaste)
        let b = item(url: nil, platform: .localDrag)
        let groups = PostGroups(items: [a, b])
        #expect(groups.memberCount(forItem: a.item.id) == 0)
        #expect(groups.memberCount(forItem: b.item.id) == 0)
    }

    @Test("counts are scoped to the LOADED feed, not the library")
    func countIsFeedScoped() {
        // Two of a four-image carousel were filed elsewhere; this collection shows
        // two, and that is what the badge must promise.
        let post = "https://www.instagram.com/p/Half/"
        let a = item(url: post), b = item(url: post)
        let groups = PostGroups(items: [a, b, item(url: "https://www.instagram.com/p/Other/")])
        #expect(groups.memberCount(forItem: a.item.id) == 2)
    }

    @Test("the empty index answers everything with nothing")
    func emptyIndex() {
        let groups = PostGroups()
        let id = UUID()
        #expect(groups.memberCount(forItem: id) == 0)
        #expect(groups.members(forItem: id).isEmpty)
        // An empty index must widen to exactly what it was given, or every action
        // would silently act on nothing before the first feed loads.
        #expect(groups.expand([id]) == [id])
        #expect(groups.collapsed([]).isEmpty)
    }
}

@Suite("Post grouping: the .union selection action")
struct GridSelectionUnionTests {

    @Test("union ADDS to the selection instead of replacing it")
    func unionIsAdditive() {
        let order = [UUID(), UUID(), UUID(), UUID()]
        var selection = GridSelection()
        selection.ids = [order[0]]
        let (next, _) = selection.applying(.union([order[2], order[3]]), order: order)
        #expect(next.ids == Set([order[0], order[2], order[3]]))
    }

    @Test("the cursor lands on the last added item in feed order and scrolls to it")
    func unionMovesTheCursor() {
        let order = [UUID(), UUID(), UUID()]
        let selection = GridSelection()
        let (next, effect) = selection.applying(.union([order[2], order[1]]), order: order)
        #expect(next.lead == order[2])
        #expect(next.anchor == order[2])
        #expect(effect == .scrollTo(order[2]))
    }

    @Test("a union that adds nothing is a no-op, cursor included")
    func unionOfAlreadySelectedIsNoOp() {
        let order = [UUID(), UUID()]
        var selection = GridSelection()
        selection.ids = [order[0], order[1]]
        selection.lead = order[0]
        let (next, effect) = selection.applying(.union([order[1]]), order: order)
        #expect(next == selection)
        #expect(effect == .none)
    }

    @Test("union collapses the live shift range, like any non-⇧ membership edit")
    func unionCollapsesShiftRange() {
        let order = [UUID(), UUID(), UUID()]
        var selection = GridSelection()
        selection.ids = [order[0], order[1]]
        selection.shiftRange = [order[0], order[1]]
        let (next, _) = selection.applying(.union([order[2]]), order: order)
        #expect(next.shiftRange.isEmpty)
        #expect(next.ids == Set(order))
    }
}

// MARK: - Accessibility

@Suite("Post grouping: the VoiceOver label")
struct PostBadgeAccessibilityTests {

    @Test("a carousel member says so; a lone item's label is unchanged")
    func labelCarriesTheGroup() {
        let detail = item(url: "https://www.instagram.com/p/AbCd/")
        let plain = gridCellAccessibilityLabel(for: detail, postMemberCount: 0)
        #expect(gridCellAccessibilityLabel(for: detail, postMemberCount: 1) == plain)
        #expect(gridCellAccessibilityLabel(for: detail, postMemberCount: 4) ==
            plain + ", one of 4 from the same post")
    }
}

// MARK: - Key normalization across the three producers

/// Three things write `Source.originalURL` and they do not agree: the live-page
/// extractor (`cleanURL` = origin + pathname), the bulk saved-feed mapper (which
/// synthesises `/p/` or `/reel/` and takes its host from context), and a hand-pasted
/// share link (which is where tracking params actually arrive). Every merge below is
/// a case where ONE post would otherwise become two groups.
///
/// The non-merge cases matter more than the merges. Under-normalizing splits a
/// carousel — visible and harmless. Over-normalizing fuses UNRELATED posts into one
/// group, which is invisible and would make an action on one post reach another's
/// images.
@Suite("Post grouping: key normalization")
struct PostGroupKeyNormalizationTests {

    @Test("a tracking query is dropped — a pasted share link carries ?igsh=")
    func queryStripped() {
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd/?igsh=xyz")) ==
            postGroupKey(for: source("https://www.instagram.com/p/AbCd/")))
    }

    @Test("the HOST is case-insensitive even though the path is not")
    func hostCaseIgnored() {
        #expect(postGroupKey(for: source("https://WWW.Instagram.com/p/AbCd/")) ==
            postGroupKey(for: source("https://www.instagram.com/p/AbCd/")))
    }

    @Test("www. / m. / bare host are the same site")
    func hostPrefixesAgree() {
        let bare = postGroupKey(for: source("https://instagram.com/p/AbCd/"))
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd/")) == bare)
        #expect(postGroupKey(for: source("https://m.instagram.com/p/AbCd/")) == bare)
    }

    @Test("/reel/ and /p/ are the same post — bulk picks one, a live page the other")
    func reelCanonicalisesToPost() {
        #expect(postGroupKey(for: source("https://www.instagram.com/reel/AbCd/")) ==
            postGroupKey(for: source("https://www.instagram.com/p/AbCd/")))
    }

    @Test("GUARD: a different shortcode is a different post")
    func differentShortcodesStayApart() {
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd/")) !=
            postGroupKey(for: source("https://www.instagram.com/p/AbCe/")))
    }

    @Test("GUARD: host-lowercasing must NOT lowercase the shortcode")
    func pathCaseSurvivesHostLowercasing() {
        #expect(postGroupKey(for: source("https://WWW.INSTAGRAM.COM/p/AbCd/")) !=
            postGroupKey(for: source("https://www.instagram.com/p/abcd/")))
    }

    @Test("GUARD: same path on different sites stays apart")
    func differentHostsStayApart() {
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd/")) !=
            postGroupKey(for: source("https://example.com/p/AbCd/")))
    }

    @Test("an unparseable URL still yields a stable key rather than crashing")
    func malformedFallsBack() {
        let key = postGroupKey(for: source("not a url at all"))
        #expect(key == "not a url at all")
        #expect(key == postGroupKey(for: source("  not a url at all  ")))
    }
}

// MARK: - The collapsed display list

@Suite("Post grouping: collapse")
struct PostGroupsCollapseTests {

    @Test("a carousel becomes ONE tile, standing at its first member's position")
    func carouselCollapsesToFirstMember() {
        let post = "https://www.instagram.com/p/AbCd/"
        let lead = item(url: post)
        let other = item(url: "https://www.instagram.com/p/Zzzz/")
        let feed = [lead, item(url: post), other, item(url: post)]
        let groups = PostGroups(items: feed)
        let shown = groups.collapsed(feed).map { $0.item.id }
        #expect(shown == [lead.item.id, other.item.id])
    }

    @Test("a feed with nothing to group is returned unchanged")
    func ungroupedFeedUntouched() {
        let feed = [item(url: "https://x.com/a/status/1"), item(url: nil), item(url: nil)]
        let groups = PostGroups(items: feed)
        #expect(groups.collapsed(feed).map { $0.item.id } == feed.map { $0.item.id })
    }

    @Test("a half-filed post collapses to the members actually present")
    func halfFiledCollapsesToWhatIsHere() {
        let post = "https://www.instagram.com/p/Half/"
        let lead = item(url: post)
        let feed = [lead, item(url: post)]
        let groups = PostGroups(items: feed)
        #expect(groups.collapsed(feed).count == 1)
        #expect(groups.memberCount(forItem: lead.item.id) == 2)
    }

    @Test("every ungrouped item is its own representative")
    func ungroupedItemsAreRepresentatives() {
        let lone = item(url: nil)
        let groups = PostGroups(items: [lone, item(url: nil)])
        #expect(groups.isRepresentative(lone.item.id))
    }
}

// MARK: - The action boundary

@Suite("Post grouping: expand")
struct PostGroupsExpandTests {

    @Test("a representative widens to every member of its post")
    func representativeWidensToPost() {
        let post = "https://www.instagram.com/p/AbCd/"
        let a = item(url: post), b = item(url: post), c = item(url: post)
        let groups = PostGroups(items: [a, b, c])
        #expect(groups.expand([a.item.id]) == Set([a.item.id, b.item.id, c.item.id]))
    }

    @Test("an ungrouped id widens to itself, so callers never special-case")
    func ungroupedWidensToItself() {
        let lone = item(url: nil)
        let groups = PostGroups(items: [lone, item(url: nil)])
        #expect(groups.expand([lone.item.id]) == [lone.item.id])
    }

    @Test("a mixed selection widens only its grouped part")
    func mixedSelectionWidensPartly() {
        let post = "https://www.instagram.com/p/AbCd/"
        let a = item(url: post), b = item(url: post)
        let lone = item(url: nil)
        let groups = PostGroups(items: [a, b, lone])
        #expect(groups.expand([a.item.id, lone.item.id]) ==
            Set([a.item.id, b.item.id, lone.item.id]))
    }

    @Test("widening is what makes a collapsed tile act on four things, not one")
    func collapsedTileActsOnWholePost() {
        let post = "https://www.instagram.com/p/AbCd/"
        let feed = [item(url: post), item(url: post), item(url: post), item(url: post)]
        let groups = PostGroups(items: feed)
        let shown = groups.collapsed(feed)
        #expect(shown.count == 1)
        #expect(groups.expand([shown[0].item.id]).count == 4)
    }
}

// MARK: - The badge pixmap

@Suite("Post grouping: the badge image")
@MainActor
struct PostBadgeImageTests {

    @Test("a lone item gets no chip; a carousel does")
    func nilBelowTwo() {
        #expect(PostBadge.image(count: 0) == nil)
        #expect(PostBadge.image(count: 1) == nil)
        #expect(PostBadge.image(count: 2) != nil)
    }

    @Test("repeat calls hand back the SAME pixmap — the cache is the point")
    func cachedByCount() {
        let first = PostBadge.image(count: 7)
        let second = PostBadge.image(count: 7)
        #expect(first != nil)
        #expect(first === second)
    }
}
