// Atelier Capture — the localhost endpoint contract (mirrors Swift CaptureDTO).
//
// Pure request-building + a thin POST wrapper (fetch injectable for tests). The
// request shape must match Swift's `CaptureRequest`: base64 image + provenance
// (platform/originalURL/authorHandle/authorName/title/rawMetadata); collectionId
// is omitted so the app routes to its default (Unsorted) folder.

export const DEFAULT_BASE = "http://127.0.0.1:47321";
export const DEFAULT_ENDPOINT = `${DEFAULT_BASE}/ingest`;
export const DEFAULT_VIDEO_ENDPOINT = `${DEFAULT_BASE}/ingest-video`;
export const TOKEN_HEADER = "X-Atelier-Token";
export const PROVENANCE_HEADER = "X-Atelier-Provenance";

/**
 * The wire `provenance` object shared by the image and video requests: the
 * per-site fields with optionals defaulted (null / empty rawMetadata) and client
 * hints (mediaUrl/mediaKind) intentionally dropped. This is the single JS-side
 * authority for the provenance shape the Swift `ProvenanceDTO` decodes — the
 * contract fixture (`test/fixtures/`) pins it against the server.
 */
export function normalizeProvenance(provenance) {
  return {
    platform: provenance.platform,
    originalURL: provenance.originalURL ?? null,
    authorHandle: provenance.authorHandle ?? null,
    authorName: provenance.authorName ?? null,
    title: provenance.title ?? null,
    rawMetadata: provenance.rawMetadata ?? {},
  };
}

/** Build the JSON body for `POST /ingest` from provenance + a base64 image.
 * `jobId`+`sourceId` (bulk import, 3A) are included ONLY when present, so a
 * single-item capture sends the exact same body it always did. */
export function buildCaptureRequest(provenance, imageBase64, { jobId = null, sourceId = null } = {}) {
  const request = {
    image: imageBase64,
    provenance: normalizeProvenance(provenance),
  };
  if (jobId) request.jobId = jobId;
  if (sourceId) request.sourceId = sourceId;
  return request;
}

/** Build the JSON body for a MEDIA-LESS content capture (003 · C3) — e.g. a tweet
 * POSTed as `kind` + `payload`. When `imageBase64` is present the bytes ride
 * ALONGSIDE kind+payload and the server routes to the hybrid `contentWithImage`
 * path (Option 3: keeps the tweet's content identity AND stores the picture as a
 * blob card). When it's `null`/absent — a text-only tweet with no card image — the
 * `image` key is OMITTED and the server takes the pure `.content` (media-less text
 * card) path. `jobId`+`sourceId` are included only when present (parity with the
 * image body). */
export function buildContentCaptureRequest(
  provenance, imageBase64, { kind, payload }, { jobId = null, sourceId = null } = {}
) {
  const request = {
    provenance: normalizeProvenance(provenance),
    kind,
    payload,
  };
  if (imageBase64) request.image = imageBase64; // omit for a text-only (media-less) item
  if (jobId) request.jobId = jobId;
  if (sourceId) request.sourceId = sourceId;
  return request;
}

/** Build a `tweet` content descriptor (`{ kind: "tweet", payload: { tweet } }`) from
 * its parts, or `null` when it isn't a usable tweet (no id, or NEITHER text nor
 * media) so the caller falls back to a plain image / skips. `media` is ALWAYS an
 * array — Swift's `TweetPayload.media` is non-optional, so the key must always be
 * present. Shared by single-capture (`tweetContent`, one card url) and the bulk X
 * sweep (a tweet's whole media list), so the payload shape lives in ONE place. */
export function buildTweetPayload(
  { tweetID, mediaUrls = [], text = null, authorHandle = null, authorName = null } = {}
) {
  if (!tweetID) return null;
  const media = mediaUrls.filter(Boolean).map((url) => ({ url }));
  const cleanText = text || null;
  if (!cleanText && media.length === 0) return null;
  const tweet = { tweetID: String(tweetID), media };
  if (cleanText) tweet.text = cleanText;
  if (authorHandle) tweet.authorHandle = authorHandle;
  if (authorName) tweet.authorName = authorName;
  return { kind: "tweet", payload: { tweet } };
}

/** Map a single-capture twitter `provenance` to a `tweet` content descriptor for
 * `buildContentCaptureRequest`, or `null` for a non-tweet (→ plain image fallback).
 * A thin adapter over `buildTweetPayload`: the extractor's collected `media[]` (all of a
 * multi-photo tweet's photos, card first) with a fallback to the single card URL for
 * provenance that predates it, best-effort text (`provenance.title` ≈ the og:description
 * X serves). `mediaUrls` is a client hint `normalizeProvenance` drops, so only the built
 * `payload.media[]` reaches the wire. The bulk sweep builds its own descriptor (a tweet's
 * whole media list) directly from the timeline JSON. */
export function tweetContent(provenance) {
  const mediaUrls = provenance.mediaUrls?.length
    ? provenance.mediaUrls
    : (provenance.mediaUrl ? [provenance.mediaUrl] : []);
  return buildTweetPayload({
    tweetID: provenance.rawMetadata?.tweetId,
    mediaUrls,
    text: provenance.title,
    authorHandle: provenance.authorHandle,
    authorName: provenance.authorName,
  });
}

/**
 * POST a built capture request to the endpoint. `fetchImpl` defaults to the
 * global fetch (injectable for tests). Returns `{ status, body }`.
 */
