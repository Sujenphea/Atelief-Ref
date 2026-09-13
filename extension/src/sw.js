// Atelier Capture — the service worker (the ONLY code that talks to localhost).
//
// On a user gesture (toolbar click or context-menu "Save to Atelier"), it:
//   1. injects harvestSignals into the active tab to read a raw page snapshot,
//   2. shapes it (buildHarvest) and computes provenance off-page via the pure
//      extractors,
//   3. fetches the media bytes in the authenticated session (base64 image, or a
//      streamed video Blob),
//   4. POSTs to the app's loopback endpoint with the shared-secret token,
//   5. flashes a result badge.
//
// Doing the fetch + POST here (not in a content script) is required by MV3: only
// the SW, with host_permissions, may reach http://127.0.0.1 without CORS trouble.
//
// STRUCTURE: the decision-making core (`captureCore`, `fetchImage`,
// `presentation`) is pure/injectable and unit-tested (sw.test.js). The browser-API
// event wiring at the bottom is thin glue, registered only in a real extension
// (guarded so this module imports cleanly under `node --test`). That glue goes
// through `browser.js` rather than naming `chrome` — see its header for why.

import { harvestSignals, buildHarvest } from "./harvest.js";
import { extractProvenance } from "./extractors/registry.js";
import {
  buildCaptureRequest, buildContentCaptureRequest, tweetContent,
  postCapture, buildProvenanceHeader, postVideoCapture,
} from "./endpoint.js";
import {
  resolveTwitterVideo, shouldResolveVideo as twitterHasVideo,
} from "./twitter-video.js";
import {
  resolvePinterestVideo, shouldResolveVideo as pinterestHasVideo,
} from "./pinterest-video.js";
import { fetchWithTimeout } from "./net.js";
import { planCapture, isTextCard, CAPTURE_KIND } from "./capture-plan.js";
import { MAX_VIDEO_BYTES, MAX_VIDEO_CANDIDATES } from "./config.js";
import { isBulkMessage } from "./bulk-messages.js";
import { handleBulkMessage } from "./bulk-sw.js";
import { openJob, fetchKnownSources, completeJob } from "./bulk-endpoint.js";
import { withBase } from "./base-url.js";
import { browser } from "./browser.js";

const TOKEN_KEY = "atelierToken";
const B64_CHUNK = 0x8000; // 32 KB per String.fromCharCode.apply — see bytesToBase64

// ---------------------------------------------------------------------------
// Core (pure / injectable — no browser API), unit-tested.
// ---------------------------------------------------------------------------

/** Base64 of a byte array, chunked so a large image doesn't do millions of
 * single-char string concatenations (which janked the SW on big captures).
 * `endpoint.js`'s `base64Utf8` stays separate — it only encodes small strings. */
function bytesToBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += B64_CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + B64_CHUNK));
  }
  return btoa(binary);
}

/**
 * Fetch the first working URL (in the authenticated session) and base64-encode
 * the bytes. Tries each candidate in order so a full-res URL that 404s falls back
 * to the rendered one. REQUIRES an `image/*` content-type — a non-image type OR a
 * MISSING one (3B) is refused, so an error/login/HTML page (which often omits the
 * header entirely) can't be "successfully" ingested as garbage bytes. Throws if none
 * succeed. Returns `{ base64, url, contentType, byteLength }`. `fetchImpl` is injectable.
 * `maxBytes` (13A — the server's authoritative image-body cap for a bulk sweep) rejects
 * an over-cap image from its declared Content-Length BEFORE reading the body (mirroring
 * the video path), so a doomed huge file isn't fully downloaded only to be 413'd. Null
 * (single-item capture) skips the pre-check; the server stays the backstop either way.
 */
