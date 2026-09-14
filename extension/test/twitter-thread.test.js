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
/** The author's screen name, read the way the walk reads it. */
const screenNameOf = (t) => t?.core?.user_results?.result?.core?.screen_name
  || t?.core?.user_results?.result?.legacy?.screen_name || null;

/** The thread in that capture, DERIVED and not pinned: the longest self-chain in the body,
 * which is what `checkThread` does when no focal tweet is named and what the app does when
 * a bookmark lands mid-thread.
 *
 * This file used to open with a hardcoded head id and a five-id spine, both copied out of a
 * hand-written fixture. Re-capturing the conversation (498) invalidated every one of them
 * and six tests went red without a single rule having changed — which is the tell that the
 * constants were pinning THE FIXTURE rather than the walk. Nothing below names an id, a
 * handle, a tweet count or a chain length; each test states the relationship it cares
 * about and lets the capture supply the numbers. */
const LIVE_TWEETS = collectConversationTweets(live);
const LIVE_CHAIN = LIVE_TWEETS.reduce((longest, t) => {
  const walked = selfThreadChain(live, t.rest_id);
  return walked.length > longest.length ? walked : longest;
}, []);
const LIVE_SPINE = LIVE_CHAIN.map((t) => t.rest_id);
const LIVE_HEAD = LIVE_SPINE[0];
const LIVE_AUTHOR = screenNameOf(LIVE_CHAIN[0]);

// MARK: - against the LIVE capture (the shapes X actually serves)

test("live: the conversation walk finds every tweet, across both entry shapes", () => {
  // The expected SET is derived from the body by a dumb recursive scan for
  // `tweet_results.result`, independent of the walk under test — so this compares two
  // readings of the same capture instead of comparing the walk to a number somebody typed.
  const scanned = new Set();
  (function scan(node) {
    if (Array.isArray(node)) return node.forEach(scan);
    if (!node || typeof node !== "object") return;
    const result = node.tweet_results && node.tweet_results.result;
    if (result && result.rest_id) scanned.add(result.rest_id);
    Object.values(node).forEach(scan);
  })(live);

  assert.ok(scanned.size > 1, "the capture has a conversation in it at all");
  assert.deepEqual(new Set(LIVE_TWEETS.map((t) => t.rest_id)), scanned);
  assert.equal(LIVE_TWEETS.length, scanned.size, "no tweet counted twice");

  // The focal tweet arrives as a bare TimelineTimelineItem and the continuations inside a
  // conversationthread MODULE; a generic walk is what survives either moving alone. Both
  // shapes must actually be PRESENT here, or this capture is not exercising the claim.
  const bare = new Set();
  const inModule = new Set();
  for (const instruction of live.data.threaded_conversation_with_injections_v2.instructions) {
    for (const entry of instruction.entries || []) {
      const content = entry.content || {};
      const direct = content.itemContent?.tweet_results?.result;
      if (direct?.rest_id) bare.add(direct.rest_id);
      for (const item of content.items || []) {
        const nested = item.item?.itemContent?.tweet_results?.result;
        if (nested?.rest_id) inModule.add(nested.rest_id);
      }
    }
  }
  assert.ok(bare.size > 0, "no tweet arrived as a bare entry");
  assert.ok(inModule.size > 0, "no tweet arrived inside a module");
  assert.deepEqual(new Set([...bare, ...inModule]), scanned);
});

test("live: from the HEAD, the chain is the author's own thread and stops there", () => {
  assert.ok(LIVE_SPINE.length >= 2, "the capture contains a threaded conversation");
  assert.deepEqual(selfThreadChain(live, LIVE_HEAD).map((t) => t.rest_id), LIVE_SPINE);
  // "The author's own, and stops there": one author across the chain, each link replying
  // to the one before it, and the head replying to nothing in the chain.
  assert.deepEqual([...new Set(LIVE_CHAIN.map(screenNameOf))], [LIVE_AUTHOR]);
  assert.deepEqual(LIVE_CHAIN.slice(1).map((t) => t.legacy.in_reply_to_status_id_str),
    LIVE_SPINE.slice(0, -1));
  assert.equal(LIVE_SPINE.includes(LIVE_CHAIN[0].legacy.in_reply_to_status_id_str), false);
  // Nothing else in the conversation continues it: no tweet outside the chain replies to
  // its LAST link, which is what "stops there" means.
  const tail = LIVE_SPINE[LIVE_SPINE.length - 1];
  const continuations = LIVE_TWEETS.filter((t) => t.legacy?.in_reply_to_status_id_str === tail
    && screenNameOf(t) === LIVE_AUTHOR);
  assert.deepEqual(continuations, []);
});

