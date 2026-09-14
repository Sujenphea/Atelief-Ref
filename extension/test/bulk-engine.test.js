// Atelier Capture — bulk-engine state-machine tests (Phase 3, [T10]).
//
// The engine is pure: driver, relay, known-set, storage, `sleep` and `random` are
// all injected, so the whole matrix — terminator, dedup-skip, resume-from-cursor,
// retry-requeue with backoff, fatal halt, concurrent checkpoint ordering — runs
// with fakes and NO real timers. `sleep` records the (logical) durations it was
// asked to wait, so "backoff timing" is asserted as a sequence, not a clock.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  runSweep, computeBackoff, classifyIngestResult, OUTCOMES,
} from "../src/bulk-engine.js";

// MARK: - fakes

/** A BulkItem with a per-item cursor derived from its sourceId. */
function item(sourceId, cursor = `cur-${sourceId}`) {
  return {
    sourceId,
    mediaUrl: `https://cdn/${sourceId}.jpg`,
    mediaUrlFallback: null,
    provenance: { platform: "test", rawMetadata: { id: sourceId } },
    cursor,
  };
}

/** A driver that yields `items` once, recording the cursor it was resumed from. */
function driverFrom(items) {
  const seen = { cursor: undefined, enumerateCalls: 0 };
  const driver = {
    enumerate(input, { cursor }) {
      seen.cursor = cursor;
      seen.enumerateCalls += 1;
      return (async function* () {
        for (const it of items) yield it;
      })();
    },
  };
  return { driver, seen };
}

/** A `sleep` that records every requested duration and resolves immediately. */
function recordingSleep() {
  const durations = [];
  return { sleep: (ms) => { durations.push(ms); return Promise.resolve(); }, durations };
}

/** An in-memory `{ load, save }` store that logs every save. */
function memStorage(initial = {}) {
  const data = { ...initial };
  const saves = [];
  return {
    data, saves,
    async load(key) { return data[key] ?? null; },
    async save(key, value) { data[key] = value; saves.push({ key, value }); },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

/** Common no-jitter, single-worker options for deterministic ordering. */
function serialOpts(over = {}) {
  const { sleep, durations } = recordingSleep();
  const opts = {
    sleep,
    random: () => 0,
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
    ...over,
  };
  return { opts, durations };
}

// MARK: - terminator

test("terminator: yields N items then completes; every item ingested", async () => {
  const { driver } = driverFrom([item("a"), item("b"), item("c")]);
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "complete");
  assert.deepEqual(result.counts, {
    ingested: 3, deduped: 0, skipped: 0, retryableFailed: 0, permanentFailed: 0,
  });
  assert.equal(result.cursor, "cur-c"); // checkpoint = last contiguous cursor
});

test("terminator: an empty driver completes with zero counts, no relay call", async () => {
  const { driver } = driverFrom([]);
  let calls = 0;
  const relay = async () => { calls += 1; return { outcome: OUTCOMES.ingested }; };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "complete");
  assert.equal(calls, 0);
  assert.equal(result.cursor, null);
});

// MARK: - dedup-skip [P14]

test("dedup-skip: known sourceIds are skipped with no relay and no pacing", async () => {
  const { driver } = driverFrom([item("a"), item("b"), item("c"), item("d")]);
  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const { opts, durations } = serialOpts({ relay, knownSet: new Set(["b", "d"]) });

  const result = await runSweep(driver, "in", opts);

  assert.deepEqual(relayed, ["a", "c"]);          // only the unknown items relayed
  assert.equal(result.counts.skipped, 2);
  assert.equal(result.counts.ingested, 2);
  assert.equal(durations.length, 2);              // skipped items don't pace
});

test("dedup-skip: an id ingested earlier in the SAME sweep skips a later duplicate", async () => {
  const { driver } = driverFrom([item("dup", "c0"), item("dup", "c1")]);
  let calls = 0;
  const relay = async () => { calls += 1; return { outcome: OUTCOMES.ingested }; };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(calls, 1);                          // second "dup" short-circuited
  assert.equal(result.counts.ingested, 1);
  assert.equal(result.counts.skipped, 1);
});

