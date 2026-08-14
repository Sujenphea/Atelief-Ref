// Atelier Capture — X conversation → the author's own chain (the PURE half, [090] 2A).
//
// Everything here is a total function over a JSON body: the conversation walk, the
// fork/foreign-author rules that keep someone else's discussion out of your capture, and
// the re-stamping that makes a thread group as one post. No network, no browser. The
// request side lives in twitter-detail-client.test.js.
//
// Two kinds of body are used here, and the split is the point ([090] 1A/9A):
//
//   · x-thread-detail.json — a REAL sanitized TweetDetail capture (29 tweets, 13
//     authors, a 5-tweet self-thread with 12 of the author's own replies to commenters
//     mixed in). This is what proves the walk against the live endpoint. Every rule that
//     a real conversation can exercise is asserted against it.
//   · x-conversation.js — synthetic builders, kept ONLY for the shapes a capture won't
//     reliably contain: a self-branching fork, a chain rooted under another author, a
//     protected conversation. Deliberately minimal, and not a substitute for the above.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  collectConversationTweets, selfThreadChain, needsThreadExpansion, mapThread,
} from "../src/twitter-thread.js";
import { tweet, photo, conversation } from "./fixtures/x-conversation.js";

/** The live capture. Sanitized: identities, ids, urls and post text are synthetic; keys,
 * nesting and every reply relationship are exactly as X served them. */
const live = JSON.parse(readFileSync(new URL("./fixtures/x-thread-detail.json", import.meta.url)));
/** The head of the author's thread in that capture. */
const LIVE_HEAD = "1900000000000040001";
const LIVE_SPINE = [
  "1900000000000040001", "1900000000000041001", "1900000000000042001",
  "1900000000000043001", "1900000000000044001",
];

// MARK: - against the LIVE capture (the shapes X actually serves)

test("live: the conversation walk finds every tweet, across both entry shapes", () => {
  const tweets = collectConversationTweets(live);
  // The focal tweet arrives as a bare TimelineTimelineItem and the continuations inside a
  // conversationthread MODULE; a generic walk is what survives either moving alone.
  assert.equal(tweets.length, 29);
  assert.equal(new Set(tweets.map((t) => t.rest_id)).size, 29, "no tweet counted twice");
});

test("live: from the HEAD, the chain is the author's own thread and stops there", () => {
  assert.deepEqual(selfThreadChain(live, LIVE_HEAD).map((t) => t.rest_id), LIVE_SPINE);
});

test("live: from a MID-thread tweet, the chain walks up to the head and back down", () => {
  // Bookmarking part 3 must still save all five, in reading order — the case the whole
  // feature exists for.
  assert.deepEqual(selfThreadChain(live, LIVE_SPINE[2]).map((t) => t.rest_id), LIVE_SPINE);
});

test("live: the author's 12 replies TO COMMENTERS stay out of the thread", () => {
  // The trap that an author+conversation filter would fall into, now proven on real data:
  // this capture has twelve tweets by the thread's author that are NOT part of it.
  const chain = selfThreadChain(live, LIVE_HEAD);
  const screenNameOf = (t) => t?.core?.user_results?.result?.core?.screen_name || null;
  const author = screenNameOf(chain[0]);
  const allByAuthor = collectConversationTweets(live).filter((t) => screenNameOf(t) === author);

  assert.equal(author, "threadauthor");
  assert.equal(allByAuthor.length, 17, "the author appears 17 times in this conversation");
  assert.equal(chain.length, 5, "only five of them are the thread");
  // Each excluded one replies to somebody else's tweet — that is what disqualifies it.
  const inChain = new Set(chain.map((t) => t.rest_id));
  const chainIds = new Set(LIVE_SPINE);
  for (const t of allByAuthor.filter((x) => !inChain.has(x.rest_id))) {
    assert.equal(chainIds.has(t.legacy.in_reply_to_status_id_str), false,
      `${t.rest_id} replies into the thread's spine and should not have been dropped`);
  }
});