test("live: from a MID-thread tweet, the chain walks up to the head and back down", () => {
  // Bookmarking any link must still save the whole thread, in reading order — the case the
  // whole feature exists for. Asserted from EVERY link rather than from a chosen one, so it
  // holds however long the next capture's thread turns out to be.
  for (const id of LIVE_SPINE) {
    assert.deepEqual(selfThreadChain(live, id).map((t) => t.rest_id), LIVE_SPINE,
      `walking from ${id} did not recover the whole thread`);
  }
});

test("live: the author's replies TO COMMENTERS stay out of the thread", () => {
  // The trap that a plain author+conversation filter would fall into, proven on real data:
  // this capture has tweets by the thread's own author that are NOT part of the thread.
  const chain = selfThreadChain(live, LIVE_HEAD);
  const allByAuthor = LIVE_TWEETS.filter((t) => screenNameOf(t) === LIVE_AUTHOR);
  const inChain = new Set(chain.map((t) => t.rest_id));
  const excluded = allByAuthor.filter((t) => !inChain.has(t.rest_id));

  assert.ok(LIVE_AUTHOR, "the chain's author is readable");
  // The filter has to be DOING something here, or the test passes on a capture that could
  // never have caught the bug. That is the load-bearing claim, not the count itself.
  assert.ok(excluded.length > 0,
    "this capture has no author-replies-to-commenters, so it cannot prove they are excluded");
  assert.equal(chain.length, allByAuthor.length - excluded.length);
  // Each excluded one replies to somebody else's tweet — that is what disqualifies it.
  const spine = new Set(LIVE_SPINE);
  for (const t of excluded) {
    assert.equal(spine.has(t.legacy.in_reply_to_status_id_str), false,
      `${t.rest_id} replies into the thread's spine and should not have been dropped`);
  }
});

test("live: the thread maps to ONE post — shared permalink, contiguous open order", () => {
  assert.ok(LIVE_SPINE.length >= 2, "a one-tweet 'thread' groups trivially and proves nothing");
  const items = mapThread(selfThreadChain(live, LIVE_HEAD), { host: "x.com" });
  assert.ok(items.length >= LIVE_SPINE.length, "every tweet in the thread produced an item");
  assert.deepEqual([...new Set(items.map((i) => i.provenance.originalURL))],
    [`https://x.com/${LIVE_AUTHOR}/status/${LIVE_HEAD}`]);
  // Contiguous from zero, however many media the thread turns out to carry.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex),
    items.map((_, index) => index));
  // threadIndex is the POSITION IN THE CHAIN, so it is non-decreasing, starts at 0, ends at
  // the last link, and every link appears — a tweet's several media share one index.
  const threadIndices = items.map((i) => i.provenance.rawMetadata.threadIndex);
  assert.deepEqual([...threadIndices].sort((a, b) => a - b), threadIndices);
  assert.deepEqual([...new Set(threadIndices)], LIVE_SPINE.map((_, index) => index));
  for (const item of items) assert.equal(item.provenance.rawMetadata.threadId, LIVE_HEAD);
  // Per-media dedup keys must stay distinct or the engine skips siblings as already-seen.
  assert.equal(new Set(items.map((i) => i.sourceId)).size, items.length);
  // These items ARE the expansion; a surviving hint would re-expand them every sweep.
  for (const item of items) assert.equal("threadHint" in item, false);
});