// MARK: - resume-from-cursor [A1]

test("resume-from-cursor: a saved checkpoint seeds the driver's start cursor", async () => {
  const { driver, seen } = driverFrom([item("a")]);
  const storage = memStorage({ "job:7": { cursor: "RESUME-HERE", counts: {} } });
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:7" });

  await runSweep(driver, "in", opts);

  assert.equal(seen.cursor, "RESUME-HERE");
});

test("resume-from-cursor: no checkpoint → driver starts from null", async () => {
  const { driver, seen } = driverFrom([item("a")]);
  const storage = memStorage();
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:new" });

  await runSweep(driver, "in", opts);

  assert.equal(seen.cursor, null);
});

test("checkpoint: cursor advances contiguously and persists progress", async () => {
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1"), item("c", "c2")]);
  const storage = memStorage();
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:1" });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.cursor, "c2");
  assert.deepEqual(storage.saves.map((s) => s.value.cursor), ["c0", "c1", "c2"]);
});

test("checkpoint: the WATERMARK ITEM's sourceId rides beside the cursor (509)", async () => {
  // The cursor says where to resume enumeration; it does not say what the halted run had
  // finished, and for a scroll-resumable driver it is null and says nothing at all. The
  // sourceId is that second fact, and a resume's per-item optimisations are built on it.
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1"), item("c", "c2")]);
  const storage = memStorage();
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:1" });

  await runSweep(driver, "in", opts);

  assert.deepEqual(storage.saves.map((s) => s.value.sourceId), ["a", "b", "c"]);
});

test("checkpoint: a SKIPPED item is a watermark like any other", async () => {
  // Every terminal outcome moves the watermark, so the sourceId has to follow it there too
  // — a resumed rednote sweep skips its way back to the halt point, and a boundary that
  // named the last INGESTED item would sit far behind the one the run actually reached.
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1")]);
  const storage = memStorage();
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({
    relay, storage, checkpointKey: "job:s", knownSet: new Set(["b"]),
  });

  await runSweep(driver, "in", opts);

  assert.deepEqual(storage.saves.map((s) => s.value.sourceId), ["a", "b"]);
});

test("checkpoint: every item the sweep could not land is NAMED in it (509)", async () => {
  // A note whose 9th image failed is in the app's known-set on the strength of the other
  // eight. Only this list can tell a resume it still owes one.
  const { driver } = driverFrom([item("a"), item("b"), item("c"), item("d")]);
  const storage = memStorage();
  const relay = async (it) => {
    if (it.sourceId === "b") return { outcome: OUTCOMES.permanentFailed };
    if (it.sourceId === "d") return { outcome: OUTCOMES.retryableFailed };
    return { outcome: OUTCOMES.ingested };
  };
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:f" });

  await runSweep(driver, "in", opts);

  const last = storage.saves.at(-1).value;
  assert.deepEqual(last.failed, ["b", "d"], "both kinds of failure, and nothing else");
  assert.equal(last.failedOverflow, false);
});

test("checkpoint: the failed set is SEEDED from the checkpoint, so it survives a chain of resumes", async () => {
  // The laundering, one level up: run 2 skips the note run 1 could not finish, fails
  // nothing of its own, and without the seed writes an empty list — so run 3 is back to
  // skipping a note that still owes an image, with nothing left that remembers.
  const { driver } = driverFrom([item("a")]);
  const storage = memStorage({
    "job:chain": { cursor: null, sourceId: "old", failed: ["note-1:8"], counts: {} },
  });
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:chain" });

  await runSweep(driver, "in", opts);

  assert.deepEqual(storage.saves.at(-1).value.failed, ["note-1:8"]);
});

