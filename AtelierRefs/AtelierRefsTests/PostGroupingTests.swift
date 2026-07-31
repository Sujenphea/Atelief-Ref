//
//  PostGroupingTests.swift
//  AtelierRefsTests
//
//  307 · carousel grouping — the pure grouping the grid's carousel badge, the
//  dashed sibling ring, and the "Select N More from This Post" action all read.
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

    @Test("a permalink is the key")
    func permalinkIsTheKey() {
        #expect(postGroupKey(for: source("https://www.instagram.com/p/AbCd")) ==
            "https://www.instagram.com/p/AbCd")
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

    @Test("siblings are the UNSELECTED members of the selection's posts")
    func siblingsExcludeTheSelection() {
        let post = "https://www.instagram.com/p/AbCd/"
        let a = item(url: post), b = item(url: post), c = item(url: post)
        let unrelated = item(url: "https://www.instagram.com/p/Zzzz/")
        let groups = PostGroups(items: [a, b, c, unrelated])
        #expect(groups.siblings(ofSelected: [a.item.id]) == Set([b.item.id, c.item.id]))
        #expect(groups.siblings(ofSelected: [a.item.id, b.item.id]) == [c.item.id])
        #expect(groups.siblings(ofSelected: [a.item.id, b.item.id, c.item.id]).isEmpty)
    }

    @Test("a selection spanning two posts pulls siblings from both")
    func siblingsAcrossTwoPosts() {
        let one = "https://www.instagram.com/p/One/", two = "https://www.instagram.com/p/Two/"
        let a = item(url: one), b = item(url: one)
        let c = item(url: two), d = item(url: two)
        let groups = PostGroups(items: [a, b, c, d])
        #expect(groups.siblings(ofSelected: [a.item.id, c.item.id]) ==
            Set([b.item.id, d.item.id]))
        #expect(groups.groupCount(ofSelected: [a.item.id, c.item.id]) == 2)
        #expect(groups.groupCount(ofSelected: [a.item.id, b.item.id]) == 1)
    }

    @Test("an ungrouped selection has no siblings")
    func ungroupedSelectionHasNoSiblings() {
        let lone = item(url: nil)
        let groups = PostGroups(items: [lone, item(url: nil)])
        #expect(groups.siblings(ofSelected: [lone.item.id]).isEmpty)
        #expect(groups.groupCount(ofSelected: [lone.item.id]) == 0)
    }

    @Test("the empty index answers everything with nothing")
    func emptyIndex() {
        let groups = PostGroups()
        let id = UUID()
        #expect(groups.memberCount(forItem: id) == 0)
        #expect(groups.siblings(ofSelected: [id]).isEmpty)
    }
}

// MARK: - Wording

@Suite("Post grouping: the action title")
struct SelectSamePostTitleTests {

    @Test("nothing to add hides the affordance")
    func noSiblingsNoTitle() {
        #expect(selectSamePostTitle(siblingCount: 0, postCount: 1) == nil)
    }

    @Test("one post reads singular, several read plural")
    func singularAndPlural() {
        #expect(selectSamePostTitle(siblingCount: 3, postCount: 1) ==
            "Select 3 More from This Post")
        #expect(selectSamePostTitle(siblingCount: 4, postCount: 2) ==
            "Select 4 More from These Posts")
    }
}

// MARK: - The reducer seam

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
        let plain = gridCellAccessibilityLabel(for: detail)
        #expect(gridCellAccessibilityLabel(for: detail, postMemberCount: 0) == plain)
        #expect(gridCellAccessibilityLabel(for: detail, postMemberCount: 4) ==
            plain + ", one of 4 from the same post")
    }
}