test("live: each tweet stays a TWEET, and the thread still forms one carousel", () => {
  // The shape the app needs, on the real capture: every tweet keeps its own identity
  // (its own id, its own text) so nothing dedups away, while all eight items still
  // group as a single post.
  const items = mapThread(selfThreadChain(live, LIVE_HEAD), { host: "x.com" });

  // ONE descriptor per TWEET, not per item. A tweet capture dedups on `(kind, tweetID)`,
  // so two items claiming one tweet id would collapse and the second's photo would be
  // deleted as an orphan blob.
  const described = items.filter((item) => item.content);
  assert.deepEqual(described.map((item) => item.content.payload.tweet.tweetID), LIVE_SPINE);
  assert.equal(new Set(described.map((i) => i.content.payload.tweet.tweetID)).size,
    LIVE_SPINE.length, "every descriptor claims a DIFFERENT tweet id");

  // Each descriptor carries that tweet's own words, not the head's. The TEXTS themselves
  // are synthetic — the sweep replaces every one — so what is asserted is that they are
  // distinct and that each descriptor's text is the text of the tweet it names, read
  // straight off the chain.
  const texts = described.map((item) => item.content.payload.tweet.text);
  assert.equal(new Set(texts).size, LIVE_SPINE.length, "each tweet keeps its own text");
  // Long-form body first, `legacy.full_text` only as the fallback — a >280-char tweet's
  // `full_text` is TRUNCATED, so reading it would silently cut three of this thread's four
  // tweets short. Three of them carry a `note_tweet` whose text differs from their
  // `full_text`, so the precedence is genuinely exercised here and not merely restated.
  const longForm = (t) => t?.note_tweet?.note_tweet_results?.result?.text || null;
  assert.deepEqual(texts, LIVE_CHAIN.map((t) => longForm(t) || t.legacy.full_text));
  assert.ok(LIVE_CHAIN.some((t) => longForm(t) && longForm(t) !== t.legacy.full_text),
    "no tweet in this chain has a long-form body, so the fallback order is untested");

  // Each tweet's descriptor lists that tweet's WHOLE media run, and the rest of its items
  // stay plain images. This is the head-carries-four-photos claim stated per tweet, so it
  // survives a capture whose thread is shaped differently.
  const byThreadIndex = new Map();
  for (const item of items) {
    const index = item.provenance.rawMetadata.threadIndex;
    if (!byThreadIndex.has(index)) byThreadIndex.set(index, []);
    byThreadIndex.get(index).push(item);
  }
  for (const [index, group] of byThreadIndex) {
    assert.ok(group[0].content, `tweet ${index} has no descriptor on its first item`);
    assert.deepEqual(group.slice(1).map((i) => i.content),
      group.slice(1).map(() => undefined), `tweet ${index} describes more than its first item`);
    assert.equal(group[0].content.payload.tweet.media.length,
      group.filter((i) => i.mediaUrl).length, `tweet ${index} lists the wrong media count`);
  }

  // …and every item still groups as ONE post, under the thread's permalink, regardless of
  // what ingest does to each tweet's originalURL for identity.
  const groupKeys = new Set(items.map((i) => i.provenance.rawMetadata.postGroupKey));
  assert.deepEqual([...groupKeys], [`https://x.com/${LIVE_AUTHOR}/status/${LIVE_HEAD}`]);
});

test("live: a swept tweet from this thread is recognised as worth expanding", () => {
  const part2 = LIVE_TWEETS.find((t) => t.rest_id === LIVE_SPINE[1]);
  const head = LIVE_TWEETS.find((t) => t.rest_id === LIVE_HEAD);
  assert.equal(needsThreadExpansion(part2), true, "a reply is mid-thread by construction");
  // The head names no parent, so it is only reachable by probing — which is why
  // probeRoots is on in production.
  assert.equal(needsThreadExpansion(head), false);
  // …and probing cannot fire on THIS body, which is a fact about the fixture rather than
  // about the rule: `probeRoots` reads `legacy.reply_count`, and the sanitizer zeroes every
  // `*_count` by key on the way in, deliberately (engagement numbers are not ours to
  // ship). So a live capture can never answer the probeRoots half, and pinning `false`
  // here says so out loud instead of leaving a silent gap — the rule itself is covered on
  // synthetic bodies below, where a reply_count can be set to 3 and to 0.
  assert.equal(head.legacy.reply_count, 0, "the sweep zeroed the count probeRoots reads");
  assert.equal(needsThreadExpansion(head, { probeRoots: true }), false);
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

