//
//  DetailSourceMetadataTests.swift
//  AtelierRefsTests
//
//  089 §Open — `repostedBy` / `threadId` / `threadIndex` were "stored but unread by
//  the app UI". 099 · P9 reads them into the Source section. NOTHING NEW IS STORED:
//  every value here is one the extension has been writing since 310 / [090] 16A, and
//  these are the readers over `Source.rawMetadata`.
//
//  The shapes asserted below are not invented. They were taken by running the
//  extension's own mappers over its committed fixtures:
//
//    · `mapThread` over `x-thread-detail.json` — the sanitized LIVE TweetDetail
//      capture — stamps all 8 items with `threadId` as a **string**
//      ("1900000000000040001") and `threadIndex` as a **number** (0,1,2,3,4; two
//      images of one tweet share an index).
//    · `parseTimelinePage` over BOTH bookmark fixtures (`x-bookmarks.json`,
//      `x-bookmarks-live.json`, 15 items between them) writes NONE of the three.
//      A plain saved post carries no thread stamp and no reposter, which is why
//      `plainPostRendersNothing` is the case that matters most: it is what almost
//      every item in a real library looks like.
//    · `repostedBy` appears in no committed fixture at all — only in
//      `bulk-twitter.test.js:312`, as the string "@reposter". The reader is written
//      to that shape and to `bulk-twitter.js:306`'s promise that the key is absent
//      rather than null when there is no repost.
//
//  Pure functions over a value type, so no view and no database: the rows they feed
//  are three `if let`s in `SourceSection`.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// A `Source` carrying `metadata`, as the ingest funnel writes them.
private func source(_ metadata: JSONValue) -> Source {
    Source(
        id: UUID(), platform: .twitter,
        originalURL: "https://x.com/someone/status/1900000000000040001",
        authorHandle: "@someone", authorName: "Someone", title: "a post",
        capturedAt: Date(), rawMetadata: metadata)
}

// MARK: - Reposts

@Suite("Detail page: who reposted this (089 · repostedBy)")
struct RepostedByTests {

    @Test("the reposter's handle is read back exactly as the extension wrote it")
    func readsTheHandle() {
        #expect(repostedBy(for: source(.object(["repostedBy": .string("@reposter")])))
            == "@reposter")
    }

    /// `bulk-twitter.js:306` — "`repostedBy` is written only when there IS one — a
    /// plain tweet's stored metadata stays exactly as it was rather than gaining a
    /// null key." So absence is the norm, not an error.
    @Test("a non-repost carries no key, and draws no row")
    func absentKey() {
        #expect(repostedBy(for: source(.object([:]))) == nil)
        #expect(repostedBy(for: source(.object(["tweetId": .string("1")]))) == nil)
    }

    @Test("a blank handle draws no row rather than a blank one")
    func blankHandle() {
        #expect(repostedBy(for: source(.object(["repostedBy": .string("")]))) == nil)
        #expect(repostedBy(for: source(.object(["repostedBy": .string("   \n ")]))) == nil)
    }

    /// The narrowness `explicitPostGroupKey` states about itself: a STRING only, so a
    /// producer that writes the wrong type contributes no row instead of "1234.0".
    @Test("a non-string value is ignored, not coerced")
    func wrongType() {
        #expect(repostedBy(for: source(.object(["repostedBy": .number(12)]))) == nil)
        #expect(repostedBy(for: source(.object(["repostedBy": .null]))) == nil)
        #expect(repostedBy(for: source(.object(["repostedBy": .object([:])]))) == nil)
    }

    @Test("a whitespace-wrapped handle is trimmed, as a wrapped byline can produce")
    func trimsSurroundingWhitespace() {
        #expect(repostedBy(for: source(.object(["repostedBy": .string(" @reposter\n")])))
            == "@reposter")
    }

    @Test("rawMetadata that is not an object yields nothing rather than trapping")
    func nonObjectMetadata() {
        #expect(repostedBy(for: source(.null)) == nil)
        #expect(repostedBy(for: source(.string("not json at all"))) == nil)
        #expect(repostedBy(for: source(.array([]))) == nil)
    }
}

// MARK: - Threads

@Suite("Detail page: where in the thread this is (089 · threadId / threadIndex)")
struct ThreadStampTests {

    /// The id from the real capture — 19 digits, which is the point of the next test.
    private static let liveHead = "1900000000000040001"

