// Atelier Capture — the loopback /jobs contract (bulk import, decision 3A).
//
// The SW-side wrappers for the job-ledger handshake the app exposes: open a sweep,
// load its known-source skip set (P14), close it. Mirrors Swift's `JobResponse`
// DTO (JobDTO.swift) — a rename on either side breaks a test here or a route test
// there. Pure request-building + a thin fetch wrapper (fetchImpl injectable). Only
// the SW calls these (a content script can't reach 127.0.0.1 without CORS); the
// content-script controller reaches them by messaging the SW.

import { TOKEN_HEADER, parseJsonResponse } from "./endpoint.js";
import { fetchWithTimeout } from "./net.js";
import { withBase } from "./base-url.js";

/** One authenticated JSON call to a /jobs route. Returns `{ status, body }`,
 * tolerating an empty/non-JSON body (→ `{}`) via the shared `parseJsonResponse` (6A —
 * the same tolerant parser the /ingest helpers use, so the two can't drift).
 *
 * The host is RESOLVED, not hard-coded (301): the dev build listens on 47322, and
 * a sweep opens with `POST /jobs`, so a wrong port used to kill the run on its very
 * first call with `TypeError: Failed to fetch`. `withBase` also re-probes once if
 * the connection is refused mid-sweep (the app was restarted, or swapped builds). */
async function jobFetch(
  path, { method = "GET", payload = null, token, fetchImpl = fetch, storage } = {}
) {
  const headers = { [TOKEN_HEADER]: token ?? "" };
  if (payload) headers["Content-Type"] = "application/json";
  return withBase(async (base) => {
    const response = await fetchWithTimeout(
      `${base}${path}`,
      { method, headers, ...(payload ? { body: JSON.stringify(payload) } : {}) },
      { fetchImpl }
    );
    return parseJsonResponse(response);
  }, { token, fetchImpl, storage });
}

/** `POST /jobs` — open a sweep. Returns `{ jobId, caps }` (caps = the server's
 * authoritative byte limits, 8A). Throws on any non-`created` response. */
export async function openJob(
  { platform, scope = null, totalEstimate = null, resumeJobId = null },
  { token, fetchImpl, storage } = {}
) {
  // `resumeJobId` (task 8) asks the app to REOPEN a still-resumable job so a resumed
  // sweep stays one ledger row; omitted for a fresh sweep. The app falls back to a new
  // job if it isn't resumable, so sending a stale id is always safe.
  const payload = { platform, scope, totalEstimate };
  if (resumeJobId) payload.resumeJobId = resumeJobId;
  const { status, body } = await jobFetch("/jobs", {
    method: "POST", payload, token, fetchImpl, storage,
  });
  if (status !== 201 || body.status !== "created" || !body.jobId) {
    throw new Error(body.error || `open job failed (HTTP ${status})`);
  }
  return { jobId: body.jobId, caps: body.caps || null };
}

/** `GET /jobs/{id}/known-sources` — the sourceIds already ingested for this
 * platform (loaded once into the engine's skip set, P14). */
export async function fetchKnownSources(jobId, { token, fetchImpl, storage } = {}) {
  const { status, body } = await jobFetch(
    `/jobs/${encodeURIComponent(jobId)}/known-sources`, { token, fetchImpl, storage });
  if (status !== 200 || !Array.isArray(body.sourceIds)) {
    throw new Error(body.error || `known-sources failed (HTTP ${status})`);
  }
  return body.sourceIds;
}

/** `POST /jobs/{id}/complete` — close/transition a sweep. `status` ∈ complete |
 * paused | halted (the engine maps its terminal state to one of these). */
export async function completeJob(jobId, status = "complete", { token, fetchImpl, storage } = {}) {
  const { status: httpStatus, body } = await jobFetch(
    `/jobs/${encodeURIComponent(jobId)}/complete`,
    { method: "POST", payload: { status }, token, fetchImpl, storage });
  if (httpStatus !== 200) throw new Error(body.error || `complete failed (HTTP ${httpStatus})`);
  return true;
}
