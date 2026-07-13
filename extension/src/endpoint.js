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

/** Build the JSON body for a MEDIA-LESS content capture that ALSO carries a card
 * image (003 · C3, Option 3) — e.g. a tweet POSTed with its picture. Mirrors
 * Swift's `CaptureRequest` with `kind` + `payload` set ALONGSIDE the base64
 * image; the server routes it to the hybrid `contentWithImage` path (an asset
 * that keeps its tweet content identity AND stores the picture as a blob).
 * `jobId`+`sourceId` are included only when present (parity with the image body). */
export function buildContentCaptureRequest(
  provenance, imageBase64, { kind, payload }, { jobId = null, sourceId = null } = {}
) {
  const request = {
    image: imageBase64,
    provenance: normalizeProvenance(provenance),
    kind,
    payload,
  };
  if (jobId) request.jobId = jobId;
  if (sourceId) request.sourceId = sourceId;
  return request;
}

/** Map a twitter `provenance` to a `tweet` content descriptor
 * (`{ kind: "tweet", payload: { tweet } }`) for `buildContentCaptureRequest`, or
 * `null` when it isn't a usable tweet (no tweet id, or NEITHER text nor media) so
 * the caller falls back to the plain image capture. `media` is ALWAYS an array —
 * Swift's `TweetPayload.media` is non-optional, so the key must always be present.
 * The tweet TEXT is best-effort (`provenance.title` ≈ the og:description X serves);
 * the server extracts the numeric id from `tweetID` and validates the substance. */
export function tweetContent(provenance) {
  const tweetId = provenance.rawMetadata?.tweetId;
  if (!tweetId) return null;
  const text = provenance.title || null;
  const media = provenance.mediaUrl ? [{ url: provenance.mediaUrl }] : [];
  if (!text && media.length === 0) return null;
  const tweet = { tweetID: String(tweetId), media };
  if (text) tweet.text = text;
  if (provenance.authorHandle) tweet.authorHandle = provenance.authorHandle;
  if (provenance.authorName) tweet.authorName = provenance.authorName;
  return { kind: "tweet", payload: { tweet } };
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
