//
//  DetailPostTests.swift
//  AtelierRefsTests
//
//  080 §5 · T2 / T3 / T4 — the detail page's post context, pinned as pure functions.
//
//  `DetailStepTests` sets the strategy for this area out loud: the off-by-one lives
//  here, and it "should not be tested through the view". So the whole of increment 1
//  is testable without a SwiftUI harness — ``PostGroups/detailPost(forItem:thumbnailURL:jump:)``
//  is a factory over an index the suite can build, and ``showsPostChip(memberCount:)``
//  is a predicate.
//
//  T2 is the reason the factory sits on ``PostGroups`` at all. The page's ← / → walk
//  ``PostGroups/fullRun(_:)`` (069/316) and the chip counts a position inside a post;
//  those are two derivations of one fact, and nothing in the running app would say so
//  if they drifted — the chip would simply read "3 of 4" while the arrows sat on image
//  2. `indexAgreesWithTheRun` is what makes that a build failure instead.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// One feed item from the post at `url` (nil = an ungroupable local capture), with its
/// OWN `Source` row exactly as the ingest funnel writes them (see `PostGroupingTests`).
///
/// `blobHash: nil` makes a MEDIA-LESS member (003 · O1) — a tweet / link / colour, which
/// since 310 can legitimately sit in the same post as an image.
private func item(
    url: String?, carouselIndex: Int? = nil, blobHash: String? = "hash-\(UUID().uuidString)"
) -> CollectionItemDetail {
    let sourceID = UUID(), assetID = UUID()
    let metadata: JSONValue = carouselIndex.map {
        .object(["carouselIndex": .number(Double($0))])
    } ?? .object([:])
    let source = Source(
        id: sourceID, platform: .instagram, originalURL: url, capturedAt: Date(),
        rawMetadata: metadata)
    let asset = Asset(
        id: assetID, kind: blobHash == nil ? .tweet : .image, blobHash: blobHash,
        mimeType: blobHash == nil ? nil : "image/jpeg",
        width: blobHash == nil ? nil : 100, height: blobHash == nil ? nil : 100,
        fileSize: blobHash == nil ? nil : 100, downloadState: .downloaded,
        createdAt: Date(), sourceId: sourceID)
    return CollectionItemDetail(
        item: CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
        asset: asset, source: source)
}

/// The factory with both host-supplied closures stubbed out — every test below is about
/// the DERIVATION, and neither closure participates in one.
private func post(_ groups: PostGroups, _ id: UUID) -> ItemDetailPost? {
    groups.detailPost(forItem: id, thumbnailURL: { _ in nil }, jump: { _ in })
}

// MARK: - T2 · the factory agrees with the run

@Suite("Detail page: the post the page is inside (080 T2)")
struct DetailPostFactoryTests {

    private static let postA = "https://www.instagram.com/p/AAA/"
    private static let postB = "https://www.instagram.com/p/BBB/"

    /// A feed with everything that can happen in one: a carousel whose images a reorder
    /// has scattered AND inverted (309), a second post with no recorded order, an item
    /// from a post only one of whose images is in this feed, and two local captures.
    private static func feed() -> [CollectionItemDetail] {
        [
            item(url: postA, carouselIndex: 2),
            item(url: nil),
            item(url: postB),
            item(url: postA, carouselIndex: 0),
            item(url: "https://x.com/u/status/9"),
            item(url: postB),
            item(url: postA, carouselIndex: 1),
            item(url: nil),
        ]
    }