    @Test("the thread id is read back as the string the extension stamped")
    func readsTheThreadID() {
        #expect(threadID(for: source(.object(["threadId": .string(Self.liveHead)])))
            == Self.liveHead)
    }

    /// **A tweet id is a 64-bit snowflake.** `1900000000000040001` is past `Double`'s
    /// 2^53 of exactly-representable integers, so a `.number` here could not be
    /// rendered back without corrupting its last digits — this test pins that the
    /// reader refuses it rather than printing a subtly wrong id. It is exactly where
    /// `carouselIndex`'s deliberate tolerance of a quoted number must NOT be copied.
    @Test("a numeric thread id is refused, because a snowflake does not survive a Double")
    func numericThreadIDIsRefused() {
        let asDouble = Double(Self.liveHead)!
        // The premise: the round trip is already lossy before any code of ours runs.
        #expect(String(Int64(asDouble)) != Self.liveHead)
        #expect(threadID(for: source(.object(["threadId": .number(asDouble)]))) == nil)
    }

    @Test("a blank or absent thread id draws no row")
    func blankThreadID() {
        #expect(threadID(for: source(.object([:]))) == nil)
        #expect(threadID(for: source(.object(["threadId": .string("")]))) == nil)
        #expect(threadID(for: source(.object(["threadId": .string("  ")]))) == nil)
        #expect(threadID(for: source(.null)) == nil)
    }

    /// The shape `mapThread` actually produces: a JSON **number**.
    @Test("the thread index is read from a number", arguments: [0, 1, 2, 3, 4])
    func readsTheThreadIndex(position: Int) {
        #expect(threadIndex(for: source(
            .object(["threadIndex": .number(Double(position))]))) == position)
    }

    /// `carouselIndex`'s tolerance, and for its stated reason: `raw_metadata` is a JSON
    /// escape hatch written by JavaScript, and a producer that serialises `"0"` should
    /// not silently drop the row. Safe here where it is not for the id — an index is
    /// small enough that the round trip is exact either way.
    @Test("a quoted index is tolerated, as the carousel index already is")
    func readsAQuotedThreadIndex() {
        #expect(threadIndex(for: source(.object(["threadIndex": .string("3")]))) == 3)
        #expect(threadIndex(for: source(.object(["threadIndex": .string("0")]))) == 0)
    }

    /// There is no tweet before the first one. A negative means the stamp is wrong,
    /// which is better said by drawing no row than by rendering "Tweet 0".
    @Test("a negative index is refused rather than clamped")
    func negativeIndexIsRefused() {
        #expect(threadIndex(for: source(.object(["threadIndex": .number(-1)]))) == nil)
        #expect(threadIndex(for: source(.object(["threadIndex": .string("-2")]))) == nil)
    }

    @Test("a non-numeric index is ignored, not coerced")
    func nonNumericIndex() {
        #expect(threadIndex(for: source(.object(["threadIndex": .string("first")]))) == nil)
        #expect(threadIndex(for: source(.object(["threadIndex": .null]))) == nil)
        #expect(threadIndex(for: source(.object(["threadIndex": .bool(true)]))) == nil)
        #expect(threadIndex(for: source(.array([.number(2)]))) == nil)
    }

    /// The row reads "Tweet N" 1-based, exactly as the "Post" row directly above it
    /// reads "Image N of M": the stamp counts from zero because it is an array
    /// position, and nobody walking a thread calls the first tweet "tweet 0".
    @Test("the stored index is 0-based and the row is 1-based")
    func rowIsOneBased() throws {
        let head = try #require(threadIndex(for: source(
            .object(["threadIndex": .number(0)]))))
        #expect(head == 0)
        #expect("Tweet \(head + 1)" == "Tweet 1")
    }
}

// MARK: - The three together

@Suite("Detail page: the three X fields are independent (089 §Open)")
struct SourceMetadataIndependenceTests {

    /// The shape `mapThread` stamps on every item of the LIVE capture: both thread
    /// fields, no reposter. Two items of one tweet share an index — the fact being
    /// that they are the same tweet.
    @Test("a thread item carries both thread fields and no reposter")
    func threadItem() {
        let s = source(.object([
            "tweetId": .string("1900000000000042001"),
            "threadId": .string("1900000000000040001"),
            "threadIndex": .number(2),
        ]))
        #expect(threadID(for: s) == "1900000000000040001")
        #expect(threadIndex(for: s) == 2)
        #expect(repostedBy(for: s) == nil)
    }

    /// The shape `mapTweet` stamps on a repost: a reposter, no thread.
    @Test("a repost carries a reposter and no thread stamp")
    func repostItem() {
        let s = source(.object([
            "tweetId": .string("42"), "repostedBy": .string("@reposter"),
        ]))
        #expect(repostedBy(for: s) == "@reposter")
        #expect(threadID(for: s) == nil)
        #expect(threadIndex(for: s) == nil)
    }

    /// **The case that matters most.** Running `parseTimelinePage` over both committed
    /// bookmark fixtures produced 15 items and not one of the three keys. This is what
    /// almost every item in a real library looks like, and the Source section must
    /// render exactly what it rendered before these rows existed.
    @Test("a plain saved post has none of the three, and adds no rows")
    func plainPostRendersNothing() {
        let s = source(.object([
            "tweetId": .string("1900000000000010001"),
            "postGroupKey": .string("https://x.com/someone/status/1900000000000010001"),
            "carouselIndex": .number(1),
        ]))
        #expect(repostedBy(for: s) == nil)
        #expect(threadID(for: s) == nil)
        #expect(threadIndex(for: s) == nil)
    }

    /// A non-X source can never carry them, and asking costs nothing.
    @Test("a Pinterest pin's own metadata is untouched by all three readers")
    func nonTwitterSource() {
        var s = source(.object(["board": .string("Refs"), "pinId": .string("77")]))
        s.platform = .pinterest
        #expect(repostedBy(for: s) == nil)
        #expect(threadID(for: s) == nil)
        #expect(threadIndex(for: s) == nil)
    }

    /// A half-written stamp — the index without the id — still says something true
    /// (which tweet of the chain), so the rows are gated independently rather than on
    /// each other. A gate on the pair would have dropped a real fact.
    @Test("a half-stamped item still renders the half it has")
    func halfStamp() {
        #expect(threadIndex(for: source(.object(["threadIndex": .number(4)]))) == 4)
        #expect(threadID(for: source(.object(["threadIndex": .number(4)]))) == nil)
        #expect(threadID(for: source(.object(["threadId": .string("9")]))) == "9")
        #expect(threadIndex(for: source(.object(["threadId": .string("9")]))) == nil)
    }
}
