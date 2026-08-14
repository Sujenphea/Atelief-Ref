// Atelier Capture — drift-check invariant tests (Phase 8, [T12]).
//
// The committed fixtures MUST pass every check (that's the baseline). Deliberately
// mutated inputs MUST be flagged with a specific problem — proving the canary
// actually catches a shape change rather than rubber-stamping.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  checkTimeline, checkBoardFeed, checkBoards, checkInstagramSaved, checkThreadDetail,
  CHECKS, fixtureStaleReminder,
} from "../src/drift.js";
import { tweet, conversation } from "./fixtures/x-conversation.js";

const load = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));
const bookmarks = load("x-bookmarks.json");
const boardFeed = load("pinterest-boardfeed.json");
const boards = load("pinterest-boards.json");
const igSaved = load("instagram-saved.json");

// MARK: - the committed fixtures are the passing baseline

test("checkTimeline passes on the committed X fixture with real signals", () => {
  const result = checkTimeline(bookmarks);
  assert.equal(result.ok, true);
  assert.equal(result.problems.length, 0);
  assert.equal(result.signals.tweetCount, 3);
  // 8 = the video tweet (1) + the photo tweet's own 3 AND the 3 it quotes + the
  // bare quote's borrowed video (1). Quoted media are merged in, not just borrowed
  // as a fallback, so this count moved from 5 when that rule changed.
  assert.equal(result.signals.mediaItems, 8);
  assert.equal(result.signals.hasCursor, true);
});

test("checkBoardFeed passes on the committed Pinterest board fixture", () => {
  const result = checkBoardFeed(boardFeed);
  assert.equal(result.ok, true);
  assert.equal(result.signals.pins, 1);
  assert.equal(result.signals.mapped, 1);
  assert.equal(result.signals.hasBookmark, true);
});

test("checkBoards passes on the committed Pinterest boards fixture", () => {
  const result = checkBoards(boards);
  assert.equal(result.ok, true);
  assert.equal(result.signals.boards, 1);
});

test("checkInstagramSaved passes on the committed IG fixture with real signals", () => {
  const result = checkInstagramSaved(igSaved);
  assert.equal(result.ok, true, JSON.stringify(result.problems));
  assert.equal(result.problems.length, 0);
  assert.equal(result.signals.posts, 3);        // image + reel + carousel
  assert.ok(result.signals.items > 3, "fan-out yields more items than posts (the carousel)");
  assert.ok(result.signals.videos >= 1, "the reel exposes a videoUrl");
  assert.equal(result.signals.endOfFeed, true); // fixture is a terminal page
});

// MARK: - drift is actually caught

test("checkTimeline flags a shape with no tweet entries", () => {
  const empty = { data: { bookmark_timeline_v2: { timeline: { instructions: [] } } } };
  const result = checkTimeline(empty);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /no tweet entries/.test(p)));
});

test("checkTimeline flags a missing pagination cursor", () => {
  // Tweets present but the Bottom cursor entry removed → pagination would stall.
  const noCursor = JSON.parse(JSON.stringify(bookmarks));
  const entries = noCursor.data.bookmark_timeline_v2.timeline.instructions[0].entries;
  noCursor.data.bookmark_timeline_v2.timeline.instructions[0].entries =
    entries.filter((e) => e.content?.entryType !== "TimelineTimelineCursor");
  const result = checkTimeline(noCursor);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /Bottom cursor/.test(p)));
});

test("checkBoardFeed flags pins that no longer map (images shape moved)", () => {
  const drifted = JSON.parse(JSON.stringify(boardFeed));
  for (const pin of drifted.resource_response.data) delete pin.images; // image shape gone
  const result = checkBoardFeed(drifted);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /failed to map/.test(p)));
});

// The invariant that matters: PARTIAL breakage. The old bound was `mapped >= 1`, so a
// page where all but one pin stopped mapping still passed — reading as a small board
// rather than as drift. Nine of ten here, which the old rule called healthy.
test("checkBoardFeed flags a PARTIAL mapping failure, not just a total one", () => {
  const drifted = JSON.parse(JSON.stringify(boardFeed));
  const pin = drifted.resource_response.data[0];
  const healthy = JSON.parse(JSON.stringify(pin));
  const broken = JSON.parse(JSON.stringify(pin));
  delete broken.images;
  drifted.resource_response.data = [healthy, ...Array.from({ length: 9 }, (_, i) => ({
    ...JSON.parse(JSON.stringify(broken)), id: `900000000000000${i}`,
  }))];
  const result = checkBoardFeed(drifted);
  assert.equal(result.signals.mapped, 1, "exactly one pin still maps");
  assert.equal(result.ok, false, "9 of 10 pins failing must be drift, not a small board");
  assert.ok(result.problems.some((p) => /9 of 10 pin entries/.test(p)));
});