test("live: the thread maps to ONE post — shared permalink, contiguous open order", () => {
  const items = mapThread(selfThreadChain(live, LIVE_HEAD), { host: "x.com" });
  // The head carries 4 photos, the four continuations one each.
  assert.equal(items.length, 8);
  assert.deepEqual([...new Set(items.map((i) => i.provenance.originalURL))],
    [`https://x.com/threadauthor/status/${LIVE_HEAD}`]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.threadIndex), [0, 0, 0, 0, 1, 2, 3, 4]);
  for (const item of items) assert.equal(item.provenance.rawMetadata.threadId, LIVE_HEAD);
  // Per-media dedup keys must stay distinct or the engine skips siblings as already-seen.
  assert.equal(new Set(items.map((i) => i.sourceId)).size, 8);
  // These items ARE the expansion; a surviving hint would re-expand them every sweep.
  for (const item of items) assert.equal("threadHint" in item, false);
});

test("live: each tweet stays a TWEET, and the thread still forms one carousel", () => {
  // The shape the app needs, on the real capture: every tweet keeps its own identity
  // (its own id, its own text) so nothing dedups away, while all eight items still
  // group as a single post.
  const items = mapThread(selfThreadChain(live, LIVE_HEAD), { host: "x.com" });

  // One descriptor per TWEET — five, not eight. A tweet capture dedups on
  // `(kind, tweetID)`, so two items claiming one tweet id would collapse and the
  // second's photo would be deleted as an orphan blob.
  const described = items.filter((item) => item.content);
  assert.deepEqual(described.map((item) => item.content.payload.tweet.tweetID), LIVE_SPINE);
  assert.equal(new Set(described.map((i) => i.content.payload.tweet.tweetID)).size, 5,
    "every descriptor claims a DIFFERENT tweet id");

  // Each descriptor carries that tweet's own words, not the head's.
  const texts = described.map((item) => item.content.payload.tweet.text);
  assert.equal(new Set(texts).size, 5, "each tweet keeps its own text");
  assert.match(texts[0], /thread part 1/);
  assert.match(texts[4], /thread part 5/);

  // The head's four photos: one descriptor listing all four, three plain images.
  assert.equal(items[0].content.payload.tweet.media.length, 4);
  assert.deepEqual(items.slice(1, 4).map((i) => i.content), [undefined, undefined, undefined]);

  // …and every one of the eight still groups as ONE post, under the thread's permalink,
  // regardless of what ingest does to each tweet's originalURL for identity.
  const groupKeys = new Set(items.map((i) => i.provenance.rawMetadata.postGroupKey));
  assert.deepEqual([...groupKeys], [`https://x.com/threadauthor/status/${LIVE_HEAD}`]);
  assert.equal(items.length, 8);
});

test("live: a swept tweet from this thread is recognised as worth expanding", () => {
  const tweets = collectConversationTweets(live);
  const part2 = tweets.find((t) => t.rest_id === LIVE_SPINE[1]);
  const head = tweets.find((t) => t.rest_id === LIVE_HEAD);
  assert.equal(needsThreadExpansion(part2), true, "a reply is mid-thread by construction");
  // The head names no parent, so it is only reachable by probing — which is why
  // probeRoots is on in production.
  assert.equal(needsThreadExpansion(head), false);
  assert.equal(needsThreadExpansion(head, { probeRoots: true }), true);
});

// MARK: - against synthetic bodies (the shapes a capture won't contain)

// MARK: - the conversation walk

test("collectConversationTweets: finds tweets in bare entries AND inside modules", () => {
  const body = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  assert.deepEqual(collectConversationTweets(body).map((t) => t.rest_id), ["1", "2"]);
});

test("selfThreadChain: from a MID-thread tweet, walks up to the head and down to the end", () => {
  const chain = [
    tweet({ id: "1", text: "one" }),
    tweet({ id: "2", text: "two", replyTo: "1" }),
    tweet({ id: "3", text: "three", replyTo: "2" }),
    tweet({ id: "4", text: "four", replyTo: "3" }),
  ];
  // Bookmarking the 3rd tweet must yield all four, in reading order.
  const result = selfThreadChain(conversation(chain), "3");
  assert.deepEqual(result.map((t) => t.rest_id), ["1", "2", "3", "4"]);
});

