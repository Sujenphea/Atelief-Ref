// Atelier Capture — the localhost endpoint contract (mirrors Swift CaptureDTO).
//
// Pure request-building + a thin POST wrapper (fetch injectable for tests). The
// request shape must match Swift's `CaptureRequest`: base64 image + provenance
// (platform/originalURL/authorHandle/authorName/title/rawMetadata); collectionId
// is omitted so the app routes to its default (Unsorted) folder.

export const DEFAULT_ENDPOINT = "http://127.0.0.1:47321/ingest";
export const DEFAULT_VIDEO_ENDPOINT = "http://127.0.0.1:47321/ingest-video";
export const TOKEN_HEADER = "X-Atelier-Token";
export const PROVENANCE_HEADER = "X-Atelier-Provenance";

/** Build the JSON body for `POST /ingest` from provenance + a base64 image. */
export function buildCaptureRequest(provenance, imageBase64) {
  return {
    image: imageBase64,
    provenance: {
      platform: provenance.platform,
      originalURL: provenance.originalURL ?? null,
      authorHandle: provenance.authorHandle ?? null,
      authorName: provenance.authorName ?? null,
      title: provenance.title ?? null,
      rawMetadata: provenance.rawMetadata ?? {},
    },
  };
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
export function buildProvenanceHeader(provenance) {
  const header = {
    provenance: {
      platform: provenance.platform,
      originalURL: provenance.originalURL ?? null,
      authorHandle: provenance.authorHandle ?? null,
      authorName: provenance.authorName ?? null,
      title: provenance.title ?? null,
      rawMetadata: provenance.rawMetadata ?? {},
    },
  };
  return base64Utf8(JSON.stringify(header));
}

/**
 * POST raw video `bytes` (a Uint8Array/ArrayBuffer) to the video endpoint, with
 * provenance in the `X-Atelier-Provenance` header (not the body). Returns
 * `{ status, body }`.
 */
export async function postVideoCapture(
  bytes,
  { endpoint = DEFAULT_VIDEO_ENDPOINT, token, provenanceHeader, fetchImpl = fetch } = {}
) {
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      [TOKEN_HEADER]: token ?? "",
      [PROVENANCE_HEADER]: provenanceHeader,
    },
    body: bytes,
  });
  let body = {};
  try {
    body = await response.json();
  } catch {
    body = {};
  }
  return { status: response.status, body };
}