    /// **The load-bearing test.** For every item in the feed, the index the chip would
    /// print is the item's offset within its post's contiguous slice of the run the
    /// arrows walk. Checked for the whole feed rather than one hand-picked item, so a
    /// derivation that happens to agree at position 0 cannot pass.
    @Test("the chip's index is the item's place in its post's slice of the run")
    func indexAgreesWithTheRun() throws {
        let feed = Self.feed()
        let groups = PostGroups(items: feed)
        let run = groups.fullRun(feed)
        let runPosition = Dictionary(
            uniqueKeysWithValues: run.enumerated().map { ($0.element.item.id, $0.offset) })

        var grouped = 0
        for detail in feed {
            let id = detail.item.id
            let members = groups.members(forItem: id)
            guard !members.isEmpty else {
                #expect(post(groups, id) == nil, "an ungrouped item must have no post")
                continue
            }
            grouped += 1
            let subject = try #require(post(groups, id))
            let positions = try members.map { try #require(runPosition[$0]) }
            // 069/316: a post's members are ONE contiguous block of the run, in post
            // order. If that ever stops being true the chip's arithmetic is meaningless,
            // so it is asserted here rather than assumed.
            let start = try #require(positions.first)
            let here = try #require(runPosition[id])
            #expect(positions == Array(start..<(start + members.count)))
            #expect(subject.index == here - start)
            #expect(subject.memberCount == members.count)
        }
        // The feed above has 5 grouped items (3 + 2); a fixture edit that quietly
        // ungroups them would otherwise leave this test passing vacuously.
        #expect(grouped == 5)
    }

    @Test("an ungrouped item has no post — the page draws nothing")
    func ungroupedItemHasNoPost() {
        let local = item(url: nil)
        let groups = PostGroups(items: [local, item(url: Self.postA), item(url: Self.postA)])
        #expect(post(groups, local.item.id) == nil)
    }

    /// `PostGroups` drops every group of one (`PostGrouping.swift:170`), so a post with
    /// a single image in this feed is not a post here — and `memberCount` is never `1`.
    @Test("a would-be single is nil, not a post of one")
    func loneMemberIsNotAPost() {
        let lone = item(url: Self.postB)
        let groups = PostGroups(items: [lone, item(url: Self.postA), item(url: Self.postA)])
        #expect(groups.memberCount(forItem: lone.item.id) == 0)
        #expect(post(groups, lone.item.id) == nil)
    }

    /// The seed is the REPRESENTATIVE's membership id — the same `detail.item.id` the
    /// collapsed tile fans with (`MasonryGridItem.swift:731`), which is what lets the
    /// page's pile be the pile the user clicked. Post order, not feed order: for an
    /// indexed carousel that is image #1 (309).
    @Test("the seed is the post's representative, in POST order")
    func seedIsTheRepresentative() throws {
        let second = item(url: Self.postA, carouselIndex: 1)
        let first = item(url: Self.postA, carouselIndex: 0)
        let groups = PostGroups(items: [second, first])
        for subject in [second, first] {
            let value = try #require(post(groups, subject.item.id))
            #expect(value.seed == first.item.id)
        }
        // Feed order is 1-then-0; the post's own order is what the factory reports.
        let laterInTheFeed = try #require(post(groups, second.item.id))
        #expect(laterInTheFeed.index == 1)
    }

    /// ALL-OR-NOTHING (`PostGrouping.swift:171`): a post is only put in carousel order
    /// when EVERY member carries an index. One live-grabbed image without one drops the
    /// whole post back to feed order — and the factory must report that order, not the
    /// order the two indices it does have would suggest.
    @Test("a half-indexed post falls back to feed order")
    func halfIndexedPostFallsBackToFeedOrder() throws {
        let ninth = item(url: Self.postA, carouselIndex: 9)   // would sort LAST if trusted
        let zeroth = item(url: Self.postA, carouselIndex: 0)  // would sort FIRST
        let unindexed = item(url: Self.postA)
        let groups = PostGroups(items: [ninth, zeroth, unindexed])

        let lead = try #require(post(groups, ninth.item.id))
        #expect(lead.index == 0)
        #expect(lead.seed == ninth.item.id)
        let middle = try #require(post(groups, zeroth.item.id))
        #expect(middle.index == 1)
        let last = try #require(post(groups, unindexed.item.id))
        #expect(last.index == 2)
    }
}

// MARK: - T3 · visibility (the chip half)

@Suite("Detail page: when the post chip draws (080 T3)")
struct DetailPostChipVisibilityTests {

