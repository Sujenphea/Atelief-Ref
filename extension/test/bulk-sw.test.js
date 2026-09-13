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
  const prov = { platform: "pinterest", mediaUrl: "https://i.pinimg.com/originals/x.jpg", rawMetadata: {} };
  const result = await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "pin-9" }, d);
  assert.deepEqual(result, { status: "saved", deduplicated: false });
  assert.equal(d.calls.relay.prov, prov);
  // A relay carrying no ladder passes an EMPTY one, not undefined: `planCapture` spreads it
  // and `ingestOne` slices it, so "absent" and "empty" must be the same thing all the way
  // down rather than two shapes one of them happens to tolerate.
  assert.deepEqual(d.calls.relay.opts,
    { token: "TOK", mp4Url: null, videoCandidates: [], content: null,
      jobId: "J", sourceId: "pin-9", caps: null });
});

test("relay: threads a tweet content descriptor to ingestOne (003 · C3 bulk)", async () => {
  const d = deps();
  const prov = { platform: "twitter", mediaUrl: "https://pbs.twimg.com/media/x.jpg", rawMetadata: { tweetId: "1" } };
  const content = { kind: "tweet", payload: { tweet: { tweetID: "1", media: [{ url: "https://pbs.twimg.com/media/x.jpg" }] } } };
  await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "1", content }, d);
  assert.deepEqual(d.calls.relay.opts.content, content); // forwarded verbatim
  // A relay without a descriptor (Pinterest / older client) passes null.
  await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "1" }, d);
  assert.equal(d.calls.relay.opts.content, null);
});

test("relay: a text-only tweet (no media url) passes the SSRF guard and relays content", async () => {
  // No media URL to fetch → the host allowlist has nothing to block, so the media-less
  // tweet still reaches ingestOne with its content descriptor (a text card).
  const d = deps();
  const prov = { platform: "twitter", mediaUrl: null, rawMetadata: { tweetId: "9" } };
  const content = { kind: "tweet", payload: { tweet: { tweetID: "9", media: [], text: "hi" } } };
  const result = await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "9", content }, d);
  assert.deepEqual(result, { status: "saved", deduplicated: false }); // ingestOne ran
  assert.deepEqual(d.calls.relay.opts.content, content);
});

test("relay: passes a resolved mp4Url through when present (opt-in video)", async () => {
  const d = deps();
  const prov = { platform: "twitter", mediaUrl: "https://pbs.twimg.com/media/x.jpg" };
  await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "t-1",
      mp4Url: "https://video.twimg.com/x.mp4" }, d);
  assert.equal(d.calls.relay.opts.mp4Url, "https://video.twimg.com/x.mp4");
});

test("relay: threads the job's server caps to ingestOne (13A)", async () => {
  const d = deps();
  const prov = { platform: "pinterest", mediaUrl: "https://i.pinimg.com/originals/x.jpg" };
  const caps = { maxBodyBytes: 100, maxVideoBodyBytes: 200 };
  await handleBulkMessage({ type: BULK.relay, provenance: prov, jobId: "J", sourceId: "p-1", caps }, d);
  assert.deepEqual(d.calls.relay.opts.caps, caps);
  // A relay without caps passes null (single-item / older client).
  await handleBulkMessage({ type: BULK.relay, provenance: prov, jobId: "J", sourceId: "p-2" }, d);
  assert.equal(d.calls.relay.opts.caps, null);
});

test("relay: refuses an off-allowlist media host (SSRF guard 3A) WITHOUT calling ingestOne", async () => {
  const d = deps();
  const prov = { platform: "pinterest", mediaUrl: "http://127.0.0.1:47321/secret" }; // not a CDN
  const result = await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "pin-9" }, d);
  assert.equal(result.status, "blocked-host");
  assert.match(result.message, /127\.0\.0\.1/);
  assert.equal(d.calls.relay, undefined); // never reached the fetch/ingest path
});

test("relay: refuses when the VIDEO url is off-allowlist even if the image host is fine", async () => {
  const d = deps();
  const prov = { platform: "twitter", mediaUrl: "https://pbs.twimg.com/media/x.jpg" };
  const result = await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "t-1", mp4Url: "https://evil.example/x.mp4" }, d);
  assert.equal(result.status, "blocked-host");
  assert.equal(d.calls.relay, undefined);
});

test("relay: threads the ordered video ladder through to ingestOne (098 D5)", async () => {
  const d = deps();
  const prov = { platform: "rednote", mediaUrl: null, mediaUrlFallback: null, rawMetadata: {} };
  const ladder = [
    "http://sns-v11.rednotecdn.com/stream/1/110/258/a_258.mp4",
    "http://sns-v27.rednotecdn.com/stream/1/110/258/a_258.mp4",
  ];
  await handleBulkMessage(
    { type: BULK.relay, provenance: prov, jobId: "J", sourceId: "n1:v", videoCandidates: ladder }, d);
  assert.deepEqual(d.calls.relay.opts.videoCandidates, ladder, "order is the contract, not a set");
});

test("relay: EVERY rung of the ladder goes through the SSRF guard, not just the first", async () => {
  // The ladder arrives on a page-supplied response and the SW fetches it in the
  // authenticated session with host_permissions — so a guard that checked only `mp4Url`
  // would leave the rung-advance as an unguarded way to reach any host at all.
  const d = deps();
  const prov = { platform: "rednote", mediaUrl: null, rawMetadata: {} };
  const result = await handleBulkMessage({
    type: BULK.relay, provenance: prov, jobId: "J", sourceId: "n1:v",
    videoCandidates: [
      "http://sns-v11.rednotecdn.com/stream/1/110/258/a_258.mp4",
      "http://127.0.0.1:47321/secret",          // the backup is the hostile one
    ],
  }, d);
  assert.equal(result.status, "blocked-host");
  assert.match(result.message, /127\.0\.0\.1/);
  assert.equal(d.calls.relay, undefined, "nothing was fetched");
});

test("relay: a rednote stream item with no still still reaches ingestOne", async () => {
  // Its poster is a SEPARATE item (`<note_id>`), so this one carries no media urls at all —
  // and the guard must not read "nothing to block" as "nothing to do".
  const d = deps();
  const prov = { platform: "rednote", mediaUrl: null, mediaUrlFallback: null, rawMetadata: {} };
  const result = await handleBulkMessage({
    type: BULK.relay, provenance: prov, jobId: "J", sourceId: "n1:v",
    videoCandidates: ["http://sns-v11.rednotecdn.com/stream/1/110/258/a_258.mp4"],
  }, d);
  assert.deepEqual(result, { status: "saved", deduplicated: false });
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
