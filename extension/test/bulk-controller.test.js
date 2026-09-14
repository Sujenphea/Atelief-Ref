// Atelier Capture — bulk controller orchestration tests (Phase 6).
//
// runBulkSweep is pure over an injected `transport` (the SW proxy) + `driver`, so a
// full sweep — open → known-set skip → relay → complete — runs with fakes and no
// chrome.*. Covers the happy path, dedup-skip via the loaded known-set, and the
// halt → "paused/halted" close transition.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  runBulkSweep, sweepCheckpointKey, sweepCleanMarkerKey, sweepMode, armsNotePreCheck,
} from "../src/bulk-controller.js";
import { BULK } from "../src/bulk-messages.js";
import { SWEEP_HEARTBEAT_MS } from "../src/config.js";
import { videoCandidates, withVideoCandidates } from "../src/rednote-video.js";

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
 * sourceId → the ingestOne result the SW would return. `progressFor` lets a test make
 * the heartbeat fail (it answers with the job's status in production). */
function fakeTransport({
  known = [],
  relayFor = () => ({ status: "saved", deduplicated: false }),
  progressFor = () => "open",
} = {}) {
  const messages = [];
  const transport = async (message) => {
    messages.push(message);
    switch (message.type) {
      case BULK.open: return { jobId: "JOB-9", caps: { maxBodyBytes: 1, maxVideoBodyBytes: 2 } };
      case BULK.known: return known;
      case BULK.relay: return relayFor(message.sourceId, message);
      case BULK.progress: return progressFor(message);
      case BULK.complete: return true;
      default: throw new Error(`unexpected ${message.type}`);
    }
  };
  return { transport, messages };
}

/** A fake `setTimer`/`clearTimer` pair: nothing is scheduled, the callback is held so a
 * test fires it exactly when it wants to. No wall-clock anywhere, like `sleep`/`random`. */
function fakeTimers() {
  const started = [];
  const cleared = [];
  return {
    started, cleared,
    setTimer: (fn, ms) => { started.push({ fn, ms }); return `timer-${started.length}`; },
    clearTimer: (id) => { cleared.push(id); },
    /** Fire every timer ever started, awaiting each — including ones since cleared, which
     * is the point: a real interval's callback can already be queued when it is cancelled. */
    async tick() { for (const t of started) await t.fn(); },
  };
}

/** A driver that fires the heartbeat once before yielding each item, so the ping lands
 * DURING the sweep (when a real interval would fire) rather than after it settled. */
function driverTicking(items, timers) {
  return {
    enumerate: () => (async function* () {
      for (const it of items) { await timers.tick(); yield it; }
    })(),
  };
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

// MARK: - the rednote stream ladder: it reaches the relay, and NOTHING else (098 D5 / 020 B3)

/** A rednote stream item as `parseNoteDetail` builds one: no still (its poster is a separate
 * item at `<note_id>`), and the ladder attached non-enumerably. */
const LADDER = {
  EF4: [{
    video_codec: "EF4", format: "mp4", stream_type: 258, width: 720, height: 960,
    master_url: "http://sns-v11.rednotecdn.com/stream/1/110/258/a_258.mp4",
    backup_urls: ["http://sns-v27.rednotecdn.com/stream/1/110/258/a_258.mp4"],
  }],
};

const streamItem = () => withVideoCandidates({
  sourceId: "note1:v",
  mediaUrl: null,
  mediaUrlFallback: null,
  cursor: "cur-note1",
  provenance: { platform: "rednote", mediaUrl: null, rawMetadata: { noteId: "note1", kind: "video" } },
}, LADDER);

test("runBulkSweep: the stream ladder rides the relay message, only with resolveVideo", async () => {
  const seen = [];
  const { transport } = fakeTransport({
    relayFor: (_id, message) => { seen.push(message.videoCandidates); return { status: "saved", deduplicated: false }; },
  });

  await runBulkSweep(
    { platform: "rednote", input: {}, scope: "board:b", resolveVideo: true, expandNotes: true },
    { transport, driver: driverOf([streamItem()]), ...engineOpts });
  assert.deepEqual(seen, [videoCandidates(LADDER).candidates],
    "ordered, master before backup — the contract ingestOne walks");

  seen.length = 0;
  await runBulkSweep(
    { platform: "rednote", input: {}, scope: "board:b", expandNotes: true },
    { transport, driver: driverOf([streamItem()]), ...engineOpts });
  assert.deepEqual(seen, [null], "the same toggle that gates mp4Url gates the ladder behind it");
});

test("runBulkSweep: NO stream url reaches a saved checkpoint (020 B3), driven end to end", async () => {
  // The rule that made the list non-enumerable: the same note served a DIFFERENT ladder on
  // two visits minutes apart, so a checkpointed `master_url` comes back 404 or points at a
  // rung that is no longer right. `rednote-video.test.js` proves the engine drops it; this
  // proves the CONTROLLER — which reads it by name to build the relay message — does not
  // reintroduce it on the way past.
  const saves = [];
  const storage = {
    async load() { return null; },
    async save(_key, value) { saves.push(JSON.stringify(value)); },
    async remove() {},
  };
  const { transport } = fakeTransport();

  await runBulkSweep(
    { platform: "rednote", input: {}, scope: "board:b", resolveVideo: true, expandNotes: true },
    { transport, driver: driverOf([streamItem()]), storage, ...engineOpts });

  const urls = videoCandidates(LADDER).candidates;
  assert.ok(saves.length > 0, "the sweep must actually have written, or this proves nothing");
  assert.ok(urls.length > 0);
  for (const saved of saves) {
    for (const url of urls) assert.equal(saved.includes(url), false, `${url} in ${saved}`);
    assert.equal(saved.includes("rednotecdn.com/stream/"), false, saved);
  }
});

test("runBulkSweep: the ladder never enters the PROVENANCE the relay ships", async () => {
  // The other persisted surface: provenance is what reaches the app and what a checkpointed
  // item would carry. The ladder travels as its own message field, beside it, never in it.
  const seen = [];
  const { transport } = fakeTransport({
    relayFor: (_id, message) => { seen.push(message); return { status: "saved", deduplicated: false }; },
  });

  await runBulkSweep(
    { platform: "rednote", input: {}, scope: "board:b", resolveVideo: true, expandNotes: true },
    { transport, driver: driverOf([streamItem()]), ...engineOpts });

  const [message] = seen;
  const stored = JSON.stringify(message.provenance);
  for (const url of videoCandidates(LADDER).candidates) assert.equal(stored.includes(url), false);
  assert.ok(message.videoCandidates.length > 0, "…and it did travel, so this is not vacuous");
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
  // The engine's CHECKPOINT saves (each carrying a cursor) go under the stable key…
  const checkpointSaves = storage.calls.save.filter((c) => c.value.cursor !== undefined);
  assert.ok(checkpointSaves.length > 0);
  assert.ok(checkpointSaves.every((c) => c.key === key));
  assert.ok(!storage.calls.save.some((c) => c.key.includes("JOB-9")));
  // Each checkpoint carries the jobId (task 8) so a later run can reopen this job.
  assert.ok(checkpointSaves.every((c) => c.value.jobId === "JOB-9"));
  assert.deepEqual(storage.calls.remove, [key]);            // checkpoint cleared on clean finish
  assert.equal(storage.store[key], undefined);
  // …and the 14A clean-marker is written once, to the :lastclean key (a failure-free run),
  // carrying the sweep's MODE beside it (098 R14 — a cover-only sweep must be legible as
  // one, or the next expansion sweep would trust its coverage and skip every note-open).
  assert.deepEqual(storage.store[`${key}:lastclean`], { clean: true, mode: "cover" });
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

// MARK: - the progress heartbeat (changelog 507)
//
// The app pauses any `open` job idle for 90s, and the only thing that bumped `updated_at`
// was a RELAYED item — so a sweep in a long dedup/note-open stretch was paused underneath
// itself and halted on the resulting `jobStatus: "paused"`. These pin the timer's contract:
// it starts after the job opens, carries the live skipped count, is always cancelled, and
// can never take the sweep down with it.

test("runBulkSweep: starts the heartbeat AFTER the job opens, at the configured interval", async () => {
  const timers = fakeTimers();
  const { transport, messages } = fakeTransport();

  await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport, driver: driverOf([item("a")]), ...engineOpts, ...timers });

  assert.equal(timers.started.length, 1, "exactly one heartbeat per sweep");
  assert.equal(timers.started[0].ms, SWEEP_HEARTBEAT_MS, "the config constant, not a local copy");
  // A ping needs the jobId, so it cannot precede the open — and the app would 404 it.
  const firstPing = messages.findIndex((m) => m.type === BULK.progress);
  assert.ok(firstPing > messages.findIndex((m) => m.type === BULK.open));
  assert.equal(messages[firstPing].jobId, "JOB-9");
});

test("runBulkSweep: a tick mid-sweep pings with the LIVE skipped count", async () => {
  const timers = fakeTimers();
  const { transport, messages } = fakeTransport({ known: ["a", "b"] });
  // a and b are already known → skipped without any relay: the exact stretch that used to
  // pass 90s in silence. c is fresh.
  const driver = driverTicking([item("a"), item("b"), item("c")], timers);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} }, { transport, driver, ...engineOpts, ...timers });

  assert.equal(result.counts.skipped, 2);
  const skips = messages.filter((m) => m.type === BULK.progress).map((m) => m.skipped);
  // One tick before each of the three items (0, 1, 2 skips so far), then the closing ping.
  assert.deepEqual(skips, [0, 1, 2, 2]);
});