test("selfThreadChain: from the HEAD, walks down the whole thread", () => {
  const chain = [
    tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" }), tweet({ id: "3", replyTo: "2" }),
  ];
  assert.deepEqual(selfThreadChain(conversation(chain), "1").map((t) => t.rest_id), ["1", "2", "3"]);
});

test("selfThreadChain: excludes the author's replies TO COMMENTERS", () => {
  // The trap that filtering by author+conversation alone would fall into: `99` is the
  // author replying to a stranger's comment. Same author, same conversation, NOT the thread.
  const body = conversation([
    tweet({ id: "1", text: "one" }),
    tweet({ id: "2", text: "two", replyTo: "1" }),
    tweet({ id: "50", author: "stranger", text: "a comment", replyTo: "1" }),
    tweet({ id: "99", text: "thanks!", replyTo: "50" }),
  ]);
  assert.deepEqual(selfThreadChain(body, "1").map((t) => t.rest_id), ["1", "2"]);
});

test("selfThreadChain: a FAST stranger reply never becomes the continuation", () => {
  // Ids are chronological, so a stranger who replies to the head within seconds gets a
  // LOWER id than the author's own part 2 — posted a minute later. "Earliest child wins"
  // would then follow the stranger straight out of the thread and file their words under
  // the author's post. Only the author's own replies are ever candidates.
  //
  // The live capture cannot prove this: there, every continuation was posted before any
  // reply arrived, so the ordering alone happens to give the right answer.
  const body = conversation([
    tweet({ id: "100", text: "head" }),
    tweet({ id: "150", author: "stranger", text: "first!", replyTo: "100" }),
    tweet({ id: "200", text: "part two", replyTo: "100" }),
    tweet({ id: "300", text: "part three", replyTo: "200" }),
  ]);
  assert.deepEqual(selfThreadChain(body, "100").map((t) => t.rest_id), ["100", "200", "300"]);
});

test("selfThreadChain: stops walking UP at another author's tweet", () => {
  // The author replied to someone else and then threaded under their own reply. The
  // chain is theirs alone — the stranger's tweet is context, not part of the capture.
  const body = conversation([
    tweet({ id: "1", author: "stranger", text: "someone else's tweet" }),
    tweet({ id: "2", text: "my reply", replyTo: "1" }),
    tweet({ id: "3", text: "continued", replyTo: "2" }),
  ]);
  assert.deepEqual(selfThreadChain(body, "3").map((t) => t.rest_id), ["2", "3"]);
});

test("selfThreadChain: a branch resolves to the earliest continuation", () => {
  const body = conversation([
    tweet({ id: "1" }),
    tweet({ id: "300", replyTo: "1" }),   // the later aside
    tweet({ id: "200", replyTo: "1" }),   // the real continuation (earlier id)
  ]);
  assert.deepEqual(selfThreadChain(body, "1").map((t) => t.rest_id), ["1", "200"]);
});

test("selfThreadChain: a dropped fork is REPORTED, never silently discarded ([090] 7A)", () => {
  const body = conversation([
    tweet({ id: "1" }),
    tweet({ id: "300", replyTo: "1" }),   // the aside that will be dropped
    tweet({ id: "200", replyTo: "1" }),   // the continuation that wins
  ]);
  const lines = [];
  const chain = selfThreadChain(body, "1", { log: (...parts) => lines.push(parts.join(" ")) });

  assert.deepEqual(chain.map((t) => t.rest_id), ["1", "200"]);
  assert.equal(lines.length, 1, "the discard is announced exactly once");
  // The line has to name what was lost, or it isn't worth logging: a capture missing an
  // arm of a thread is only diagnosable if the dropped id is in the log.
  assert.match(lines[0], /forked under 1/);
  assert.match(lines[0], /300/);
});

test("selfThreadChain: an unforked thread logs nothing", () => {
  const body = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  const lines = [];
  selfThreadChain(body, "1", { log: (...parts) => lines.push(parts.join(" ")) });
  assert.deepEqual(lines, []);
});

