// Atelier Capture — the loopback /jobs contract (bulk import, decision 3A).
//
// The SW-side wrappers for the job-ledger handshake the app exposes: open a sweep,
// load its known-source skip set (P14), close it. Mirrors Swift's `JobResponse`
// DTO (JobDTO.swift) — a rename on either side breaks a test here or a route test
// there. Pure request-building + a thin fetch wrapper (fetchImpl injectable). Only
// the SW calls these (a content script can't reach 127.0.0.1 without CORS); the
// content-script controller reaches them by messaging the SW.

import { DEFAULT_BASE, TOKEN_HEADER } from "./endpoint.js";
import { fetchWithTimeout } from "./net.js";

/** One authenticated JSON call to a /jobs route. Returns `{ status, body }`,
 * tolerating an empty/non-JSON body (→ `{}`). */
async function jobFetch(path, { method = "GET", payload = null, token, fetchImpl = fetch } = {}) {
  const headers = { [TOKEN_HEADER]: token ?? "" };
  if (payload) headers["Content-Type"] = "application/json";
  const response = await fetchWithTimeout(
    `${DEFAULT_BASE}${path}`,
    { method, headers, ...(payload ? { body: JSON.stringify(payload) } : {}) },
    { fetchImpl }
  );
  let body = {};
  try { body = await response.json(); } catch { body = {}; }
  return { status: response.status, body };
}

/** `POST /jobs` — open a sweep. Returns `{ jobId, caps }` (caps = the server's
 * authoritative byte limits, 8A). Throws on any non-`created` response. */
export async function openJob(
  { platform, scope = null, totalEstimate = null }, { token, fetchImpl } = {}
) {
  const { status, body } = await jobFetch("/jobs", {
    method: "POST", payload: { platform, scope, totalEstimate }, token, fetchImpl,
  });
  if (status !== 201 || body.status !== "created" || !body.jobId) {
    throw new Error(body.error || `open job failed (HTTP ${status})`);
  }
  return { jobId: body.jobId, caps: body.caps || null };
}

/** `GET /jobs/{id}/known-sources` — the sourceIds already ingested for this
 * platform (loaded once into the engine's skip set, P14). */
export async function fetchKnownSources(jobId, { token, fetchImpl } = {}) {
  const { status, body } = await jobFetch(
    `/jobs/${encodeURIComponent(jobId)}/known-sources`, { token, fetchImpl });
  if (status !== 200 || !Array.isArray(body.sourceIds)) {
    throw new Error(body.error || `known-sources failed (HTTP ${status})`);
  }
  return body.sourceIds;
}

/** `POST /jobs/{id}/complete` — close/transition a sweep. `status` ∈ complete |
 * paused | halted (the engine maps its terminal state to one of these). */
export async function completeJob(jobId, status = "complete", { token, fetchImpl } = {}) {
  const { status: httpStatus, body } = await jobFetch(
    `/jobs/${encodeURIComponent(jobId)}/complete`,
    { method: "POST", payload: { status }, token, fetchImpl });
  if (httpStatus !== 200) throw new Error(body.error || `complete failed (HTTP ${httpStatus})`);
  return true;
}