export async function fetchImage(urls, { fetchImpl = fetch, maxBytes = null } = {}) {
  let lastError = new Error("No media URL to fetch.");
  for (const url of urls) {
    try {
      const response = await fetchWithTimeout(url, {}, { fetchImpl });
      if (!response.ok) {
        // Carry the numeric status on the error so ingestOne can surface it (5A): the
        // engine's classifier turns a 401/403 into a resumable auth-wall halt.
        lastError = Object.assign(new Error(`HTTP ${response.status} for ${url}`),
          { httpStatus: response.status });
        continue;
      }
      const contentType = response.headers.get("content-type") || "";
      if (!contentType.startsWith("image/")) {
        lastError = new Error(`Non-image response (${contentType || "no content-type"}) for ${url}`);
        continue;
      }
      // Declared-size pre-check (13A). Over-cap → skip to the next candidate (a smaller
      // rendered variant may fit). Absent Content-Length → proceed; the server caps it.
      if (maxBytes) {
        const declared = Number(response.headers.get("content-length") || 0);
        if (declared > maxBytes) {
          lastError = new Error(`image too large (${declared} > ${maxBytes} bytes) for ${url}`);
          continue;
        }
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      return {
        base64: bytesToBase64(bytes),
        url,
        contentType: contentType || null,
        byteLength: bytes.length,
      };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

/** Download the resolved MP4 and POST it to the video endpoint. Returns
 * `{ deduplicated }`; THROWS on any failure so the caller can fall back to the
 * poster image. The body is a `Blob` (browser-backed, streamed on send) so the
 * whole clip never sits in the JS heap. A non-200 ingest also throws. `maxBytes`
 * (13A — the server's authoritative video cap for a bulk sweep) overrides the
 * `MAX_VIDEO_BYTES` default; null/absent falls back to that constant (single-item). */
export async function downloadAndIngestVideo(
  provenance, mp4Url, token, { fetchImpl = fetch, jobId = null, sourceId = null, maxBytes = null } = {}
) {
  const response = await fetchWithTimeout(mp4Url, {}, { fetchImpl });
  // Every throw below is TAGGED (`videoStage`, and `httpStatus` where there is one), because
  // `ingestOne` now has to tell "this rung is bad, take the next one" from "the network is
  // down, stop walking" — and a thrown string message is not something to re-parse. See
  // `videoCandidateVerdict`.
  if (!response.ok) {
    throw Object.assign(new Error(`video HTTP ${response.status} for ${mp4Url}`),
      { videoStage: "download", httpStatus: response.status });
  }
  const contentType = response.headers.get("content-type") || "";
  if (contentType && !contentType.startsWith("video/")) {
    // No `httpStatus`: the request was fine and the BODY is not a video (a CDN error page,
    // a rehosted still). Another shard of the same rung, or the next rung, may serve.
    throw Object.assign(new Error(`non-video response (${contentType})`), { videoStage: "download" });
  }
  // Reject an over-cap clip from its declared size BEFORE reading the body, so a
  // huge MP4 isn't fully downloaded only for the server to 413 it. (Absent on a
  // chunked response — then we proceed and the server's cap is the backstop.) The
  // server's authoritative cap (13A) overrides the local default when supplied.
  const limit = maxBytes || MAX_VIDEO_BYTES;
  const declaredBytes = Number(response.headers.get("content-length") || 0);
  if (declaredBytes > limit) {
    throw Object.assign(new Error(`video too large (${declaredBytes} > ${limit} bytes)`),
      { videoStage: "download" });
  }
  const blob = await response.blob();
  // Resolved host, not the hard-coded 47321 (301) — the dev build listens on 47322.
  const { status, body } = await withBase((base) => postVideoCapture(blob, {
    endpoint: `${base}/ingest-video`,
    token,
    provenanceHeader: buildProvenanceHeader(provenance, { jobId, sourceId }),
  }), { token });
  if (status !== 200) {
    throw Object.assign(new Error(body.error || `ingest HTTP ${status}`),
      { videoStage: "ingest", httpStatus: status });
  }
  return { deduplicated: !!body.deduplicated };
}

/**
 * What a failed video candidate means for the ladder: `"advance"` (try the next candidate)
 * or `"stop"` (this failure is not the rung's fault — stop walking).
 *
 * 020 rule 2 is the whole reason this exists: **`thumbnailFailed` means "advance the
 * ladder", not "fail the item"**, and the HTTP 422 from `/ingest-video` is precisely the
 * undecodable-rung signal. The manual harvest learned it by shipping an `ef51` stream that
 * nothing could decode; the 422 is the app telling us that from the other side, and it must
 * never become a `permanentFailed`.
 *
 * The three cases, each decided rather than defaulted:
 *
 *   · **422 from the ingest** → ADVANCE. The bytes arrived and the app could not read them.
 *     Nothing about the next rung is implied by that, so try it. Any OTHER ingest status
 *     stops: a 401/403 is a bad token (session-wide — walking the ladder would burn the
 *     whole board against it), a 5xx is our own app being unwell, a 413 means the next rung
 *     is likely bigger, not smaller.
 *   · **404 / 410 from the CDN** → ADVANCE, and deliberately NOT "retryable". 020 B3 is the
 *     evidence: the same note served a DIFFERENT ladder on two visits minutes apart, so a
 *     stream url that 404s is a rung that has moved, not a hiccup. Retrying the same url
 *     cannot fix it, and the fix it CAN have is sitting next in the list — a backup shard
 *     carrying the same object, or the next rung entirely. A retryable classification would
 *     spend the item's four backoff attempts re-fetching a url that is gone.
 *   · **A transport failure** (the fetch threw: DNS, timeout, abort) → STOP. It says nothing
 *     about this rung, so walking the rest of the ladder means N dead requests instead of
 *     one, and the engine ALREADY has the right mechanism: the item is re-relayed with
 *     backoff, which re-resolves the ladder from the note's response — which is what 020 B3
 *     asks for anyway. Same for any CDN status that is not 404/410 (a 429 or 5xx is the
 *     CDN's state, not this rung's; a 401/403 is an auth wall the engine halts on).
 *
 * A `download` failure with NO status is the third shape: the response was fine and its
 * body was not usable (a non-video content-type, or an over-cap clip). That is a property
 * of THIS candidate, so it advances.
 */
export function videoCandidateVerdict(error) {
  const stage = error && error.videoStage;
  const status = error && error.httpStatus;
  if (stage === "ingest") return status === 422 ? "advance" : "stop";
  if (stage === "download") {
    if (status == null) return "advance";
    return status === 404 || status === 410 ? "advance" : "stop";
  }
  return "stop";
}

/** Real implementations the core uses; overridden wholesale in tests. */
const defaultDeps = {
  extractProvenance,
  twitterHasVideo,
  resolveTwitterVideo,
  pinterestHasVideo,
  resolvePinterestVideo,
  fetchImage,
  downloadAndIngestVideo,
  buildCaptureRequest,
  buildContentCaptureRequest,
  tweetContent,
  // Wrapped so the ingest host is RESOLVED per call (301): the core passes only
  // `{ token }`, and this supplies the `endpoint` for whichever build is up.
  postCapture: (request, opts = {}) => withBase(
    (base) => postCapture(request, { ...opts, endpoint: `${base}/ingest` }),
    { token: opts.token }),
  log: (...args) => console.log("[Atelier]", ...args),
  logError: (...args) => console.error("[Atelier]", ...args),
};

/**
 * The full capture decision, as a pure function returning a semantic result (the
 * glue maps it to a badge via `presentation`). Fail-OPEN on video: a resolution
 * failure is EXPECTED (not a video / the platform API changed) → quiet log; a
 * RESOLVED video that then fails to download/ingest is UNEXPECTED → loud log; both
 * fall back to the still image, so a capture is never worse than before.
 */
export async function captureCore(harvest, context, token, deps = defaultDeps) {
  const provenance = deps.extractProvenance(harvest, context);
  // A tweet with no image but real substance (a text-only tweet) is still capturable
  // as a text card (003 · C3): compute the content descriptor up front and bail only
  // when there's NEITHER an image NOR usable tweet content. `ingestOne` then posts a
  // media-less content capture when there's a descriptor but no media URL.
  const content = deps.tweetContent(provenance);
  // **"Is there anything to capture" is `planCapture`'s question, asked once.**
  //
  // This used to be `!provenance.mediaUrl && !content`, hand-written here — a second,
  // NARROWER copy of the decision `capture-plan.js` was extracted to own (096 § D7). It
  // ignored `mediaUrlFallback`, which `planCapture` counts: the plan builds its candidates
  // from `[mediaUrl, mediaUrlFallback].filter(Boolean)`.
  //
  // That was not a live bug. `mediaUrl` is null only when `rendered` is null, and every
  // rewrite helper is total — `toOrigName` returns `src` on a parse failure, `toOriginals`
  // returns `src` when its regex misses, `toRednoteOriginal` returns `src` in every branch
  // — so `mediaUrl == null` implies `mediaUrlFallback == null` across all five extractors
  // today. It held by an invariant spread over five files and asserted nowhere, and the
  // shape that breaks it is the natural one to write: a regex-replace helper returning
  // `null` when it does not match. The failure would have been silent — a capture reporting
  // `no-image` and quietly lost with a usable fallback URL sitting in its provenance.
  //
  // The invariant is now pinned in `extractors.test.js` as well. Belt and braces: the test
  // documents what the extractors promise, and this asks the authority anyway.
  //
  // No `mp4Url` yet — resolution needs the network and happens below. That is deliberate
  // and matches what the hand-written test did: a video post carries a poster or a frame,
  // so its `mediaUrl` is set and the plan is never `none`. A post with neither a still nor
  // content was already rejected here before any video call, and still is.
  if (planCapture(provenance, { content }).kind === CAPTURE_KIND.none) {
    return { status: "no-image" };
  }
  if (!token) return { status: "no-token" };

  // Video DETECTION + resolution is single-item-specific: it reads harvest/context
  // (the bulk engine resolves video from structured JSON instead). A failure here
  // is EXPECTED (not a video / the platform API changed) → quiet log, fall through.
  // The resolved mp4Url (or null) is handed to the shared ingestOne tail.
  let mp4Url = null;
  try {
    if (deps.twitterHasVideo(provenance, context)) {
      mp4Url = await deps.resolveTwitterVideo(provenance.rawMetadata.tweetId);
    } else if (deps.pinterestHasVideo(provenance, harvest)) {
      mp4Url = await deps.resolvePinterestVideo(provenance.rawMetadata.pinId);
    }
  } catch (error) {
    deps.log("no video / resolution failed → image fallback:", String(error));
    mp4Url = null;
  }

  // A single-item tweet capture (003 · C3, Option 3): a usable tweet POSTs as a
  // `tweet` content item — carrying its card image when present, or media-less (a text
  // card) when the focal tweet has no image. `content` is null for a non-tweet → the
  // plain image path. (Computed above so a text-only tweet isn't rejected as no-image.)
  return ingestOne(provenance, { token, mp4Url, content }, deps);
}

/**
 * The shared ingest TAIL (decision 5A): given a `provenance` and an already-
 * resolved optional `mp4Url`, fetch the media bytes in the authenticated session
 * and POST to the app — the SAME path single-item capture and the bulk engine both
 * use. `jobId`+`sourceId` (bulk, 3A) tag the POST so the app records a job_item;
 * single-item capture omits them. Fail-OPEN on video: a RESOLVED video that then
 * fails to download/ingest is UNEXPECTED → loud log, then falls back to the still
 * image, so a capture is never worse than before. Pure/injectable — no browser API.
 *
 * `videoCandidates` is the ORDERED fallback ladder behind `mp4Url` (098 D5): a 422 from
 * `/ingest-video` advances to the next one rather than failing the item (020 rule 2).
 * Absent for the three platforms that resolve a single url, so their walk is one attempt.
 */
export async function ingestOne(
  provenance,
  { token, mp4Url = null, videoCandidates = [], jobId = null, sourceId = null,
    caps = null, content = null } = {},
  deps = defaultDeps
) {
  // Server byte caps (13A): a bulk relay carries the job's authoritative limits so the
  // pre-download size checks use them; single-item capture passes no caps (null → the
  // local defaults / no image pre-check apply, with the server as backstop).
  const maxImageBytes = caps ? (caps.maxBodyBytes ?? null) : null;
  const maxVideoBytes = caps ? (caps.maxVideoBodyBytes ?? null) : null;

  // The DECISION (096 § D7) — which URLs, in what order, video or still, text card or not.
  // Shared with tier 3, which consumes the same plan and hands it to the native handler
  // instead of fetching here. This function keeps only the localhost transport.
  const plan = planCapture(provenance, { mp4Url, content, videoCandidates });

  // Nothing to capture. `captureCore` asks the same question before it spends a token
  // check or a video resolution, so this is unreachable from there — but `ingestOne` is
  // also the bulk engine's tail and tier 3's, and reaching here with an empty plan used
  // to fall through to `fetchImage([])`, which throws its "No media URL to fetch."
  // placeholder and surfaces as a fetch-error: a sweep item classified as a network
  // failure when in fact there was simply nothing on the post. The plan already says so;
  // this reports what it says.
  if (plan.kind === CAPTURE_KIND.none) {
    return { status: "no-image", reason: plan.reason };
  }

  // WALK the candidate list (098 D5). For X, Instagram and Pinterest that list is one
  // element — the single url they resolved — so this loop runs once and does exactly what
  // the single `try` before it did. rednote hands over a whole ladder, and a 422 advances
  // it: WITHIN a rung first (`master_url`, then each `backup_urls[]` entry — the same object
  // on another CDN shard), then between rungs. The order is `rednote-video.js`'s and is
  // walked as given; re-deriving it here would be a second copy of 020 rule 1.
  let videoSkip = null;
  if (plan.kind === CAPTURE_KIND.video) {
    // Bounded (020's ladder is plural in two directions and each attempt is a whole
    // download): past the cap the honest answer is the cover still, not a longer walk.
    const ladder = plan.videoCandidates.slice(0, MAX_VIDEO_CANDIDATES);
    let attempts = 0;
    let verdict = "advance";
    let lastError = null;
    for (const url of ladder) {
      attempts += 1;
      try {
        const { deduplicated } = await deps.downloadAndIngestVideo(
          provenance, url, token, { jobId, sourceId, maxBytes: maxVideoBytes });
        // The SAME result shape a single-try ingest returned before the walk existed — no
        // `attempt` field, deliberately: three of the four platforms pass a one-element
        // list, and a result that differed by platform would be a second thing to keep in
        // step. Which rung won is in the log line above it, where a diagnostic belongs.
        return { status: "saved", kind: "video", deduplicated };
      } catch (error) {
        lastError = error;
        verdict = videoCandidateVerdict(error);
        if (verdict === "advance" && attempts < ladder.length) {
          // Quiet: a refused rung is the ladder working, not a fault. The LOUD line is the
          // one below, when the whole ladder is spent.
          deps.log(`video candidate ${attempts}/${ladder.length} refused → advancing:`, String(error));
          continue;
        }
        break;
      }
    }
    videoSkip = {
      reason: verdict === "advance" ? "video-ladder-exhausted" : "video-failed",
      attempts,
      candidates: plan.videoCandidates.length,
      message: String(lastError || "no video candidate"),
    };
    // A resolved video should normally ingest, so both endings are UNEXPECTED and loud —
    // but the still candidates the plan carried alongside it are still tried below.
    deps.logError(
      verdict === "advance"
        ? `every video candidate was refused (${attempts} of ${plan.videoCandidates.length}) → still fallback:`
        : "resolved video failed to download/ingest → still fallback:",
      lastError);
  }

  // EXHAUSTING THE LADDER IS A TYPED SKIP, NOT A FAILED ITEM (020, Risks & edge cases: "the
  // honest outcome is cover-still-only for that note; record it as a typed skip, do not fail
  // the sweep"). When the plan carries still candidates — every X / Instagram / Pinterest
  // video, whose poster IS the fallback — the fail-open path below keeps the cover and this
  // never fires. It fires for a rednote stream item, which deliberately carries no still:
  // its poster is already ingested under `<note_id>` by the cover pass, and re-enqueueing it
  // here would be the exact one-picture-two-keys duplicate 098 T5a refused video notes to
  // avoid. `classifyIngestResult` maps this to `skipped`, so the note keeps its cover, the
  // sweep stays clean, and nothing is recorded as permanently failed.
  //
  // (A video plan with CONTENT but no still still falls through to the fetch below, exactly
  // as it did before this walk existed — unreachable today, and not this change's to move.)
  if (videoSkip && plan.urlCandidates.length === 0 && !content) {
    return { status: "skipped", reason: videoSkip.reason, video: videoSkip };
  }

  // Build the POST body. A media-less content item (a text-only tweet has NO card
  // image) posts kind+payload with no image → the server's `.content` text-card path.
  // This fires ONLY when there's genuinely no media URL to fetch; a FETCH FAILURE must
  // still surface as fetch-error (so a 401/403 auth wall halts the sweep, 5A), never
  // silently downgrade a picture tweet to a text card.
  let request;
  if (isTextCard(plan)) {
    request = deps.buildContentCaptureRequest(provenance, null, content, { jobId, sourceId });
  } else {
    let fetched;
    try {
      fetched = await deps.fetchImage(plan.urlCandidates, { maxBytes: maxImageBytes });
    } catch (error) {
      // Thread the CDN's HTTP status through (5A) so a 401/403 auth wall halts the sweep
      // resumable rather than burning through the rest of the board as permanent fails.
      return {
        status: "fetch-error",
        httpStatus: error.httpStatus ?? null,
        message: `Could not fetch the image (${String(error)}).`,
      };
    }
    // A tweet content-capture (Option 3) carries the SAME card-image bytes but as a
    // `tweet` content item (kind + payload); otherwise the plain image body.
    request = content
      ? deps.buildContentCaptureRequest(provenance, fetched.base64, content, { jobId, sourceId })
      : deps.buildCaptureRequest(provenance, fetched.base64, { jobId, sourceId });
  }

  try {
    const { status, body } = await deps.postCapture(request, { token });
    if (status === 200) {
      const result = {
        status: "saved", kind: content ? "tweet" : "image",
        deduplicated: !!body.deduplicated,
      };
      // Bulk relay feedback (7A): the app stamps the job's status on a tagged reply
      // so a user pause/cancel halts the sweep. Absent on single-item captures.
      if (body.jobStatus) result.jobStatus = body.jobStatus;
      return result;
    }
    // Surface the app's status (5A): a 401/403 (bad/expired token) is an auth wall the
    // classifier halts on; a 5xx is transient; other 4xx are per-item permanent.
    return { status: "ingest-error", httpStatus: status, message: body.error || `HTTP ${status}` };
  } catch {
    return { status: "unreachable" };
  }
}

/** Map a capture result to a badge `{ text, color, title }`. */
export function presentation(result) {
  switch (result.status) {
    case "no-image":
      return { text: "?", color: "#e08c00", title: "No image found on this page." };
    case "skipped":
      // A typed skip, not an error: every video candidate was refused and there was no
      // still to fall back to. Warning-coloured like `no-image`, because nothing was saved
      // and nothing is broken. Unreachable from single-item capture today (every platform
      // it serves carries a poster), and mapped anyway so the tail cannot fall through to
      // the generic "Capture failed."
      return { text: "?", color: "#e08c00", title: "No usable video — the still was kept." };
    case "no-token":
      return { text: "KEY", color: "#e08c00", title: "Set your Atelier token in the extension options." };
    case "saved":
      return {
        text: "✓", color: "#2e8b57",
        title: result.deduplicated
          ? "Already saved."
          : result.kind === "video" ? "Saved video to Atelier." : "Saved to Atelier.",
      };
    case "ingest-error":
      return { text: "ERR", color: "#cc3333", title: result.message || "Ingest failed." };
    case "fetch-error":
      return { text: "ERR", color: "#cc3333", title: result.message || "Could not fetch the image." };
    case "unreachable":
      return { text: "ERR", color: "#cc3333", title: "Could not reach Atelier — is the app running?" };
    default:
      return { text: "ERR", color: "#cc3333", title: String(result.message || "Capture failed.") };
  }
}

// ---------------------------------------------------------------------------
// Glue (the browser API, via ./browser.js) — thin, registered only in a real
// extension.
// ---------------------------------------------------------------------------

/** The saved shared-secret token, or "" if unset. */
async function getToken() {
  const stored = await browser.storage.local.get(TOKEN_KEY);
  return stored[TOKEN_KEY] || "";
}

/** Full capture flow for one tab, given the right-clicked `context` (or {}). */
async function capture(tab, context) {
  if (!tab?.id) return;
  clearBadge(); // 8A: drop any stale badge from a prior capture up front

  let raw;
  try {
    const [injection] = await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: harvestSignals,
    });
    raw = injection?.result;
  } catch {
    return flash("ERR", "#cc3333", "Could not read the page.");
  }
  if (!raw) return flash("ERR", "#cc3333", "Could not read the page.");

  const harvest = buildHarvest(raw);
  const token = await getToken();
  const result = await captureCore(harvest, context, token);
  const { text, color, title } = presentation(result);
  flash(text, color, title);
}

/** Brief action-badge feedback (title carries the full message). */
function flash(text, color, title) {
  browser.action.setBadgeBackgroundColor({ color });
  browser.action.setBadgeText({ text });
  if (title) browser.action.setTitle({ title: `Atelier — ${title}` });
  // Best-effort auto-clear; an MV3 SW may be torn down before it fires, so the
  // next capture also clears the badge up front (see capture()).
  setTimeout(() => browser.action.setBadgeText({ text: "" }), 4000);
}

/** Clear the badge immediately (no title change). */
function clearBadge() {
  browser.action.setBadgeText({ text: "" });
}

if (browser.runtime && browser.runtime.onMessage) {
  // Thin bulk relay: the content-script controller messages the SW for every
  // localhost op (only the SW reaches 127.0.0.1). Each message resets the SW idle
  // timer, which is what keeps it alive across a long sweep. An error is returned as
  // an `{ __error }` envelope the controller's transport rethrows (→ engine halt).
  browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!isBulkMessage(message)) return false;
    getToken()
      .then((token) => handleBulkMessage(message, {
        token, fetchImpl: fetch, ingestOne, openJob, fetchKnownSources, completeJob,
      }))
      .then((payload) => sendResponse(payload))
      .catch((error) => sendResponse({ __error: String(error) }));
    return true; // keep the message channel open for the async sendResponse
  });
}

if (browser.action && browser.contextMenus) {
  // NB: the toolbar action now opens the popup (manifest `action.default_popup`), so
  // `action.onClicked` no longer fires — single-item capture lives on the
  // right-click context menu below (and the popup launches sweeps).
  browser.runtime.onInstalled.addListener(() => {
    // removeAll first so a re-install/update can't throw "duplicate id". The shim
    // hands back a promise on both engines (Chrome's form here is callback-only in
    // practice; Safari's rejects a callback outright) — see browser.js.
    browser.contextMenus.removeAll().then(() => {
      browser.contextMenus.create({
        id: "atelier-save",
        title: "Save to Atelier",
        contexts: ["page", "image", "link"],
      });
    });
  });

  browser.contextMenus.onClicked.addListener((info, tab) => {
    // The right-clicked element: exact image + its link — far more reliable than
    // guessing from the page (esp. capturing a pin from the feed).
    const context = {
      srcUrl: info.srcUrl || null,
      linkUrl: info.linkUrl || null,
      pageUrl: info.pageUrl || null,
    };
    if (tab) capture(tab, context).catch((error) => flash("ERR", "#cc3333", String(error)));
  });
}