test("runBulkSweep: pings once more before the close, so a short sweep's count still lands", async () => {
  const timers = fakeTimers();
  const { transport, messages } = fakeTransport({ known: ["a"] });

  await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport, driver: driverOf([item("a")]), ...engineOpts, ...timers });

  // The timer never fired — a sweep finishing inside 30s never would — so without the
  // closing ping the ledger would keep 0 and the row would read "0 skipped" for ever.
  const pings = messages.filter((m) => m.type === BULK.progress);
  assert.deepEqual(pings.map((m) => m.skipped), [1]);
  // …and it lands BEFORE the close, not after a job the app has already terminated.
  assert.ok(messages.indexOf(pings[0]) < messages.findIndex((m) => m.type === BULK.complete));
});

test("runBulkSweep: a FAILING ping logs and the sweep still completes", async () => {
  const timers = fakeTimers();
  const logs = [];
  const { transport } = fakeTransport({
    progressFor: () => { throw new Error("progress failed (HTTP 500)"); },
  });
  const driver = driverTicking([item("a"), item("b")], timers);

  const result = await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport, driver, log: (...a) => logs.push(a.join(" ")), ...engineOpts, ...timers });

  // A lost heartbeat's worst case is the bug this fixes (the job goes stale and is
  // paused); losing the whole sweep to it would be strictly worse.
  assert.equal(result.status, "complete");
  assert.equal(result.counts.ingested, 2);
  assert.ok(logs.some((l) => /progress ping failed/.test(l)), "logged, not swallowed");
});