// ...but a non-pin module is NOT a mapping failure. Pinterest interleaves them into
// data[], so they leave the denominator rather than counting against it.
test("checkBoardFeed does not count interleaved non-pin modules as failures", () => {
  const withModule = JSON.parse(JSON.stringify(boardFeed));
  withModule.resource_response.data.push({
    id: "w5gBtXUx", type: "story", story_type: "related_interests_module", title: "More ideas",
  });
  const result = checkBoardFeed(withModule);
  assert.equal(result.ok, true, "a story card is not a broken pin");
  assert.equal(result.signals.modules, 1);
  assert.equal(result.signals.pinEntries, result.signals.mapped);
});

test("checkTimeline flags tweets that map to no item at all", () => {
  const drifted = JSON.parse(JSON.stringify(bookmarks));
  const entries = drifted.data.bookmark_timeline_v2.timeline.instructions
    .find((i) => i.type === "TimelineAddEntries").entries;
  // Strip the id from every tweet but the first. `unwrapTweet` still succeeds, so the
  // entry COUNTS as a tweet — but `mapTweet` bails at `if (!tweetId) return []`, so it
  // yields nothing. That asymmetry is the whole point: deleting `tweet_results` instead
  // would drop the entry from `tweetCount` too, and the ratio would stay equal.
  // Old rule: items.length >= 1, so this passed.
  let seen = 0;
  for (const entry of entries) {
    const result = entry.content?.itemContent?.tweet_results?.result;
    if (!result) continue;
    if (seen++ === 0) continue;
    const tweet = result.tweet || result;
    delete tweet.rest_id;
    if (tweet.legacy) delete tweet.legacy.id_str;
  }
  const result = checkTimeline(drifted);
  assert.ok(result.signals.mappedTweets < result.signals.tweetCount);
  assert.equal(result.ok, false, "tweets silently dropped must be drift");
  assert.ok(result.problems.some((p) => /mapped to no item/.test(p)));
});

test("checkBoardFeed flags a missing bookmark cursor", () => {
  const drifted = JSON.parse(JSON.stringify(boardFeed));
  delete drifted.resource_response.bookmark;
  const result = checkBoardFeed(drifted);
  assert.ok(result.problems.some((p) => /bookmark cursor/.test(p)));
});

test("checkInstagramSaved flags a broken carousel fan-out (child walk moved)", () => {
  const drifted = JSON.parse(JSON.stringify(igSaved));
  // Simulate IG renaming/removing the `carousel_media` array the parser walks, while its
  // declared `carousel_media_count` still says N children → the parser produces 1 (the
  // cover) but the count expects N, so the fan-out mismatch is caught.
  for (const wrapper of drifted.items) {
    if (wrapper.media.carousel_media) delete wrapper.media.carousel_media;
  }
  const result = checkInstagramSaved(drifted);
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /fan-out count/.test(p)));
});

test("checkInstagramSaved flags a challenge body (recognizer + no items)", () => {
  const result = checkInstagramSaved({ message: "checkpoint_required", status: "fail" });
  assert.equal(result.ok, false);
  assert.ok(result.problems.some((p) => /challenge recognizer misfired/.test(p)));
});

test("checkInstagramSaved flags items that no longer carry an image (image_versions2 moved)", () => {
  const drifted = JSON.parse(JSON.stringify(igSaved));
  for (const wrapper of drifted.items) {
    delete wrapper.media.image_versions2;
    if (wrapper.media.carousel_media) for (const c of wrapper.media.carousel_media) delete c.image_versions2;
  }
  const result = checkInstagramSaved(drifted);
  assert.equal(result.ok, false);
  // With no images nothing maps → the "no items mapped" invariant trips.
  assert.ok(result.problems.some((p) => /no items mapped|fan-out count/.test(p)));
});

test("a completely foreign payload is flagged, not thrown", () => {
  assert.equal(checkTimeline({ hello: "world" }).ok, false);
  assert.equal(checkBoardFeed({ hello: "world" }).ok, false);
  assert.equal(checkBoards({ hello: "world" }).ok, false);
  assert.equal(checkInstagramSaved({ hello: "world" }).ok, true); // no items → vacuously fine (endOfFeed)
});

test("CHECKS registry wires each check to a --flag", () => {
  assert.deepEqual(Object.keys(CHECKS).sort(),
    ["instagram", "pinterest-board", "pinterest-boards", "x", "x-thread"]);
  assert.equal(CHECKS.x.run, checkTimeline);
  assert.equal(CHECKS.instagram.run, checkInstagramSaved);
  assert.equal(CHECKS["x-thread"].run, checkThreadDetail);
});

// MARK: - checkThreadDetail ([090] 1A)
//
// The check itself is exercised here against a synthetic conversation. That proves the
// INVARIANTS are right; it does NOT prove the parser matches X, which is the whole reason
// the check exists — that needs the live capture the CLI reports as awaited. These tests
// are the half that can be written today.