export async function postCapture(
  request,
  { endpoint = DEFAULT_ENDPOINT, token, fetchImpl = fetch } = {}
) {
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      [TOKEN_HEADER]: token ?? "",
    },
    body: JSON.stringify(request),
  });
  return parseJsonResponse(response);
}

/** Read a JSON response body, tolerating an empty/non-JSON body (→ `{}`).
 * Returns `{ status, body }` — the shape every loopback POST/GET helper surfaces
 * (shared by bulk-endpoint.js's job-ledger calls too, decision 6A). */
export async function parseJsonResponse(response) {
  let body = {};
  try {
    body = await response.json();
  } catch {
    body = {};
  }
  return { status: response.status, body };
}

/** Base64 of a UTF-8 string. `btoa` is Latin1-only, but provenance (titles,
 * handles) can be non-ASCII, so encode to UTF-8 bytes first. Matches Swift's
 * `Data(base64Encoded:)` → `JSONDecoder` on the server. */
export function base64Utf8(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

/** The `X-Atelier-Provenance` header value for a video POST: base64 JSON of the
 * server's `VideoCaptureHeader` ({ provenance }). collectionId is omitted so the
 * app routes to its default (Unsorted) folder, and `mediaUrl`/`mediaKind` (client
 * hints) are not sent — only the wire provenance the server expects. */
export function buildProvenanceHeader(provenance, { jobId = null, sourceId = null } = {}) {
  const header = { provenance: normalizeProvenance(provenance) };
  if (jobId) header.jobId = jobId;
  if (sourceId) header.sourceId = sourceId;
  return base64Utf8(JSON.stringify(header));
}

/**
 * POST raw video `body` (a `Blob`, or a `Uint8Array`/`ArrayBuffer`) to the video
 * endpoint, with provenance in the `X-Atelier-Provenance` header (not the body).
 * A `Blob` lets the browser back the payload with a temp file and stream it on
 * send, so the service worker never holds the whole clip in the JS heap. Returns
 * `{ status, body }`.
 */
export async function postVideoCapture(
  body,
  { endpoint = DEFAULT_VIDEO_ENDPOINT, token, provenanceHeader, fetchImpl = fetch } = {}
) {
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      [TOKEN_HEADER]: token ?? "",
      [PROVENANCE_HEADER]: provenanceHeader,
    },
    body,
  });
  return parseJsonResponse(response);
}

// --- Version handshake (010 · Phase 3) -------------------------------------
// The app's GET /health reply carries { appVersion, minExtensionVersion,
// maxExtensionVersion }. The extension compares its own manifest version against
// that range and warns the user to update — instead of drifting silently out of
// the wire contract. Pure comparators (testable), plus a thin fetch wrapper.

/** Parse a dotted version ("a.b.c") into ints; missing/garbage parts → 0. */
export function parseVersion(v) {
  return String(v ?? "0").split(".").map((n) => parseInt(n, 10) || 0);
}

/** Compare dotted versions: -1 (a<b), 0 (a==b), 1 (a>b). */
export function compareVersions(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const da = pa[i] || 0;
    const db = pb[i] || 0;
    if (da < db) return -1;
    if (da > db) return 1;
  }
  return 0;
}

/**
 * Compare this extension's version against the app's /health handshake. Pure:
 * `health` is the parsed body { appVersion, minExtensionVersion,
 * maxExtensionVersion }. Returns { compatible, reason, appVersion }. A missing
 * range (an older app that predates the handshake) is treated as compatible —
 * unknown is not a reason to cry wolf.
 */
export function checkExtensionCompatibility(extensionVersion, health) {
  const min = health && health.minExtensionVersion;
  const max = health && health.maxExtensionVersion;
  const appVersion = (health && health.appVersion) || null;
  if (!min || !max) return { compatible: true, reason: null, appVersion };
  if (compareVersions(extensionVersion, min) < 0) {
    return {
      compatible: false,
      reason: `The extension (v${extensionVersion}) is older than the app supports (needs v${min}+). Update the extension.`,
      appVersion,
    };
  }
  if (compareVersions(extensionVersion, max) > 0) {
    return {
      compatible: false,
      reason: `The extension (v${extensionVersion}) is newer than the app supports (up to v${max}). Update the app.`,
      appVersion,
    };
  }
  return { compatible: true, reason: null, appVersion };
}

/**
 * GET /health and evaluate compatibility. `fetchImpl` injectable for tests.
 * Returns { reachable, compatible, reason, appVersion }. A network failure →
 * reachable:false (the app isn't running / the port is blocked). /health is
 * token-gated, so an unpaired extension gets `reachable:true` but can't yet read
 * the range (treated as compatible until paired).
 */
export async function fetchHealth(
  extensionVersion,
  { base = DEFAULT_BASE, token = null, fetchImpl = fetch } = {}
) {
  try {
    const headers = token ? { [TOKEN_HEADER]: token } : {};
    const res = await fetchImpl(`${base}/health`, { method: "GET", headers });
    if (!res.ok) {
      return { reachable: true, compatible: true, reason: null, appVersion: null, status: res.status };
    }
    const body = await res.json();
    return { reachable: true, ...checkExtensionCompatibility(extensionVersion, body) };
  } catch {
    return { reachable: false, compatible: true, reason: null, appVersion: null };
  }
}
