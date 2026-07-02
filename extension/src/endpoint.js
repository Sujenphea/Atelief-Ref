// Atelier Capture — the localhost endpoint contract (mirrors Swift CaptureDTO).
//
// Pure request-building + a thin POST wrapper (fetch injectable for tests). The
// request shape must match Swift's `CaptureRequest`: base64 image + provenance
// (platform/originalURL/authorHandle/authorName/title/rawMetadata); collectionId
// is omitted so the app routes to its default (Unsorted) folder.

export const DEFAULT_ENDPOINT = "http://127.0.0.1:47321/ingest";
export const TOKEN_HEADER = "X-Atelier-Token";

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
