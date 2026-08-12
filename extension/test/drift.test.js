// Atelier Capture — drift-check invariant tests (Phase 8, [T12]).
//
// The committed fixtures MUST pass every check (that's the baseline). Deliberately
// mutated inputs MUST be flagged with a specific problem — proving the canary
// actually catches a shape change rather than rubber-stamping.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  checkTimeline, checkBoardFeed, checkBoards, checkInstagramSaved, CHECKS, fixtureStaleReminder,
} from "../src/drift.js";

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
  assert.ok(result.problems.some((p) => /no pin mapped/.test(p)));
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
    ["instagram", "pinterest-board", "pinterest-boards", "x"]);
  assert.equal(CHECKS.x.run, checkTimeline);
  assert.equal(CHECKS.instagram.run, checkInstagramSaved);
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
