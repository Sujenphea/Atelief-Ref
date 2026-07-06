// Atelier Capture — SW bulk message handler tests (Phase 6).
//
// handleBulkMessage is the pure dispatcher: every collaborator injected, so the
// open/known/relay/complete matrix is asserted with no chrome.* and no network.

import { test } from "node:test";
import assert from "node:assert/strict";

import { handleBulkMessage } from "../src/bulk-sw.js";
import { BULK } from "../src/bulk-messages.js";

function deps(over = {}) {
  const calls = {};
  return {
    token: "TOK",
    fetchImpl: async () => ({}),
    openJob: async (spec, opts) => { calls.open = { spec, opts }; return { jobId: "J", caps: null }; },
    fetchKnownSources: async (id, opts) => { calls.known = { id, opts }; return ["s1"]; },
    ingestOne: async (prov, opts) => { calls.relay = { prov, opts }; return { status: "saved", deduplicated: false }; },
    completeJob: async (id, status, opts) => { calls.complete = { id, status, opts }; return true; },
    calls,
    ...over,
  };
}

test("open: forwards platform + token to openJob", async () => {
  const d = deps();
  const result = await handleBulkMessage(
    { type: BULK.open, platform: "pinterest", scope: "b", totalEstimate: 5 }, d);
  assert.deepEqual(result, { jobId: "J", caps: null });
  assert.deepEqual(d.calls.open.spec,
    { platform: "pinterest", scope: "b", totalEstimate: 5, resumeJobId: undefined });
  assert.equal(d.calls.open.opts.token, "TOK");
});

test("open: forwards resumeJobId when present (task-8 same-job resume)", async () => {
  const d = deps();
  await handleBulkMessage(
    { type: BULK.open, platform: "pinterest", scope: "b", totalEstimate: 5, resumeJobId: "JOB-prev" }, d);
  assert.equal(d.calls.open.spec.resumeJobId, "JOB-prev");
});

test("known: returns the sourceIds from fetchKnownSources", async () => {
  const d = deps();
  assert.deepEqual(await handleBulkMessage({ type: BULK.known, jobId: "J" }, d), ["s1"]);
  assert.equal(d.calls.known.id, "J");
});

test("relay: runs ingestOne with token + jobId/sourceId, defaults mp4Url null", async () => {
  const d = deps();
  const prov = { platform: "pinterest", mediaUrl: "u", rawMetadata: {} };
  const result = await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "pin-9" }, d);
  assert.deepEqual(result, { status: "saved", deduplicated: false });
  assert.equal(d.calls.relay.prov, prov);
  assert.deepEqual(d.calls.relay.opts, { token: "TOK", mp4Url: null, jobId: "J", sourceId: "pin-9" });
});

test("relay: passes a resolved mp4Url through when present (opt-in video)", async () => {
  const d = deps();
  await handleBulkMessage(
    { type: BULK.relay, provenance: {}, jobId: "J", sourceId: "t-1", mp4Url: "https://v/x.mp4" }, d);
  assert.equal(d.calls.relay.opts.mp4Url, "https://v/x.mp4");
});

test("complete: forwards the status (defaults to complete)", async () => {
  const d = deps();
  await handleBulkMessage({ type: BULK.complete, jobId: "J", status: "halted" }, d);
  assert.equal(d.calls.complete.status, "halted");
  await handleBulkMessage({ type: BULK.complete, jobId: "J" }, d);
  assert.equal(d.calls.complete.status, "complete");
});

test("an unknown bulk type throws", async () => {
  await assert.rejects(() => handleBulkMessage({ type: "atelier-bulk-nope" }, deps()), /unknown bulk message/);
});
