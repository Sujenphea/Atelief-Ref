// Atelier Capture — X conversation → the author's own chain (the PURE half, [090] 2A).
//
// Everything here is a total function over a JSON body: the conversation walk, the
// fork/foreign-author rules that keep someone else's discussion out of your capture, and
// the re-stamping that makes a thread group as one post. No network, no browser. The
// request side lives in twitter-detail-client.test.js.
//
// The bodies are synthetic (test/fixtures/x-conversation.js) — deliberately, for the
// branch shapes a real capture won't contain. What proves the parser against the LIVE
// endpoint is the committed capture + `checkThreadDetail` ([090] 1A), not these.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  collectConversationTweets, selfThreadChain, needsThreadExpansion, mapThread,
} from "../src/twitter-thread.js";
import { tweet, photo, conversation } from "./fixtures/x-conversation.js";

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

