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
  assert.deepEqual(relayed, ["a", "b"]);           // "c" never reached
  assert.equal(result.counts.ingested, 1);
  assert.equal(result.counts.retryableFailed, 1);  // the halting item is recorded
  assert.equal(result.cursor, "cur-b");
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
    { outcome: OUTCOMES.ingested, signal: "continue" });
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: true }),
    { outcome: OUTCOMES.deduped, signal: "continue" });
  assert.deepEqual(classifyIngestResult({ status: "unreachable" }),
    { outcome: OUTCOMES.retryableFailed, signal: "halt" });
  assert.deepEqual(classifyIngestResult({ status: "fetch-error" }),
    { outcome: OUTCOMES.retryableFailed, signal: "continue" });
  assert.deepEqual(classifyIngestResult({ status: "ingest-error" }),
    { outcome: OUTCOMES.permanentFailed, signal: "continue" });
  // no-image / no-token never reach the relay → recorded defensively as permanent.
  assert.deepEqual(classifyIngestResult({ status: "no-image" }),
    { outcome: OUTCOMES.permanentFailed, signal: "continue" });
});

test("classifyIngestResult halts on an app-side pause/cancel (jobStatus relay feedback)", () => {
  // The item still ingests, but the sweep halts after it.
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: false, jobStatus: "paused" }),
    { outcome: OUTCOMES.ingested, signal: "halt" });
  assert.deepEqual(classifyIngestResult({ status: "saved", deduplicated: true, jobStatus: "halted" }),
    { outcome: OUTCOMES.deduped, signal: "halt" });
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

// MARK: - guardrails

test("runSweep requires a relay function", async () => {
  const { driver } = driverFrom([item("a")]);
  await assert.rejects(() => runSweep(driver, "in", {}), /requires a relay/);
});
