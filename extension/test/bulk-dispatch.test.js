// Atelier Capture — sweep dispatch tests (send + cold-tab recovery).
//
// The branchy bit the popup can't unit-test with real chrome.*: happy send, the
// resolved-error reply (returned, not retried), and the inject→retry recovery when a
// tab has no content script. Fakes for sendMessage/injectScript/sleep.

import { test } from "node:test";
import assert from "node:assert/strict";

import { dispatchStart } from "../src/bulk-dispatch.js";
import { START } from "../src/bulk-messages.js";

const SPEC = { platform: "twitter", input: {}, scope: "bookmarks", resolveVideo: false };
const noSleep = async () => {};

/** A sendMessage that rejects for the first `failFirst` calls, then resolves `reply`.
 * Records the messages it received. */
function fakeSend(failFirst, reply) {
  const calls = [];
  const send = async (message) => {
    calls.push(message);
    if (calls.length <= failFirst) throw new Error("Could not establish connection. Receiving end does not exist.");
    return reply;
  };
  return { send, calls };
}

test("happy path: send succeeds, no injection, returns the reply", async () => {
  const { send, calls } = fakeSend(0, { ok: true, result: { status: "complete" } });
  let injected = 0;
  const reply = await dispatchStart({
    spec: SPEC, sendMessage: send, injectScript: async () => { injected += 1; }, sleep: noSleep,
  });
  assert.deepEqual(reply, { ok: true, result: { status: "complete" } });
  assert.equal(injected, 0, "must not inject when the first send works");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].type, START, "sends the START message");
  assert.deepEqual(calls[0], {
    type: START, platform: "twitter", input: {}, scope: "bookmarks",
    resolveVideo: false, expandNotes: undefined,
  });
});

test("a resolved error reply is returned as-is (not a transport failure → no retry)", async () => {
  const { send, calls } = fakeSend(0, { ok: false, error: "job open failed" });
  let injected = 0;
  const reply = await dispatchStart({
    spec: SPEC, sendMessage: send, injectScript: async () => { injected += 1; }, sleep: noSleep,
  });
  assert.deepEqual(reply, { ok: false, error: "job open failed" });
  assert.equal(injected, 0);
  assert.equal(calls.length, 1, "an ok:false reply is not retried");
});

test("cold tab: first send throws → inject once → retry succeeds", async () => {
  const { send, calls } = fakeSend(1, { ok: true, result: { status: "complete" } });
  let injected = 0;
  const reply = await dispatchStart({
    spec: SPEC, sendMessage: send, injectScript: async () => { injected += 1; }, sleep: noSleep,
  });
  assert.deepEqual(reply, { ok: true, result: { status: "complete" } });
  assert.equal(injected, 1, "injects exactly once");
  assert.equal(calls.length, 2, "one failed send + one successful retry");
});

test("cold tab: listener slow to register → several rejects then success", async () => {
  const { send, calls } = fakeSend(4, { ok: true, result: {} }); // 1 initial + 3 retry rejects, then ok
  const reply = await dispatchStart({
    spec: SPEC, sendMessage: send, injectScript: async () => {}, sleep: noSleep, retries: 6,
  });
  assert.equal(reply.ok, true);
  assert.equal(calls.length, 5);
});

test("stays unreachable after injecting → throws (retries exhausted)", async () => {
  const { send, calls } = fakeSend(99, { ok: true }); // never succeeds
  await assert.rejects(
    () => dispatchStart({ spec: SPEC, sendMessage: send, injectScript: async () => {}, sleep: noSleep, retries: 3 }),
    /unreachable after injecting/);
  assert.equal(calls.length, 4, "1 initial + 3 retries");
});

test("injection itself failing → throws a clear inject error", async () => {
  const { send } = fakeSend(1, { ok: true });
  await assert.rejects(
    () => dispatchStart({
      spec: SPEC, sendMessage: send,
      injectScript: async () => { throw new Error("Cannot access chrome:// URL"); }, sleep: noSleep,
    }),
    /couldn't inject the sweep controller: Cannot access chrome:\/\/ URL/);
});