test("checkpoint: at the cap the failed set says so rather than dropping ids", async () => {
  // Fail SAFE: a truncated list reads as a complete one, and the id it dropped is exactly
  // the note that would then be skipped still owing an image. The reader disarms on the
  // flag; it never gets a partial list to half-trust.
  const items = [item("f0"), item("f1"), item("f2")];
  const { driver } = driverFrom(items);
  const storage = memStorage();
  const relay = async () => ({ outcome: OUTCOMES.permanentFailed });
  const { opts } = serialOpts({
    relay, storage, checkpointKey: "job:cap",
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0, CHECKPOINT_FAILED_ID_CAP: 2 },
  });

  await runSweep(driver, "in", opts);

  const last = storage.saves.at(-1).value;
  assert.equal(last.failedOverflow, true);
  assert.equal(last.failed.length, 2, "capped, and the overflow flag is what says so");
});

test("checkpoint: an overflowed set stays overflowed across a resume", async () => {
  // The run that inherits a truncated list cannot un-truncate it, so the flag is as sticky
  // as the list is seeded — otherwise resume 2 reads a short list as a complete one.
  const { driver } = driverFrom([item("a")]);
  const storage = memStorage({
    "job:of": { cursor: null, failed: ["x"], failedOverflow: true, counts: {} },
  });
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, storage, checkpointKey: "job:of" });

  await runSweep(driver, "in", opts);

  assert.equal(storage.saves.at(-1).value.failedOverflow, true);
});