test("runBulkSweep: the heartbeat is cancelled on a clean close, a halt, and a THROW", async () => {
  // Clean close.
  const clean = fakeTimers();
  const { transport } = fakeTransport();
  await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport, driver: driverOf([item("a")]), ...engineOpts, ...clean });
  assert.deepEqual(clean.cleared, clean.started.map((_, i) => `timer-${i + 1}`));

  // Halt (the app cancelled mid-sweep).
  const halted = fakeTimers();
  const { transport: haltTransport } = fakeTransport({
    relayFor: () => ({ status: "saved", deduplicated: false, jobStatus: "halted" }),
  });
  await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport: haltTransport, driver: driverOf([item("a"), item("b")]), ...engineOpts, ...halted });
  assert.deepEqual(halted.cleared, ["timer-1"]);

  // A throw out of the engine — an interval nobody cancels outlives the sweep and keeps
  // pinging a job that is closed, which is why the stop lives in a `finally`.
  const thrown = fakeTimers();
  const { transport: throwTransport } = fakeTransport();
  await assert.rejects(() => runBulkSweep(
    { platform: "pinterest", input: {} },
    {
      transport: throwTransport,
      driver: { enumerate: () => { throw new Error("driver exploded"); } },
      ...engineOpts, ...thrown,
    }), /driver exploded/);
  assert.deepEqual(thrown.cleared, ["timer-1"]);
});