test("selfThreadChain: a big conversation resolves without a per-step rescan ([090] 15A)", () => {
  // The shape the parent→children index exists for: one author's long thread buried in a
  // conversation full of other people's replies to the head. The old per-descendant
  // filter re-scanned all of these at every step.
  const chain = [tweet({ id: "1000", text: "head" })];
  for (let i = 1; i < 60; i += 1) {
    chain.push(tweet({ id: String(1000 + i), text: `part ${i}`, replyTo: String(999 + i) }));
  }
  for (let i = 0; i < 400; i += 1) {
    chain.push(tweet({ id: `9${i}`, author: `stranger${i}`, text: "nice", replyTo: "1000" }));
  }
  const walked = selfThreadChain(conversation(chain), "1030");
  assert.equal(walked.length, 60, "the author's whole spine, none of the audience");
  assert.deepEqual(walked.map((t) => t.rest_id).slice(0, 3), ["1000", "1001", "1002"]);
  assert.equal(walked.at(-1).rest_id, "1059");
});

test("selfThreadChain: a lone tweet is a chain of one; a missing focal tweet is empty", () => {
  assert.deepEqual(selfThreadChain(conversation([tweet({ id: "1" })]), "1").length, 1);
  // Protected / withheld conversation → the caller saves the tweet unexpanded.
  assert.deepEqual(selfThreadChain(conversation([tweet({ id: "1" })]), "404"), []);
  assert.deepEqual(selfThreadChain({}, "1"), []);
});

// MARK: - the expansion predicate

test("needsThreadExpansion: a reply is certain; a root only under probeRoots", () => {
  const reply = tweet({ id: "2", replyTo: "1" });
  const root = tweet({ id: "1", replyCount: 3 });
  const lonely = tweet({ id: "1", replyCount: 0 });

  assert.equal(needsThreadExpansion(reply), true);          // mid-thread by construction
  assert.equal(needsThreadExpansion(root), false);          // not knowable → no request spent
  assert.equal(needsThreadExpansion(root, { probeRoots: true }), true);
  // Even when probing, a root nobody replied to cannot have a continuation.
  assert.equal(needsThreadExpansion(lonely, { probeRoots: true }), false);
});

test("needsThreadExpansion: a self_thread marker counts even without a parent id", () => {
  const marked = tweet({ id: "5" });
  marked.legacy.self_thread = { id_str: "100" };
  assert.equal(needsThreadExpansion(marked), true);
});

// MARK: - chain → items

test("mapThread: the whole thread shares the HEAD's permalink and one running index", () => {
  const items = mapThread([
    tweet({ id: "1", text: "one", media: [photo("a"), photo("b")] }),
    tweet({ id: "2", text: "two", replyTo: "1", media: [photo("c")] }),
    tweet({ id: "3", text: "three", replyTo: "2" }),               // text-only → a card
  ], { host: "x.com" });

  assert.equal(items.length, 4);                                    // 2 photos + 1 photo + 1 card
  // ONE permalink across the thread — the grouping key that collapses it to a single tile.
  const permalinks = new Set(items.map((i) => i.provenance.originalURL));
  assert.deepEqual([...permalinks], ["https://x.com/author/status/1"]);
  // The index runs CONTINUOUSLY, so the tile opens in the order the thread was written
  // rather than restarting at 0 on each tweet.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1, 2, 3]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.threadIndex), [0, 0, 1, 2]);
  // Each tweet stays individually identifiable under the shared permalink.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.tweetId), ["1", "1", "2", "3"]);
  for (const item of items) assert.equal(item.provenance.rawMetadata.threadId, "1");
  // Per-media dedup keys survive the re-stamp — a collision would make the engine
  // skip every sibling as already-seen.
  assert.equal(new Set(items.map((i) => i.sourceId)).size, 4);
});

test("mapThread: an empty chain maps to nothing", () => {
  assert.deepEqual(mapThread([]), []);
  assert.deepEqual(mapThread(null), []);
});