test("checkpoint: the sourceId never runs ahead of the contiguous prefix either", async () => {
  // The same trap the cursor has: item N+1 can finish first, and committing ITS id would
  // name a boundary past an item that never landed — on rednote, skipping the note that
  // was in flight when the sweep died.
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1")]);
  const gates = { a: deferred(), b: deferred() };
  const relay = async (it) => { await gates[it.sourceId].promise; return { outcome: OUTCOMES.ingested }; };
  const storage = memStorage();
  const { sleep } = recordingSleep();

  const done = runSweep(driver, "in", {
    relay, storage, checkpointKey: "job:o",
    sleep, random: () => 0,
    config: { MAX_CONCURRENCY: 2, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  await new Promise((r) => setTimeout(r, 0));
  gates.b.resolve();                                  // seq 1 finishes first
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(storage.saves.length, 0, "b's id must not be committed over an unfinished a");
  gates.a.resolve();
  await done;

  assert.deepEqual(storage.saves.map((s) => s.value.sourceId), ["b"], "one save, the whole prefix");
});

test("checkpoint: a storage.save failure is non-fatal — the sweep still completes (8A)", async () => {
  const { driver } = driverFrom([item("a"), item("b")]);
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const logs = [];
  const storage = {
    async load() { return null; },
    async save() { throw new Error("quota exceeded"); }, // every checkpoint write fails
  };
  const { sleep } = recordingSleep();

  const result = await runSweep(driver, "in", {
    relay, storage, checkpointKey: "job:x",
    sleep, random: () => 0, log: (...a) => logs.push(a.join(" ")),
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  assert.equal(result.status, "complete");         // NOT aborted by the failing save
  assert.equal(result.counts.ingested, 2);         // both items still relayed + recorded
  assert.ok(logs.some((l) => /checkpoint save failed/.test(l)), "the failure is logged");
});

// MARK: - retry requeue + backoff timing [P13][C7]

test("retry requeue: two transient fails then success → item ingested, 3 relay calls", async () => {
  const { driver } = driverFrom([item("a")]);
  const outcomes = [
    { outcome: OUTCOMES.retryableFailed },
    { outcome: OUTCOMES.retryableFailed },
    { outcome: OUTCOMES.ingested },
  ];
  let call = 0;
  const relay = async () => outcomes[call++];
  const { opts, durations } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(call, 3);
  assert.equal(result.counts.ingested, 1);
  assert.equal(result.counts.retryableFailed, 0); // recovered, not recorded failed
  // durations = pace(0), backoff, pace(0), backoff, pace(0). Backoffs: base, 2·base.
  assert.deepEqual(durations, [0, 1000, 0, 2000, 0]);
});

test("retry requeue: exhausting the budget records retryableFailed and moves on", async () => {
  const { driver } = driverFrom([item("a"), item("b")]);
  const relay = async (it) =>
    it.sourceId === "a" ? { outcome: OUTCOMES.retryableFailed } : { outcome: OUTCOMES.ingested };
  const { opts, durations } = serialOpts({
    relay, config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0, MAX_ITEM_RETRIES: 2 },
  });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "complete");         // one bad item never aborts
  assert.equal(result.counts.retryableFailed, 1);
  assert.equal(result.counts.ingested, 1);
  // "a": pace + (2 retries → backoff base, 2·base) across 3 relay calls, then "b".
  const backoffs = durations.filter((d) => d > 0);
  assert.deepEqual(backoffs, [1000, 2000]);
});

test("backoff timing: computeBackoff doubles then caps", () => {
  const cfg = { BACKOFF_BASE_MS: 1000, BACKOFF_MAX_MS: 5000 };
  assert.equal(computeBackoff(1, cfg), 1000);
  assert.equal(computeBackoff(2, cfg), 2000);
  assert.equal(computeBackoff(3, cfg), 4000);
  assert.equal(computeBackoff(4, cfg), 5000); // 8000 capped
  assert.equal(computeBackoff(9, cfg), 5000);
});

test("a relay that THROWS is treated as retryable (requeued with backoff)", async () => {
  const { driver } = driverFrom([item("a")]);
  let call = 0;
  const relay = async () => {
    call += 1;
    if (call === 1) throw new Error("socket reset");
    return { outcome: OUTCOMES.ingested };
  };
  const { opts, durations } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.counts.ingested, 1);
  assert.deepEqual(durations.filter((d) => d > 0), [1000]); // one backoff before retry
});

// MARK: - fatal halt [C7]

test("fatal halt: a halt signal pauses the sweep; later items are not relayed", async () => {
  const { driver } = driverFrom([item("a"), item("b"), item("c")]);
  const relayed = [];
  const relay = async (it) => {
    relayed.push(it.sourceId);
    if (it.sourceId === "b") return { outcome: OUTCOMES.retryableFailed, signal: "halt" };
    return { outcome: OUTCOMES.ingested };
  };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, null);           // a self-halt, not an app intent
  assert.deepEqual(relayed, ["a", "b"]);           // "c" never reached
  assert.equal(result.counts.ingested, 1);
  assert.equal(result.counts.retryableFailed, 1);  // the halting item is recorded
  assert.equal(result.cursor, "cur-b");
});

test("app halt: runSweep surfaces the relay's appStatus (paused vs cancel) as haltStatus", async () => {
  const { driver } = driverFrom([item("a"), item("b")]);
  // The relay reports the app PAUSED after the first item (7A feedback).
  const relay = async (it) =>
    it.sourceId === "a"
      ? { outcome: OUTCOMES.ingested, signal: "halt", appStatus: "paused" }
      : { outcome: OUTCOMES.ingested };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, "paused");       // surfaced for a resumable close
});

test("fatal halt: a halt outcome is NOT retried even with retry budget left", async () => {
  const { driver } = driverFrom([item("a")]);
  let call = 0;
  const relay = async () => { call += 1; return { outcome: OUTCOMES.retryableFailed, signal: "halt" }; };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(call, 1);                            // halt short-circuits the retry loop
  assert.equal(result.status, "halted");
});

test("a driver that throws mid-enumeration halts gracefully (no crash, error surfaced)", async () => {
  const driver = {
    enumerate() {
      return (async function* () {
        yield item("a");
        throw new Error("page fetch 403");   // driver dies pulling the next page
      })();
    },
  };
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "halted");
  assert.equal(result.counts.ingested, 1);      // the item pulled before the throw
  assert.match(result.error, /403/);
});