test("runBulkSweep: a tick that lands AFTER the sweep settled sends nothing", async () => {
  // A real interval's callback can already be queued when `clearInterval` runs, so the
  // stop is a flag as well as a cancel — otherwise a ping arrives after the close and
  // touches a job the sweep no longer owns.
  const timers = fakeTimers();
  const { transport, messages } = fakeTransport();

  await runBulkSweep(
    { platform: "pinterest", input: {} },
    { transport, driver: driverOf([item("a")]), ...engineOpts, ...timers });

  const before = messages.filter((m) => m.type === BULK.progress).length;
  await timers.tick();
  assert.equal(messages.filter((m) => m.type === BULK.progress).length, before);
});

test("runBulkSweep: the heartbeat does not displace the caller's onProgress", async () => {
  // The ping reads the same counts snapshot `onProgress` is handed, and wrapping it must
  // not cost the caller its own callback.
  const timers = fakeTimers();
  const { transport } = fakeTransport();
  const seen = [];

  await runBulkSweep(
    { platform: "pinterest", input: {} },
    {
      transport, driver: driverOf([item("a"), item("b")]),
      onProgress: (counts) => seen.push(counts.ingested), ...engineOpts, ...timers,
    });

  assert.deepEqual(seen, [1, 2]);
});

// MARK: - re-sweep early-stop arming (14A)

test("sweepCleanMarkerKey: points at the same target as the checkpoint, with a :lastclean suffix", () => {
  assert.equal(
    sweepCleanMarkerKey({ platform: "instagram", scope: "saved" }),
    "atelier:bulk:instagram:saved:lastclean");
});

test("runBulkSweep: records a clean-marker true after a failure-free completion", async () => {
  const { transport } = fakeTransport();
  const driver = driverOf([item("a"), item("b")]);
  const storage = fakeStorage();

  await runBulkSweep(
    { platform: "instagram", scope: "saved", input: {} },
    { transport, driver, storage, ...engineOpts });

  assert.deepEqual(storage.store["atelier:bulk:instagram:saved:lastclean"], { clean: true, mode: "cover" });
});

test("runBulkSweep: records clean-marker false when the sweep had a permanent/retryable fail", async () => {
  // A stray failure means the NEXT sweep must full-walk to re-attempt it, so it must NOT
  // be allowed to early-stop — the marker records the failure to enforce that.
  const { transport } = fakeTransport({
    relayFor: (id) => (id === "a" ? { status: "ingest-error" } : { status: "saved", deduplicated: false }),
  });
  const driver = driverOf([item("a"), item("b")]);
  const storage = fakeStorage();

  const result = await runBulkSweep(
    { platform: "instagram", scope: "saved", input: {} },
    { transport, driver, storage, ...engineOpts });

  assert.equal(result.status, "complete");
  assert.equal(result.counts.permanentFailed, 1);
  assert.deepEqual(storage.store["atelier:bulk:instagram:saved:lastclean"], { clean: false, mode: "cover" });
});

test("runBulkSweep: arms early-stop ONLY on a fresh sweep whose prior run was clean", async () => {
  const items = Array.from({ length: 10 }, (_, i) => item(`k${i}`));
  const known = items.map((it) => it.sourceId);          // the whole feed is already ingested
  const cleanKey = "atelier:bulk:instagram:saved:lastclean";

  // (a) prior clean=true → early-stops after the threshold, not a full re-walk.
  {
    const { transport } = fakeTransport({ known });
    const storage = fakeStorage({ [cleanKey]: { clean: true } });
    const result = await runBulkSweep(
      { platform: "instagram", scope: "saved", input: {} },
      { transport, driver: driverOf(items), storage, ...engineOpts, earlyStopThreshold: 3 });
    assert.equal(result.earlyStopped, true);
    assert.ok(result.counts.skipped < 10, "stopped early");
  }
  // (b) no prior marker (first-ever sweep) → full walk, never early-stop.
  {
    const { transport } = fakeTransport({ known });
    const storage = fakeStorage();
    const result = await runBulkSweep(
      { platform: "instagram", scope: "saved", input: {} },
      { transport, driver: driverOf(items), storage, ...engineOpts, earlyStopThreshold: 3 });
    assert.equal(result.earlyStopped, false);
    assert.equal(result.counts.skipped, 10);
  }
  // (c) prior clean=false → full walk (re-attempt any stranded stray).
  {
    const { transport } = fakeTransport({ known });
    const storage = fakeStorage({ [cleanKey]: { clean: false } });
    const result = await runBulkSweep(
      { platform: "instagram", scope: "saved", input: {} },
      { transport, driver: driverOf(items), storage, ...engineOpts, earlyStopThreshold: 3 });
    assert.equal(result.earlyStopped, false);
    assert.equal(result.counts.skipped, 10);
  }
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
      case BULK.progress: return "open";
      case BULK.complete: throw new Error("complete failed (HTTP 500)");
      default: throw new Error(`unexpected ${message.type}`);
    }
  };

  await assert.rejects(
    () => runBulkSweep({ platform: "pinterest", input: {} }, { transport, driver, ...engineOpts }),
    /complete failed/);
});

