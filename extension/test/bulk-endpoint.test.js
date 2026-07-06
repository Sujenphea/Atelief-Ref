// Atelier Capture — /jobs loopback contract tests (Phase 6).
//
// The SW-side wrappers must speak Swift's JobResponse DTO exactly. fetch is injected
// (no network); each test asserts the request shape (method / auth header / body) and
// the parsed return, plus the error mapping on a non-success status.

import { test } from "node:test";
import assert from "node:assert/strict";

import { openJob, fetchKnownSources, completeJob } from "../src/bulk-endpoint.js";
import { TOKEN_HEADER } from "../src/endpoint.js";

/** A fake fetch returning a given status + JSON body, recording the request. */
function fakeFetch(status, body) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return { status, json: async () => body };
  };
  return { fetchImpl, calls };
}

test("openJob: POSTs platform + token, returns { jobId, caps }", async () => {
  const { fetchImpl, calls } = fakeFetch(201, {
    status: "created", jobId: "JOB-1", caps: { maxBodyBytes: 10, maxVideoBodyBytes: 20 },
  });
  const result = await openJob({ platform: "pinterest", scope: "board:7" }, { token: "T", fetchImpl });

  assert.deepEqual(result, { jobId: "JOB-1", caps: { maxBodyBytes: 10, maxVideoBodyBytes: 20 } });
  assert.match(calls[0].url, /\/jobs$/);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers[TOKEN_HEADER], "T");
  assert.deepEqual(JSON.parse(calls[0].init.body), { platform: "pinterest", scope: "board:7", totalEstimate: null });
});

test("openJob: includes resumeJobId in the body only when provided (task-8 resume)", async () => {
  const { fetchImpl, calls } = fakeFetch(201, { status: "created", jobId: "JOB-2", caps: null });
  await openJob(
    { platform: "pinterest", scope: "b", resumeJobId: "JOB-prev" }, { token: "T", fetchImpl });
  assert.deepEqual(JSON.parse(calls[0].init.body),
    { platform: "pinterest", scope: "b", totalEstimate: null, resumeJobId: "JOB-prev" });
});

test("openJob: a non-created response throws with the server error", async () => {
  const { fetchImpl } = fakeFetch(400, { status: "error", error: "Unknown platform 'x'." });
  await assert.rejects(() => openJob({ platform: "x" }, { token: "T", fetchImpl }), /Unknown platform/);
});

test("fetchKnownSources: GETs the sourceIds array", async () => {
  const { fetchImpl, calls } = fakeFetch(200, { status: "known_sources", sourceIds: ["a", "b"] });
  const ids = await fetchKnownSources("JOB-1", { token: "T", fetchImpl });

  assert.deepEqual(ids, ["a", "b"]);
  assert.match(calls[0].url, /\/jobs\/JOB-1\/known-sources$/);
  assert.equal(calls[0].init.method, "GET");
});

test("fetchKnownSources: a 404 throws", async () => {
  const { fetchImpl } = fakeFetch(404, { status: "error", error: "no such job" });
  await assert.rejects(() => fetchKnownSources("X", { token: "T", fetchImpl }), /no such job/);
});

test("completeJob: POSTs the target status", async () => {
  const { fetchImpl, calls } = fakeFetch(200, { status: "ok" });
  assert.equal(await completeJob("JOB-1", "halted", { token: "T", fetchImpl }), true);
  assert.match(calls[0].url, /\/jobs\/JOB-1\/complete$/);
  assert.deepEqual(JSON.parse(calls[0].init.body), { status: "halted" });
});

test("completeJob: a non-200 throws", async () => {
  const { fetchImpl } = fakeFetch(400, { status: "error", error: "bad status" });
  await assert.rejects(() => completeJob("JOB-1", "nope", { token: "T", fetchImpl }), /bad status/);
});