test("unreachable classification halts the sweep (app is down)", async () => {
  const { driver } = driverFrom([item("a"), item("b")]);
  const relay = async () => classifyIngestResult({ status: "unreachable" });
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "halted");
  assert.equal(result.counts.retryableFailed, 1);  // only the first item, then halt
});

// MARK: - concurrent checkpoint ordering

test("concurrency: a later item finishing first never checkpoints past an unfinished earlier item", async () => {
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1")]);
  const gates = { a: deferred(), b: deferred() };
  const relay = async (it) => {
    await gates[it.sourceId].promise;
    return { outcome: OUTCOMES.ingested };
  };
  const storage = memStorage();
  const { sleep } = recordingSleep();

  const done = runSweep(driver, "in", {
    relay, storage, checkpointKey: "job:c",
    sleep, random: () => 0,
    config: { MAX_CONCURRENCY: 2, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  // Let both items dispatch and block in relay.
  await new Promise((r) => setTimeout(r, 0));
  // Finish item "b" (seq 1) FIRST — its cursor must NOT be checkpointed yet.
  gates.b.resolve();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(storage.saves.length, 0, "no checkpoint while seq 0 is still in flight");
  // Now finish item "a" (seq 0) — the watermark jumps across both to c1.
  gates.a.resolve();
  const result = await done;

  assert.equal(result.cursor, "c1");
  assert.deepEqual(storage.saves.map((s) => s.value.cursor), ["c1"]);
});

test("concurrency: never more than MAX_CONCURRENCY relays in flight at once", async () => {
  const { driver } = driverFrom(Array.from({ length: 9 }, (_, i) => item(`i${i}`)));
  let inFlight = 0;
  let peak = 0;
  const relay = async () => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 0)); // hold so overlap is observable
    inFlight -= 1;
    return { outcome: OUTCOMES.ingested };
  };
  const { sleep } = recordingSleep();

  const result = await runSweep(driver, "in", {
    relay, sleep, random: () => 0,
    config: { MAX_CONCURRENCY: 3, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  assert.equal(result.counts.ingested, 9);
  assert.equal(peak, 3);                           // exactly the worker cap, never more
});

test("concurrency + halt: a later item's halt never strands an unfinished earlier item", async () => {
  const { driver } = driverFrom([item("a", "c0"), item("b", "c1"), item("c", "c2")]);
  const gateA = deferred();
  const relay = async (it) => {
    if (it.sourceId === "a") { await gateA.promise; return { outcome: OUTCOMES.ingested }; }
    if (it.sourceId === "b") return { outcome: OUTCOMES.retryableFailed, signal: "halt" };
    return { outcome: OUTCOMES.ingested };         // "c" must never be reached
  };
  const storage = memStorage();
  const { sleep } = recordingSleep();

  const done = runSweep(driver, "in", {
    relay, storage, checkpointKey: "job:h",
    sleep, random: () => 0,
    config: { MAX_CONCURRENCY: 2, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  // Both "a" (seq 0, gated) and "b" (seq 1, halts) dispatch. b records its halt, but
  // seq 0 is still in flight → the watermark must NOT advance over it.
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(storage.saves.length, 0, "b's cursor must not checkpoint over unfinished a");

  gateA.resolve();
  const result = await done;

  assert.equal(result.status, "halted");
  assert.equal(result.cursor, "c1");               // watermark jumps a→b once a lands
  assert.deepEqual(storage.saves.map((s) => s.value.cursor), ["c1"]); // one save, no strand
});

test("pacing jitter: the per-item gap includes the random()-scaled jitter", async () => {
  const { driver } = driverFrom([item("a")]);
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { sleep, durations } = recordingSleep();

  await runSweep(driver, "in", {
    relay, sleep, random: () => 0.5,               // mid-range jitter, deterministic
    config: { MAX_CONCURRENCY: 1, PACING_MS: 800, PACING_JITTER_MS: 700 },
  });

  // pace = PACING_MS + floor(random() * PACING_JITTER_MS) = 800 + floor(0.5·700) = 1150.
  assert.deepEqual(durations, [1150]);
});

// MARK: - progress reporting

test("onProgress reports cumulative counts after each terminal item", async () => {
  const { driver } = driverFrom([item("a"), item("b"), item("c")]);
  const relay = async (it) =>
    it.sourceId === "b"
      ? { outcome: OUTCOMES.permanentFailed }
      : { outcome: OUTCOMES.ingested };
  const snapshots = [];
  const { opts } = serialOpts({ relay, onProgress: (c) => snapshots.push({ ...c }) });

  await runSweep(driver, "in", opts);

  assert.equal(snapshots.length, 3);
  assert.equal(snapshots[2].ingested, 2);
  assert.equal(snapshots[2].permanentFailed, 1);
});

// MARK: - classifyIngestResult ([C7] taxonomy)

test("classifyIngestResult maps every ingestOne status", () => {
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: false }),
    { outcome: OUTCOMES.ingested, signal: "continue", appStatus: null });
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: true }),
    { outcome: OUTCOMES.deduped, signal: "continue", appStatus: null });
  assert.deepEqual(classifyIngestResult({ status: "unreachable" }),
    { outcome: OUTCOMES.retryableFailed, signal: "halt" });
  assert.deepEqual(classifyIngestResult({ status: "fetch-error" }),
    { outcome: OUTCOMES.retryableFailed, signal: "continue" });
  assert.deepEqual(classifyIngestResult({ status: "ingest-error" }),
    { outcome: OUTCOMES.permanentFailed, signal: "continue" });
  // no-image / no-token never reach the relay → recorded defensively as permanent.
  assert.deepEqual(classifyIngestResult({ status: "no-image" }),
    { outcome: OUTCOMES.permanentFailed, signal: "continue" });
  // blocked-host (3A SSRF refusal) is a permanent per-item skip — never retried, never a halt.
  assert.deepEqual(classifyIngestResult({ status: "blocked-host" }),
    { outcome: OUTCOMES.permanentFailed, signal: "continue" });
  // A TYPED SKIP from the relay (098 D5 / 020 Risks): every video candidate refused, with no
  // still to fall back to. It must NOT be a failure of either kind — a permanentFailed marks
  // the sweep unclean (which disarms the next run's known-set optimisations for the whole
  // board) and a retryableFailed spends four backoff attempts re-walking a ladder that just
  // said no.
  assert.deepEqual(classifyIngestResult({ status: "skipped", reason: "video-ladder-exhausted" }),
    { outcome: OUTCOMES.skipped, signal: "continue" });
});