/** A 3-tweet self-thread with an outsider's reply mixed in, as a real one would have. */
const threadBody = () => conversation([
  tweet({ id: "500", text: "one" }),
  tweet({ id: "501", text: "two", replyTo: "500" }),
  tweet({ id: "502", text: "three", replyTo: "501" }),
  tweet({ id: "900", author: "stranger", text: "great thread", replyTo: "500" }),
]);

test("checkThreadDetail passes on a walkable conversation, reporting the chain it found", () => {
  const result = checkThreadDetail(threadBody());
  assert.equal(result.ok, true, result.problems.join("; "));
  assert.equal(result.signals.chain, 3, "the author's spine, not the stranger's reply");
  assert.equal(result.signals.tweets, 4);
  assert.equal(result.signals.items, 3);
});

test("checkThreadDetail finds the thread without being told the focal id", () => {
  // The operator saves a response out of DevTools; digging the focal id out of the
  // request as well is friction that would just stop the check being run.
  const withFocal = checkThreadDetail(threadBody(), { focalTweetId: "501" });
  const without = checkThreadDetail(threadBody());
  assert.deepEqual(without.signals.chain, withFocal.signals.chain);
});

test("checkThreadDetail flags a renamed reply link (the walk's load-bearing field)", () => {
  const body = threadBody();
  for (const t of [
    ...body.data.threaded_conversation_with_injections_v2.instructions[0].entries[1].content.items,
  ]) {
    const legacy = t.item.itemContent.tweet_results.result.legacy;
    legacy.inReplyToStatusId = legacy.in_reply_to_status_id_str;   // X renamed it
    delete legacy.in_reply_to_status_id_str;
  }
  const result = checkThreadDetail(body);
  assert.equal(result.ok, false);
  assert.match(result.problems.join(" "), /in_reply_to_status_id_str/);
});

test("checkThreadDetail flags a conversation whose entries no longer yield tweets", () => {
  const result = checkThreadDetail({ data: { threaded_conversation_with_injections_v2: {
    instructions: [{ type: "TimelineAddEntries", entries: [{ entryId: "tweet-1", content: {} }] }],
  } } });
  assert.equal(result.ok, false);
  assert.match(result.problems.join(" "), /no tweets in the conversation/);
});

test("checkThreadDetail flags a body with no self-thread — the wrong capture to check with", () => {
  // A conversation of one tweet plus strangers' replies. Not drift, but not a check
  // either: the operator captured a non-threaded tweet and must be told so.
  const body = conversation([
    tweet({ id: "500", text: "a lone tweet" }),
    tweet({ id: "900", author: "stranger", text: "nice", replyTo: "500" }),
  ]);
  const result = checkThreadDetail(body);
  assert.equal(result.ok, false);
  assert.match(result.problems.join(" "), /THREADED conversation/);
});

test("checkThreadDetail flags a moved AUTHOR path by name, not as a short chain", () => {
  // The two failures look identical from the outside — both yield a chain of one — and
  // have completely different fixes. A moved author path must say so.
  const body = threadBody();
  const entries = body.data.threaded_conversation_with_injections_v2.instructions[0].entries;
  const results = [
    entries[0].content.itemContent.tweet_results.result,
    ...entries[1].content.items.map((i) => i.item.itemContent.tweet_results.result),
  ];
  for (const result of results) result.core = { user_results: { result: { profile: {} } } };

  const result = checkThreadDetail(body);
  assert.equal(result.ok, false);
  assert.match(result.problems.join(" "), /screen_name moved/);
  assert.equal(result.signals.withAuthor, 0);
});

test("checkThreadDetail reports the grouping contract it verified", () => {
  // A passing run has actually checked the app-facing shape — one permalink for the whole
  // thread and a contiguous open order — not merely that the walk returned something.
  const result = checkThreadDetail(threadBody());
  assert.equal(result.ok, true);
  assert.equal(result.signals.items, result.signals.chain);
  assert.equal(result.signals.withAuthor, 4);
});

test("checkThreadDetail: a foreign payload is flagged, not thrown", () => {
  assert.equal(checkThreadDetail({ hello: "world" }).ok, false);
  assert.equal(checkThreadDetail(null).ok, false);
});

test("fixtureStaleReminder is null inside the window (G18)", () => {
  const baseline = { capturedAt: "2026-07-01", staleAfterDays: 30 };
  const now = Date.parse("2026-07-10T00:00:00Z");
  assert.equal(fixtureStaleReminder(baseline, now), null);
});

test("fixtureStaleReminder returns operator copy when past staleAfterDays", () => {
  const baseline = { capturedAt: "2026-07-01", staleAfterDays: 7 };
  const now = Date.parse("2026-07-20T00:00:00Z");
  const msg = fixtureStaleReminder(baseline, now);
  assert.match(msg, /19d old/);
  assert.match(msg, /npm run drift-check/);
});