    /// `0` is "ungrouped", `1` cannot occur (groups of one are dropped) but is pinned
    /// anyway because the predicate is the defensive statement of the rule, and 15 is
    /// the top of a rednote carousel (020).
    @Test("the chip needs a real post", arguments: [(0, false), (1, false), (2, true), (15, true)])
    func chipVisibility(memberCount: Int, shows: Bool) {
        #expect(showsPostChip(memberCount: memberCount) == shows)
    }
}

// MARK: - T4 · mutation while the page is open

@Suite("Detail page: the post changes under the page (080 T4)")
struct DetailPostMutationTests {

    private static let url = "https://www.instagram.com/p/AAA/"

    /// **T4.1.** ⌫ / ⌘⌫ reach the page (`ItemDetailView.swift:233`), so a 2-image post
    /// can lose a member while it is being looked at. `PostGroups` drops every group of
    /// one, so the survivor's count goes 2 → 0, not 2 → 1: the chip must VANISH rather
    /// than sit there reading "1 of 1 in this post".
    @Test("a 2-image post losing a member dissolves the group, and the chip with it")
    func twoImagePostDissolves() throws {
        let kept = item(url: Self.url), deleted = item(url: Self.url)

        let before = PostGroups(items: [kept, deleted])
        let opened = try #require(post(before, kept.item.id))
        #expect(opened.memberCount == 2)
        #expect(showsPostChip(memberCount: opened.memberCount))

        let after = PostGroups(items: [kept])
        #expect(after.memberCount(forItem: kept.item.id) == 0)
        #expect(post(after, kept.item.id) == nil)
        #expect(!showsPostChip(memberCount: 0))
    }

    /// **T4.4.** Since 310 a post's members can be a mix of kinds, and a media-less one
    /// (003 · O1) has no blob to draw. It stays a MEMBER — it is counted, it has a
    /// position, the arrows walk onto it — it simply contributes no card to the spread.
    /// Which is why `blobHashes` is deliberately not index-aligned with `index`.
    @Test("a media-less member is skipped, not crashed on")
    func mediaLessMemberIsSkipped() throws {
        let first = item(url: Self.url, carouselIndex: 0, blobHash: "aaa")
        let mediaLess = item(url: Self.url, carouselIndex: 1, blobHash: nil)
        let third = item(url: Self.url, carouselIndex: 2, blobHash: "ccc")
        let groups = PostGroups(items: [first, mediaLess, third])

        let subject = try #require(groups.detailPost(
            forItem: mediaLess.item.id,
            thumbnailURL: { URL(string: "file:///thumbs/\($0).jpg") },
            jump: { _ in }))
        #expect(subject.memberCount == 3)
        #expect(subject.index == 1)
        #expect(subject.blobHashes == ["aaa", "ccc"])
        #expect(subject.thumbnailURL("aaa") == URL(string: "file:///thumbs/aaa.jpg"))

        // And from a neighbour, so the compaction is not accidentally keyed on who asks.
        let neighbour = try #require(post(groups, third.item.id))
        #expect(neighbour.blobHashes == ["aaa", "ccc"])
    }

    /// A post of nothing but media-less members yields an empty card list rather than a
    /// crash or a phantom — the count still says there are three of them.
    @Test("a post with no media at all still counts its members")
    func allMediaLessPost() throws {
        let members = (0..<3).map { item(url: Self.url, carouselIndex: $0, blobHash: nil) }
        let groups = PostGroups(items: members)
        let subject = try #require(post(groups, members[0].item.id))
        #expect(subject.memberCount == 3)
        #expect(subject.blobHashes.isEmpty)
    }
}