test("a relayed skip leaves the sweep CLEAN — the property the outcome was chosen for", async () => {
  // `runBulkSweep` records `clean` from retryableFailed + permanentFailed being zero, and the
  // next sweep's pre-check is armed off that marker. A video note whose ladder gave nothing
  // must not cost the whole board its optimisation.
  const items = [{ sourceId: "a", cursor: "1" }, { sourceId: "b", cursor: "2" }];
  const driver = { enumerate: () => (async function* () { for (const i of items) yield i; })() };
  const result = await runSweep(driver, null, {
    relay: async (item) => classifyIngestResult(
      item.sourceId === "b" ? { status: "skipped", reason: "video-ladder-exhausted" }
        : { status: "saved", deduplicated: false }),
    sleep: async () => {}, random: () => 0,
  });
  assert.equal(result.status, "complete");
  assert.equal(result.counts.skipped, 1);
  assert.equal(result.counts.permanentFailed, 0);
  assert.equal(result.counts.retryableFailed, 0);
});

test("classifyIngestResult halts on an app-side pause/cancel (jobStatus relay feedback)", () => {
  // The item still ingests, but the sweep halts after it — and surfaces WHICH app
  // intent (paused vs halted/cancel) so the controller closes the ledger correctly.
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: false, jobStatus: "paused" }),
    { outcome: OUTCOMES.ingested, signal: "halt", appStatus: "paused" });
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: true, jobStatus: "halted" }),
    { outcome: OUTCOMES.deduped, signal: "halt", appStatus: "halted" });
  // An open/complete job (or no status) keeps going.
  assert.equal(classifyIngestResult({ status: "saved", deduplicated: false, jobStatus: "open" }).signal, "continue");
  assert.equal(classifyIngestResult({ status: "saved", deduplicated: false }).signal, "continue");
});

