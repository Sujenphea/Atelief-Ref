// Atelier Capture — bulk controller orchestration tests (Phase 6).
//
// runBulkSweep is pure over an injected `transport` (the SW proxy) + `driver`, so a
// full sweep — open → known-set skip → relay → complete — runs with fakes and no
// chrome.*. Covers the happy path, dedup-skip via the loaded known-set, and the
// halt → "paused/halted" close transition.

import { test } from "node:test";
import assert from "node:assert/strict";

import { runBulkSweep, sweepCheckpointKey } from "../src/bulk-controller.js";
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

test("runBulkSweep: an unreachable (wall) self-halt closes the job as PAUSED (resumable)", async () => {
  const { transport, messages } = fakeTransport({ relayFor: () => ({ status: "unreachable" }) });
  const driver = driverOf([item("a"), item("b")]);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} }, { transport, driver, ...engineOpts });

  assert.equal(result.status, "halted");            // engine terminal state
  assert.equal(result.haltStatus, null);            // self-halt, not an app Cancel
  // No app Cancel → the ledger closes resumable, not "Stopped".
  assert.equal(messages.find((m) => m.type === BULK.complete).status, "paused");
});

test("runBulkSweep: an app-side PAUSE closes the job as paused (resumable), not halted", async () => {
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
  assert.equal(result.haltStatus, "paused");       // the app's Pause intent surfaced
  assert.deepEqual(relayed, ["a"]);                // stopped after the first item
  // The load-bearing fix: a Pause must close RESUMABLE, or the UI shows a dead
  // "Stopped" job with no Resume button.
  assert.equal(messages.find((m) => m.type === BULK.complete).status, "paused");
});

test("runBulkSweep: an app-side CANCEL closes the job as halted (terminal)", async () => {
  const relayed = [];
  const { transport, messages } = fakeTransport({
    relayFor: (id) => {
      relayed.push(id);
      // The app CANCELLED after the first item: its reply carries jobStatus "halted".
      return { status: "saved", deduplicated: false, jobStatus: relayed.length >= 1 ? "halted" : "open" };
    },
  });
  const driver = driverOf([item("a"), item("b"), item("c")]);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} }, { transport, driver, ...engineOpts });

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, "halted");       // explicit Cancel intent
  assert.equal(messages.find((m) => m.type === BULK.complete).status, "halted"); // stays terminal
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

// MARK: - Stable checkpoint key (cross-run resume)

/** A `{ load, save, remove }` store that records every call, seeded with `initial`. */
function fakeStorage(initial = {}) {
  const store = { ...initial };
  const calls = { load: [], save: [], remove: [] };
  return {
    store, calls,
    async load(key) { calls.load.push(key); return store[key] ?? null; },
    async save(key, value) { calls.save.push({ key, value }); store[key] = value; },
    async remove(key) { calls.remove.push(key); delete store[key]; },
  };
}

/** A driver that records the resume cursor its `enumerate` was invoked with. */
function recordingDriver(items) {
  const seen = {};
  return {
    seen,
    enumerate: (_input, opts) => {
      seen.cursor = opts ? opts.cursor : undefined;
      return (async function* () { for (const it of items) yield it; })();
    },
  };
}

test("sweepCheckpointKey: boardId wins, then scope, then a platform default", () => {
  assert.equal(
    sweepCheckpointKey({ platform: "pinterest", input: { boardId: "B" }, scope: "s" }),
    "atelier:bulk:pinterest:B");
  assert.equal(
    sweepCheckpointKey({ platform: "twitter", scope: "bookmarks" }),
    "atelier:bulk:twitter:bookmarks");
  assert.equal(sweepCheckpointKey({ platform: "pinterest" }), "atelier:bulk:pinterest:default");
});

test("runBulkSweep: checkpoints under the STABLE key (not jobId), cleared on complete", async () => {
  const { transport } = fakeTransport();
  const driver = driverOf([item("a"), item("b")]);
  const storage = fakeStorage();

  const result = await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" }, scope: "board:x" },
    { transport, driver, storage, ...engineOpts });

  assert.equal(result.status, "complete");
  const key = "atelier:bulk:pinterest:B7";                  // boardId, not "JOB-9"
  assert.ok(storage.calls.save.length > 0);
  assert.ok(storage.calls.save.every((c) => c.key === key));
  assert.ok(!storage.calls.save.some((c) => c.key.includes("JOB-9")));
  // Each checkpoint carries the jobId (task 8) so a later run can reopen this job.
  assert.ok(storage.calls.save.every((c) => c.value.jobId === "JOB-9"));
  assert.deepEqual(storage.calls.remove, [key]);            // cleared on clean finish
  assert.equal(storage.store[key], undefined);
});

