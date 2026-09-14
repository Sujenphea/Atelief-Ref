// Atelier Capture — /jobs loopback contract tests (Phase 6).
//
// The SW-side wrappers must speak Swift's JobResponse DTO exactly. fetch is injected
// (no network); each test asserts the request shape (method / auth header / body) and
// the parsed return, plus the error mapping on a non-success status.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  openJob, fetchKnownSources, reportJobProgress, completeJob,
} from "../src/bulk-endpoint.js";
import { TOKEN_HEADER } from "../src/endpoint.js";
import { BASE_CACHE_KEY, STABLE_BASE, makeMemoryStorage } from "../src/base-url.js";

/** A fake fetch returning a given status + JSON body, recording the request. */
function fakeFetch(status, body) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return { status, json: async () => body };
  };
  return { fetchImpl, calls };
}

/** A per-test store with the base already resolved (301), so these tests assert the
 * /jobs request itself rather than the one-off `/health` probe in front of it — and
 * so they stay order-independent (a shared module cache would leak between them). */
function resolvedStorage() {
  return makeMemoryStorage({ [BASE_CACHE_KEY]: STABLE_BASE });
}

test("openJob: POSTs platform + token, returns { jobId, caps }", async () => {
  const { fetchImpl, calls } = fakeFetch(201, {
    status: "created", jobId: "JOB-1", caps: { maxBodyBytes: 10, maxVideoBodyBytes: 20 },
  });
  const result = await openJob({ platform: "pinterest", scope: "board:7" }, { token: "T", fetchImpl, storage: resolvedStorage() });

  assert.deepEqual(result, { jobId: "JOB-1", caps: { maxBodyBytes: 10, maxVideoBodyBytes: 20 } });
  assert.match(calls[0].url, /\/jobs$/);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers[TOKEN_HEADER], "T");
  assert.deepEqual(JSON.parse(calls[0].init.body), { platform: "pinterest", scope: "board:7", totalEstimate: null });
});

test("openJob: includes resumeJobId in the body only when provided (task-8 resume)", async () => {
  const { fetchImpl, calls } = fakeFetch(201, { status: "created", jobId: "JOB-2", caps: null });
  await openJob(
    { platform: "pinterest", scope: "b", resumeJobId: "JOB-prev" }, { token: "T", fetchImpl, storage: resolvedStorage() });
  assert.deepEqual(JSON.parse(calls[0].init.body),
    { platform: "pinterest", scope: "b", totalEstimate: null, resumeJobId: "JOB-prev" });
});

test("openJob: a non-created response throws with the server error", async () => {
  const { fetchImpl } = fakeFetch(400, { status: "error", error: "Unknown platform 'x'." });
  await assert.rejects(() => openJob({ platform: "x" }, { token: "T", fetchImpl, storage: resolvedStorage() }), /Unknown platform/);
});

test("fetchKnownSources: GETs the sourceIds array", async () => {
  const { fetchImpl, calls } = fakeFetch(200, { status: "known_sources", sourceIds: ["a", "b"] });
  const ids = await fetchKnownSources("JOB-1", { token: "T", fetchImpl, storage: resolvedStorage() });

  assert.deepEqual(ids, ["a", "b"]);
  assert.match(calls[0].url, /\/jobs\/JOB-1\/known-sources$/);
  assert.equal(calls[0].init.method, "GET");
});

test("fetchKnownSources: a 404 throws", async () => {
  const { fetchImpl } = fakeFetch(404, { status: "error", error: "no such job" });
  await assert.rejects(() => fetchKnownSources("X", { token: "T", fetchImpl, storage: resolvedStorage() }), /no such job/);
});

test("reportJobProgress: POSTs the skipped count, returns the job's current status", async () => {
  const { fetchImpl, calls } = fakeFetch(200, { status: "progress", jobStatus: "open" });
  const status = await reportJobProgress("JOB-1", 82, { token: "T", fetchImpl, storage: resolvedStorage() });

  assert.equal(status, "open");
  assert.match(calls[0].url, /\/jobs\/JOB-1\/progress$/);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers[TOKEN_HEADER], "T");
  assert.deepEqual(JSON.parse(calls[0].init.body), { skipped: 82 });
});

test("reportJobProgress: a ZERO count is still sent — the ping is the point, not the number", async () => {
  // A sweep scrolling or waiting on a note-open has skipped nothing new and is exactly the
  // sweep the 90s reconciler was pausing; an omitted body would be a heartbeat that isn't one.
  const { fetchImpl, calls } = fakeFetch(200, { status: "progress", jobStatus: "open" });
  await reportJobProgress("JOB-1", 0, { token: "T", fetchImpl, storage: resolvedStorage() });
  assert.deepEqual(JSON.parse(calls[0].init.body), { skipped: 0 });
});

test("reportJobProgress: reports a pause the sweep has not relayed into yet", async () => {
  const { fetchImpl } = fakeFetch(200, { status: "progress", jobStatus: "paused" });
  assert.equal(
    await reportJobProgress("JOB-1", 3, { token: "T", fetchImpl, storage: resolvedStorage() }),
    "paused");
});

test("reportJobProgress: a 404 (job gone) throws with the server error", async () => {
  const { fetchImpl } = fakeFetch(404, { status: "error", error: "Job not found." });
  await assert.rejects(
    () => reportJobProgress("X", 1, { token: "T", fetchImpl, storage: resolvedStorage() }),
    /Job not found/);
});

test("completeJob: POSTs the target status", async () => {
  const { fetchImpl, calls } = fakeFetch(200, { status: "ok" });
  assert.equal(await completeJob("JOB-1", "halted", { token: "T", fetchImpl, storage: resolvedStorage() }), true);
  assert.match(calls[0].url, /\/jobs\/JOB-1\/complete$/);
  assert.deepEqual(JSON.parse(calls[0].init.body), { status: "halted" });
});

test("completeJob: a non-200 throws", async () => {
  const { fetchImpl } = fakeFetch(400, { status: "error", error: "bad status" });
  await assert.rejects(() => completeJob("JOB-1", "nope", { token: "T", fetchImpl, storage: resolvedStorage() }), /bad status/);
});