test("classifyIngestResult refines with httpStatus when present (forward-compatible)", () => {
  // A hard 404 on the media CDN is permanent, not retryable.
  assert.equal(classifyIngestResult({ status: "fetch-error", httpStatus: 404 }).outcome,
    OUTCOMES.permanentFailed);
  // A 429 stays retryable (throttle → back off).
  assert.equal(classifyIngestResult({ status: "fetch-error", httpStatus: 429 }).outcome,
    OUTCOMES.retryableFailed);
  // A 5xx from our own app is transient.
  assert.equal(classifyIngestResult({ status: "ingest-error", httpStatus: 503 }).outcome,
    OUTCOMES.retryableFailed);
  // A 422 stays permanent.
  assert.equal(classifyIngestResult({ status: "ingest-error", httpStatus: 422 }).outcome,
    OUTCOMES.permanentFailed);
});

test("classifyIngestResult: a 401/403 auth wall HALTS resumable, not a per-item fail (5A)", async () => {
  // A media-CDN 403 (session expired) or app 401 (bad token) is session-wide: recording
  // it per-item permanent would silently lose the rest of the sweep. Both HALT resumable.
  for (const httpStatus of [401, 403]) {
    const fromFetch = classifyIngestResult({ status: "fetch-error", httpStatus });
    assert.equal(fromFetch.signal, "halt", `fetch-error ${httpStatus} halts`);
    assert.equal(fromFetch.outcome, OUTCOMES.retryableFailed); // re-attempted on resume
    const fromIngest = classifyIngestResult({ status: "ingest-error", httpStatus });
    assert.equal(fromIngest.signal, "halt", `ingest-error ${httpStatus} halts`);
  }
  // Neither surfaces an appStatus, so the controller closes the job "paused" (resumable),
  // not "halted" (a terminal Cancel).
  assert.equal(classifyIngestResult({ status: "fetch-error", httpStatus: 403 }).appStatus, undefined);
});

test("auth wall halts the sweep resumable, sparing the rest of the board (5A)", async () => {
  const { driver } = driverFrom([item("a"), item("b"), item("c")]);
  const relayed = [];
  // The CDN cookie expired: every media fetch now 403s. The FIRST one must halt the
  // whole sweep, not fail-and-continue burning b and c as permanentFailed.
  const relay = async (it) => {
    relayed.push(it.sourceId);
    return classifyIngestResult({ status: "fetch-error", httpStatus: 403 });
  };
  const { opts } = serialOpts({ relay });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, null);           // self-halt → controller closes "paused"
  assert.deepEqual(relayed, ["a"]);                // stopped at the first wall, b/c untouched
  assert.equal(result.counts.retryableFailed, 1);  // "a" re-attempted on resume
  assert.equal(result.counts.permanentFailed, 0);  // NOTHING wrongly burned as permanent
});

// MARK: - re-sweep early-stop [14A]

