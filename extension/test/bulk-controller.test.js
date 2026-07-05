// Atelier Capture — bulk controller orchestration tests (Phase 6).
//
// runBulkSweep is pure over an injected `transport` (the SW proxy) + `driver`, so a
// full sweep — open → known-set skip → relay → complete — runs with fakes and no
// chrome.*. Covers the happy path, dedup-skip via the loaded known-set, and the
// halt → "paused/halted" close transition.

import { test } from "node:test";
import assert from "node:assert/strict";

import { runBulkSweep } from "../src/bulk-controller.js";
import { BULK } from "../src/bulk-messages.js";

function item(sourceId, videoUrl = null) {
  return {
    sourceId,
    mediaUrl: `https://cdn/${sourceId}.jpg`,
    mediaUrlFallback: null,
    cursor: `cur-${sourceId}`,
    provenance: { platform: "pinterest", mediaUrl: `https://cdn/${sourceId}.jpg`, rawMetadata: { videoUrl } },
  };
}

function driverOf(items) {
  return { enumerate: () => (async function* () { for (const it of items) yield it; })() };
}

/** A transport that records messages and answers per type; `relayFor` maps a
 * sourceId → the ingestOne result the SW would return. */
function fakeTransport({ known = [], relayFor = () => ({ status: "saved", deduplicated: false }) } = {}) {
  const messages = [];
  const transport = async (message) => {
    messages.push(message);
    switch (message.type) {
      case BULK.open: return { jobId: "JOB-9", caps: { maxBodyBytes: 1, maxVideoBodyBytes: 2 } };
      case BULK.known: return known;
      case BULK.relay: return relayFor(message.sourceId, message);
      case BULK.complete: return true;
      default: throw new Error(`unexpected ${message.type}`);
    }
  };
  return { transport, messages };
}

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};

test("runBulkSweep: opens, skips known, relays the rest, completes", async () => {
  const { transport, messages } = fakeTransport({ known: ["b"] });
  const driver = driverOf([item("a"), item("b"), item("c")]);

  const result = await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B", boardUrl: "/u/b/" } },
    { transport, driver, ...engineOpts });

  assert.equal(result.jobId, "JOB-9");
  assert.equal(result.status, "complete");
  assert.equal(result.counts.ingested, 2);
  assert.equal(result.counts.skipped, 1);

  const types = messages.map((m) => m.type);
  assert.equal(types[0], BULK.open);
  assert.equal(types[1], BULK.known);
  // relays only for the unknown items (b was skipped, never relayed).
  const relayed = messages.filter((m) => m.type === BULK.relay).map((m) => m.sourceId);
  assert.deepEqual(relayed.sort(), ["a", "c"]);
  const complete = messages.find((m) => m.type === BULK.complete);
  assert.equal(complete.status, "complete");
});

test("runBulkSweep: an unreachable relay halts and closes the job as halted", async () => {
  const { transport, messages } = fakeTransport({ relayFor: () => ({ status: "unreachable" }) });
  const driver = driverOf([item("a"), item("b")]);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} }, { transport, driver, ...engineOpts });

  assert.equal(result.status, "halted");
  assert.equal(messages.find((m) => m.type === BULK.complete).status, "halted");
});

test("runBulkSweep: an app-side pause (jobStatus on the relay reply) halts the sweep", async () => {
  const relayed = [];
  const { transport, messages } = fakeTransport({
    relayFor: (id) => {
      relayed.push(id);
      // The app paused after the first item lands: its reply carries jobStatus.
      return { status: "saved", deduplicated: false, jobStatus: relayed.length >= 1 ? "paused" : "open" };
    },
  });
  const driver = driverOf([item("a"), item("b"), item("c")]);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} }, { transport, driver, ...engineOpts });

  assert.equal(result.status, "halted");           // honored the pause
  assert.deepEqual(relayed, ["a"]);                // stopped after the first item
  assert.equal(messages.find((m) => m.type === BULK.complete).status, "halted");
});

test("runBulkSweep: relays a resolved MP4 only when resolveVideo is opt-in", async () => {
  const seen = [];
  const { transport } = fakeTransport({
    relayFor: (id, message) => { seen.push(message.mp4Url); return { status: "saved", deduplicated: false }; },
  });
  const driver = driverOf([item("v", "https://v/clip.mp4")]);

  await runBulkSweep(
    { platform: "twitter", input: {}, resolveVideo: true }, { transport, driver, ...engineOpts });
  assert.deepEqual(seen, ["https://v/clip.mp4"]);

  seen.length = 0;
  const driver2 = driverOf([item("v", "https://v/clip.mp4")]);
  await runBulkSweep(
    { platform: "twitter", input: {} }, { transport, driver: driver2, ...engineOpts }); // resolveVideo false
  assert.deepEqual(seen, [null]); // poster only
});
