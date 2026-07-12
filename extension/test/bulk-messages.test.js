// Atelier Capture — bulk message contract tests.
//
// The START message has two producers (the popup + any console/agent launch) and one
// consumer (the controller). buildStartMessage/readStartMessage own its shape in one
// place; this round-trip pins that contract so a field rename can't silently desync
// the popup from the controller.

import { test } from "node:test";
import assert from "node:assert/strict";

import { START, buildStartMessage, readStartMessage, isBulkMessage, BULK } from "../src/bulk-messages.js";

test("START is the literal external launchers/console use", () => {
  assert.equal(START, "atelier-bulk-start");
});

test("buildStartMessage tags the type and carries the spec fields", () => {
  const spec = { platform: "pinterest", input: { boardId: "7", boardUrl: "/u/b/" }, scope: "board:b", resolveVideo: true };
  assert.deepEqual(buildStartMessage(spec), {
    type: START, platform: "pinterest", input: { boardId: "7", boardUrl: "/u/b/" }, scope: "board:b", resolveVideo: true,
  });
});

test("round-trip: readStartMessage(buildStartMessage(spec)) === spec", () => {
  for (const spec of [
    { platform: "twitter", input: {}, scope: "bookmarks", resolveVideo: false },
    { platform: "pinterest", input: { boardId: "1", boardUrl: "/a/b/" }, scope: "board:b", resolveVideo: true },
  ]) {
    assert.deepEqual(readStartMessage(buildStartMessage(spec)), spec);
  }
});

test("the START message is NOT a bulk (open/known/relay/complete) message", () => {
  // isBulkMessage gates the SW's localhost relay; a START goes to the content script,
  // so it must not be mistaken for a relay op.
  assert.equal(isBulkMessage(buildStartMessage({ platform: "twitter", input: {}, scope: "bookmarks" })), false);
  assert.equal(isBulkMessage({ type: BULK.open }), true);
});