// MARK: - the sweep MODE, and the note-level pre-check it gates (098 R14, T5b)
//
// The clean marker used to record one bit: "did the last completed sweep of this scope
// fail?". rednote's expansion pass needs a second: WHICH PASS it was. A cover item is keyed
// `<note_id>` and an expanded image `<note_id>:<index>`, so after the cover-only DEFAULT
// every note on the board is a known id — and a note-level pre-check armed off that would
// skip every note-open of the first expansion sweep. The toggle would silently do nothing
// on any board already swept, which is worse than the waste R14 exists to cure: that one is
// loud, this one reports "complete, 0 new".

test("sweepMode: the expansion toggle is what names the pass", () => {
  assert.equal(sweepMode({ platform: "rednote" }), "cover");
  assert.equal(sweepMode({ platform: "rednote", expandNotes: false }), "cover");
  assert.equal(sweepMode({ platform: "rednote", expandNotes: true }), "expansion");
  assert.equal(sweepMode({ platform: "instagram" }), "cover", "a platform with one pass records it anyway");
});

test("armsNotePreCheck: the whole table, including the migration row", () => {
  // prior expansion → this expansion: the R14 case, and the only YES.
  assert.equal(armsNotePreCheck({ clean: true, mode: "expansion" }, "expansion"), true);
  // prior cover-only → this expansion: every note still owes its images.
  assert.equal(armsNotePreCheck({ clean: true, mode: "cover" }, "expansion"), false);
  // prior expansion → this cover-only: a cover was never keyed `<id>:<index>`.
  assert.equal(armsNotePreCheck({ clean: true, mode: "expansion" }, "cover"), true);
  assert.equal(armsNotePreCheck({ clean: true, mode: "cover" }, "cover"), true);
  // MIGRATION: a marker written by a build that predates the field. UNKNOWN is neither
  // "cover" nor "expansion" — it arms nothing, and the pre-existing `clean` rule is
  // untouched (asserted for real against Instagram's early-stop below).
  assert.equal(armsNotePreCheck({ clean: true }, "expansion"), false);
  assert.equal(armsNotePreCheck({ clean: true, mode: "something-later" }, "expansion"), false);
  assert.equal(armsNotePreCheck(null, "expansion"), false);
});

/** A fake expander with the shape runBulkSweep threads: armed once with the known-set,
 * read back once at the end. */
function fakeExpansion(stats = { mode: "expansion", partial: false }) {
  const armings = [];
  return {
    armings,
    arm: (options) => { armings.push(options); },
    stats: () => stats,
  };
}

test("runBulkSweep: records the sweep's MODE beside `clean`, for both passes", async () => {
  for (const [spec, mode] of [
    [{ platform: "rednote", scope: "board:b", input: {} }, "cover"],
    [{ platform: "rednote", scope: "board:b", input: {}, expandNotes: true }, "expansion"],
  ]) {
    const { transport } = fakeTransport();
    const storage = fakeStorage();
    await runBulkSweep(spec, {
      transport, driver: driverOf([item("a")]), storage,
      expansion: spec.expandNotes ? fakeExpansion() : null, ...engineOpts,
    });
    assert.deepEqual(storage.store["atelier:bulk:rednote:board:b:lastclean"], { clean: true, mode });
  }
});