test("runBulkSweep: resumes enumeration from the saved cursor under the stable key", async () => {
  const { transport } = fakeTransport();
  const driver = recordingDriver([item("a")]);
  const key = "atelier:bulk:pinterest:B7";
  const storage = fakeStorage({ [key]: { cursor: "CUR-9", counts: {} } });

  await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" }, scope: "board:x" },
    { transport, driver, storage, ...engineOpts });

  assert.equal(driver.seen.cursor, "CUR-9");                // read back, not stranded
});

test("runBulkSweep: resumes the SAME job — passes the checkpoint's jobId as resumeJobId (task 8)", async () => {
  const { transport, messages } = fakeTransport();
  const driver = driverOf([item("a")]);
  const key = "atelier:bulk:pinterest:B7";
  // A prior resumable halt left the jobId in the checkpoint.
  const storage = fakeStorage({ [key]: { cursor: "CUR-9", counts: {}, jobId: "JOB-prev" } });

  await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver, storage, ...engineOpts });

  const open = messages.find((m) => m.type === BULK.open);
  assert.equal(open.resumeJobId, "JOB-prev");              // reopen, don't mint a new job
});

test("runBulkSweep: a FRESH sweep (no prior checkpoint) opens with no resumeJobId", async () => {
  const { transport, messages } = fakeTransport();
  const driver = driverOf([item("a")]);
  const storage = fakeStorage();   // empty — nothing to resume

  await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver, storage, ...engineOpts });

  const open = messages.find((m) => m.type === BULK.open);
  assert.equal(open.resumeJobId, null);
});

test("runBulkSweep: a RESUMABLE halt (wall/pause) KEEPS the checkpoint so the next run resumes", async () => {
  const { transport } = fakeTransport({ relayFor: () => ({ status: "unreachable" }) });
  const driver = driverOf([item("a")]);
  const key = "atelier:bulk:pinterest:B7";
  const storage = fakeStorage({ [key]: { cursor: "CUR-prev" } });

  const result = await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver, storage, ...engineOpts });

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, null);                    // self-halt → resumable
  assert.deepEqual(storage.calls.remove, []);               // NOT cleared — resumable
  assert.ok(storage.store[key] != null);                    // a checkpoint remains
});

test("runBulkSweep: an app CANCEL CLEARS the checkpoint (terminal — a re-sweep starts fresh)", async () => {
  const relayed = [];
  const { transport } = fakeTransport({
    relayFor: (id) => {
      relayed.push(id);
      return { status: "saved", deduplicated: false, jobStatus: relayed.length >= 1 ? "halted" : "open" };
    },
  });
  const driver = driverOf([item("a"), item("b")]);
  const key = "atelier:bulk:pinterest:B7";
  const storage = fakeStorage({ [key]: { cursor: "CUR-prev" } });

  const result = await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver, storage, ...engineOpts });

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, "halted");                // explicit Cancel
  assert.deepEqual(storage.calls.remove, [key]);            // cleared — terminal
  assert.equal(storage.store[key], undefined);
});

// MARK: - close-tail robustness (12A)

test("runBulkSweep: a checkpoint-cleanup (remove) failure LOGS but does not mask sweep success", async () => {
  const { transport } = fakeTransport();
  const driver = driverOf([item("a"), item("b")]);
  const storage = fakeStorage();
  storage.remove = async () => { throw new Error("storage quota exceeded"); };
  const logs = [];

  // The sweep completed on the server; only the LOCAL checkpoint delete failed. That's
  // cosmetic (a resume just re-skips via dedup), so runBulkSweep must still resolve.
  const result = await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver, storage, log: (...a) => logs.push(a.join(" ")), ...engineOpts });

  assert.equal(result.status, "complete");
  assert.ok(logs.some((l) => /cleanup failed/.test(l)), "the failure is logged, not swallowed silently");
});

test("runBulkSweep: a failing job-close (complete) PROPAGATES — the ledger close is load-bearing", async () => {
  const driver = driverOf([item("a")]);
  // Unlike local cleanup, a failed server /complete must surface: leaving the ledger row
  // open is a real error the caller (and its retry/report path) needs to see.
  const transport = async (message) => {
    switch (message.type) {
      case BULK.open: return { jobId: "J", caps: null };
      case BULK.known: return [];
      case BULK.relay: return { status: "saved", deduplicated: false };
      case BULK.complete: throw new Error("complete failed (HTTP 500)");
      default: throw new Error(`unexpected ${message.type}`);
    }
  };

  await assert.rejects(
    () => runBulkSweep({ platform: "pinterest", input: {} }, { transport, driver, ...engineOpts }),
    /complete failed/);
});