test("early-stop: after K consecutive known items a fresh sweep completes EARLY (clean, not a halt)", async () => {
  const { driver } = driverFrom([item("k1"), item("k2"), item("k3"), item("new1"), item("new2")]);
  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const { opts } = serialOpts({
    relay, knownSet: new Set(["k1", "k2", "k3"]),
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0, STOP_AFTER_CONSECUTIVE_SKIPS: 3 },
  });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "complete");     // a clean completion, NOT "halted"
  assert.equal(result.earlyStopped, true);
  assert.equal(result.counts.skipped, 3);
  assert.equal(result.counts.ingested, 0);
  assert.deepEqual(relayed, []);               // new1/new2 past the wall are never reached
});

test("early-stop: a non-skip RESETS the consecutive run — a new item deep in the feed is not walled off", async () => {
  // k,k, NEW (resets to 0), k,k, NEW → the longest known-run is 2 < 3, so the whole feed
  // is walked and both new items are captured. This is the guard against under-capturing.
  const { driver } = driverFrom([item("k1"), item("k2"), item("n1"), item("k3"), item("k4"), item("n2")]);
  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const { opts } = serialOpts({
    relay, knownSet: new Set(["k1", "k2", "k3", "k4"]),
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0, STOP_AFTER_CONSECUTIVE_SKIPS: 3 },
  });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.status, "complete");
  assert.equal(result.earlyStopped, false);
  assert.equal(result.counts.skipped, 4);
  assert.deepEqual(relayed, ["n1", "n2"]);     // BOTH new items reached; never early-stopped
});

test("early-stop: disabled on a RESUME (a checkpoint present) even when configured", async () => {
  // A resumed sweep must run to the end (its checkpoint-page overlap would be a false
  // skip-run at the very front). The engine inerts early-stop whenever startCursor != null.
  const { driver } = driverFrom([item("k1"), item("k2"), item("k3"), item("k4")]);
  const storage = memStorage({ "job:r": { cursor: "RESUME", counts: {} } });
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({
    relay, storage, checkpointKey: "job:r", knownSet: new Set(["k1", "k2", "k3", "k4"]),
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0, STOP_AFTER_CONSECUTIVE_SKIPS: 2 },
  });

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.earlyStopped, false);
  assert.equal(result.counts.skipped, 4);      // full walk despite 4 consecutive knowns
});

test("early-stop: no threshold → a full re-walk even when everything is already known (default off)", async () => {
  const { driver } = driverFrom([item("k1"), item("k2"), item("k3")]);
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { opts } = serialOpts({ relay, knownSet: new Set(["k1", "k2", "k3"]) }); // no STOP_AFTER config

  const result = await runSweep(driver, "in", opts);

  assert.equal(result.earlyStopped, false);
  assert.equal(result.counts.skipped, 3);      // X/Pinterest behaviour — unchanged
});

test("early-stop: under concurrency it still stops early (the run is counted in enumeration order)", async () => {
  // 50 all-known items, threshold 5, 3 workers: the trailing-skip run is measured over the
  // CONTIGUOUS committed prefix (seq order), so it trips well before the feed is exhausted.
  const { driver } = driverFrom(Array.from({ length: 50 }, (_, i) => item(`k${i}`)));
  const known = new Set(Array.from({ length: 50 }, (_, i) => `k${i}`));
  const relay = async () => ({ outcome: OUTCOMES.ingested });
  const { sleep } = recordingSleep();

  const result = await runSweep(driver, "in", {
    relay, knownSet: known, sleep, random: () => 0,
    config: { MAX_CONCURRENCY: 3, PACING_MS: 0, PACING_JITTER_MS: 0, STOP_AFTER_CONSECUTIVE_SKIPS: 5 },
  });

  assert.equal(result.status, "complete");
  assert.equal(result.earlyStopped, true);
  assert.equal(result.counts.ingested, 0);
  assert.ok(result.counts.skipped < 50, `stopped early, not a full walk (skipped ${result.counts.skipped})`);
});

// MARK: - guardrails

test("runSweep requires a relay function", async () => {
  const { driver } = driverFrom([item("a")]);
  await assert.rejects(() => runSweep(driver, "in", {}), /requires a relay/);
});