test("runBulkSweep: arms the note pre-check only after a CLEAN EXPANSION sweep", async () => {
  const cleanKey = "atelier:bulk:rednote:board:b:lastclean";
  const spec = { platform: "rednote", scope: "board:b", input: {}, expandNotes: true };
  const cases = [
    // [ the marker the prior sweep left, armed? ]
    [{ clean: true, mode: "expansion" }, true],            // the R14 case
    [{ clean: true, mode: "cover" }, false],               // the mode trap: every note owes images
    [{ clean: false, mode: "expansion" }, false],          // a stray failure → full re-walk
    [{ clean: true }, false],                              // MIGRATION: an older build's marker
    [null, false],                                         // never swept
  ];
  for (const [marker, armed] of cases) {
    const { transport } = fakeTransport({ known: ["a"] });
    const storage = fakeStorage(marker ? { [cleanKey]: marker } : {});
    const expansion = fakeExpansion();
    await runBulkSweep(spec, {
      transport, driver: driverOf([item("a")]), storage, expansion, ...engineOpts,
    });
    assert.equal(expansion.armings.length, 1, "the expander is armed exactly once, after the known-set loads");
    assert.equal(expansion.armings[0].armed, armed, `marker ${JSON.stringify(marker)}`);
    // Armed or not, it is always HANDED the known-set — the decision is the `armed` flag,
    // never a silently absent set.
    assert.deepEqual([...expansion.armings[0].knownSet], ["a"]);
  }
});

test("runBulkSweep: a RESUMED sweep never arms the note pre-check", async () => {
  // Same precondition as Instagram's early-stop: an outstanding checkpoint means the last
  // attempt HALTED, and a halt can leave a note with 3 of its 9 images ingested — which
  // looks expanded. The clean marker only speaks for the last sweep that COMPLETED.
  const key = "atelier:bulk:rednote:board:b";
  const storage = fakeStorage({
    [key]: { cursor: null, counts: {}, jobId: "JOB-prev" },
    [`${key}:lastclean`]: { clean: true, mode: "expansion" },
  });
  const { transport } = fakeTransport();
  const expansion = fakeExpansion();

  await runBulkSweep(
    { platform: "rednote", scope: "board:b", input: {}, expandNotes: true },
    { transport, driver: driverOf([item("a")]), storage, expansion, ...engineOpts });

  assert.equal(expansion.armings[0].armed, false);
});

test("runBulkSweep: Instagram's early-stop is untouched by a marker with no mode", async () => {
  // The migration case, on the platform it must not regress. A 14A marker written before
  // `mode` existed still arms STOP_AFTER_CONSECUTIVE_SKIPS exactly as it did — the new
  // field gates the new pre-check and nothing else.
  const items = Array.from({ length: 10 }, (_, i) => item(`k${i}`));
  const { transport } = fakeTransport({ known: items.map((it) => it.sourceId) });
  const storage = fakeStorage({ "atelier:bulk:instagram:saved:lastclean": { clean: true } });

  const result = await runBulkSweep(
    { platform: "instagram", scope: "saved", input: {} },
    { transport, driver: driverOf(items), storage, ...engineOpts, earlyStopThreshold: 3 });

  assert.equal(result.earlyStopped, true);
  assert.ok(result.counts.skipped < 10);
});

test("runBulkSweep: the expansion stats ride out on the result (098 R7)", async () => {
  const stats = { mode: "expansion", expanded: 3, degraded: 2, budgetExhausted: false, partial: true };
  const { transport } = fakeTransport();

  const result = await runBulkSweep(
    { platform: "rednote", scope: "board:b", input: {}, expandNotes: true },
    { transport, driver: driverOf([item("a")]), expansion: fakeExpansion(stats), ...engineOpts });

  // Without this a sweep where forty notes quietly kept their cover is indistinguishable
  // from one where every note gave up its photos — same status, same counts, same message.
  assert.deepEqual(result.expansion, stats);
  assert.equal(result.status, "complete");
});

test("runBulkSweep: a cover-only sweep reports NO expansion, not an empty one", async () => {
  const { transport } = fakeTransport();
  const result = await runBulkSweep(
    { platform: "rednote", scope: "board:b", input: {} },
    { transport, driver: driverOf([item("a")]), ...engineOpts });

  assert.equal(result.expansion, null);
});

test("runBulkSweep: with no expansion and no early-stop, the clean marker is never READ", async () => {
  // It is only ever an input to those two optimisations, and X/Pinterest have neither.
  const { transport } = fakeTransport();
  const storage = fakeStorage();

  await runBulkSweep(
    { platform: "pinterest", input: { boardId: "B7" } },
    { transport, driver: driverOf([item("a")]), storage, ...engineOpts });

  assert.equal(storage.calls.load.some((key) => key.endsWith(":lastclean")), false);
});
