// Atelier Capture — drift-check invariant tests (Phase 8, [T12]).
//
// The committed fixtures MUST pass every check (that's the baseline). Deliberately
// mutated inputs MUST be flagged with a specific problem — proving the canary
// actually catches a shape change rather than rubber-stamping.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { checkTimeline, checkBoardFeed, checkBoards, CHECKS } from "../src/drift.js";

const load = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));
const bookmarks = load("x-bookmarks.json");
const boardFeed = load("pinterest-boardfeed.json");
const boards = load("pinterest-boards.json");

// MARK: - the committed fixtures are the passing baseline

test("checkTimeline passes on the committed X fixture with real signals", () => {
  const result = checkTimeline(bookmarks);
  assert.equal(result.ok, true);
  assert.equal(result.problems.length, 0);
  assert.equal(result.signals.tweetCount, 3);
  assert.equal(result.signals.mediaItems, 4);
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

test("a completely foreign payload is flagged, not thrown", () => {
  assert.equal(checkTimeline({ hello: "world" }).ok, false);
  assert.equal(checkBoardFeed({ hello: "world" }).ok, false);
  assert.equal(checkBoards({ hello: "world" }).ok, false);
});

test("CHECKS registry wires each check to a --flag", () => {
  assert.deepEqual(Object.keys(CHECKS).sort(), ["pinterest-board", "pinterest-boards", "x"]);
  assert.equal(CHECKS.x.run, checkTimeline);
});
