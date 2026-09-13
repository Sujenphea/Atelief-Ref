// Atelier Capture — rednote board-feed parser + push→pull source (098 T2, K3a).
//
// The board feed is INTERCEPTED, never requested: rednote signs every API call with an
// `X-s` derived from the URL and an `X-t` timestamp, and a hand-signed request was tried
// and refused with HTTP 461 (098 D1). So the page makes its own calls, `hook-core.js`
// forwards the responses, and this file only ever PARSES what arrived. A signature-scheme
// change therefore cannot break the sweep — there is no signature on our side to break.
//
// The endpoint, verified live 2026-09-13:
//   GET //webapi.rednote.com/api/sns/web/v1/board/note
//         ?board_id=<24-hex>&num=30&cursor=<hex>&image_formats=jpg,webp,avif
// Note the PROTOCOL-RELATIVE form — that is what the XHR path hands over, and `new URL()`
// throws on it unaided. Every URL reader here takes a base for exactly that reason.
//
// FAN-OUT: one `BulkItem` per NOTE, keyed by `note_id`, carrying the note's COVER. This
// is the whole shape of K3a and it is forced by the data: a feed row has nine keys and
// holds a single `cover` — no `imageList`, no `video`, no `stream`. Doc 020 planned a
// per-carousel-image fan-out from this response; that data is not in it. Carousels and
// video need a per-note detail fetch (K3b, 098 D4), which is a separate phase.
//
// A yielded `BulkItem` matches the engine seam:
//   { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor, xsecToken }
// `cursor` and `xsecToken` are LOCAL fields — the relay sends only `sourceId` and
// `provenance` (the twitter driver's `content` field works the same way).

import { makeProvenance } from "./extractors/base.js";
import { toRednoteOriginal } from "./extractors/rednote.js";

/** The board-feed path. Pinned to the PATH, deliberately not to a host: rednote's own
 * telemetry rides adjacent hosts the page also calls (`t2.rnote.com/api/v2/collect`,
 * `apm-fe.rnote.com/api/data`), and a host-shaped matcher would hoover those up. */
export const BOARD_FEED_PATH = "/api/sns/web/v1/board/note";

/** A base for parsing the protocol-relative request URLs the XHR path reports. Never used
 * to make a request — only to read the query off a string `new URL()` would otherwise
 * reject. */
const URL_BASE = "https://www.rednote.com";

/** True for a board-feed request URL (absolute or protocol-relative, ± query). */
export function isBoardFeedRequest(url) {
  return typeof url === "string" &&
    new RegExp(`${BOARD_FEED_PATH.replace(/\//g, "\\/")}(?:$|[/?])`).test(url);
}

/** One query parameter off a board-feed request URL, or null. Tolerates the
 * protocol-relative form and an unparseable string. An EMPTY value reads as absent —
 * rednote's last page returns `cursor=""`, which is not a cursor. */
function paramFromRequestURL(url, name) {
  if (typeof url !== "string" || !url) return null;
  try {
    return new URL(url, URL_BASE).searchParams.get(name) || null;
  } catch {
    return null;
  }
}

/** The `cursor` the page asked for, off its own request URL. */
export const cursorFromRequestURL = (url) => paramFromRequestURL(url, "cursor");

/** The `board_id` the page asked for. 24-char hex, NOT digits — Pinterest's numeric
 * board-id rule cannot be reused. */
export const boardIdFromRequestURL = (url) => paramFromRequestURL(url, "board_id");

/** Drop a response that belongs to a DIFFERENT board (the hook's replay buffer can hold
 * pages from a board visited earlier in the same tab). Unknown → drop, mirroring X: a
 * scope we cannot verify is never worth the risk of sweeping the wrong feed. */
export function matchesScope(url, scope) {
  if (!isBoardFeedRequest(url)) return false;
  const boardId = boardIdFromRequestURL(url);
  return !!boardId && `board:${boardId}` === scope;
}

/** Raised when a board-feed response is not a usable page. The source re-raises it from
 * `enumerate` so the engine HALTS RESUMABLE — rednote runs an active risk-control layer
 * (`as.rednote.com/api/sec/v1/shield/webprofile`, `xhsFingerprintV3`), and burning through
 * a flagged session is the one failure worth stopping a sweep for. */
export class RednoteChallengeError extends Error {
  constructor(kind) {
    super(`rednote refused the feed: ${kind}`);
    this.name = "RednoteChallengeError";
    this.challenge = true;
    this.kind = kind;
  }
}

/**
 * Recognize a response that is NOT a normal board page → a challenge kind, else null.
 *
 * The hook forwards responses status-blind (it has no HTTP status to give us), so this
 * reads the BODY alone. A healthy page is `{ code: 0, success: true, data: { notes: [] } }`
 * — and note that the genuine LAST page is `has_more: false, notes: [], cursor: ""`, an
 * empty ARRAY, so an exhausted feed is not mistaken for a refusal.
 *
 * Deliberately biased toward halting. A false halt costs the user a resume; a false
 * CONTINUE keeps hammering a session rednote has already flagged. The observed refusal
 * (HTTP 461 during the 2026-09-13 signing experiment) came back `success: true, code: 0,
 * msg: ""` where every genuine response says `msg: "成功"` — a rejection wearing a success
 * shape — which is why the presence of a real `data.notes` array, not the status fields,
 * is the load-bearing check.
 */
export function detectRednoteChallenge(json) {
  if (!json || typeof json !== "object") return "unparseable";
  if (json.code != null && json.code !== 0) return `code_${json.code}`;
  if (json.success === false) return "request_failed";
  const data = json.data;
  if (!data || typeof data !== "object" || !Array.isArray(data.notes)) return "no_feed_payload";
  return null;
}

/**
 * The author of a note. rednote publishes NO username — only a display nickname — so
 * `handle` is always null and `authorName` carries the nickname.
 *
 * The board feed spells it `nick_name`; note detail spells it `nickname`. Same product,
 * same field, two spellings: read both, or one surface silently produces a null author
 * and nothing fails loudly enough to notice (098 D6).
 */
export function rednoteAuthor(user) {
  const source = user || {};
  return {
    handle: null,
    name: source.nick_name || source.nickname || null,
    userId: source.user_id != null ? String(source.user_id) : null,
  };
}

/** First non-empty string in a list, or null. `""` is absent, not a value — rednote uses
 * the empty string for "no URL here" throughout (`cover.url` is `""` on every row). */
function firstNonEmpty(candidates) {
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.length > 0) return candidate;
  }
  return null;
}

/**
 * Choose the fetch URL + fallback for a rednote image object — a board-feed `cover` OR a
 * note-detail `image_list[]` entry, which have an IDENTICAL shape (`url`, `url_pre`,
 * `url_default`, `info_list[]`, `file_id`). One function for both, because two would
 * drift the first time either shape moved.
 *
 * Preference order runs largest-rendering-first: the default rendering (`WB_DFT`) before
 * the preview (`WB_PRV`). Whichever is chosen is then rewritten to its unsigned
 * full-resolution original and the SIGNED url is kept as the fallback — the signed one
 * always loads, the bare original is the one that could 404, exactly the
 * prefer-original/keep-fallback rule Pinterest uses for `/originals/`.
 *
 * `cover.url` is `""` on every row of the live capture, so a mapper that reached for the
 * obvious field would drop every item as "no usable image". Hence `firstNonEmpty`.
 */
export function pickRednoteImage(image) {
  if (!image || typeof image !== "object") return { mediaUrl: null, mediaUrlFallback: null };
  const scenes = new Map(
    (Array.isArray(image.info_list) ? image.info_list : [])
      .filter((entry) => entry && entry.url)
      .map((entry) => [entry.image_scene, entry.url]),
  );
  const signed = firstNonEmpty([
    image.url, image.url_default, scenes.get("WB_DFT"), image.url_pre, scenes.get("WB_PRV"),
  ]);
  if (!signed) return { mediaUrl: null, mediaUrlFallback: null };

  const original = toRednoteOriginal(signed);
  return {
    mediaUrl: original || signed,
    mediaUrlFallback: original && original !== signed ? signed : null,
  };
}

/**
 * Map one board-feed row to a `BulkItem`, or null when it has no id or no usable cover
 * (a doomed item is never enqueued).
 *
 * `xsec_token` is a short-lived per-note credential. It rides as a LOCAL field on the
 * item — NOT inside `provenance` — because the single-capture path already establishes
 * that "a short-lived credential has no business in stored provenance"
 * (`extractors.test.js`, where `cleanURL` strips it from the permalink). K3b needs it
 * during the sweep; nothing needs it afterwards, and a stored one would be dead anyway.
 */
export function mapBoardNote(note, { host = "www.rednote.com", cursor = null } = {}) {
  if (!note || typeof note !== "object") return null;
  const noteId = note.note_id != null ? String(note.note_id) : null;
  if (!noteId) return null;

  const { mediaUrl, mediaUrlFallback } = pickRednoteImage(note.cover);
  if (!mediaUrl) return null;

  const author = rednoteAuthor(note.user);
  const cover = note.cover || {};

  return {
    sourceId: noteId,
    mediaUrl,
    mediaUrlFallback,
    cursor,
    xsecToken: note.xsec_token || null,
    provenance: makeProvenance({
      platform: "rednote",
      originalURL: `https://${host}/explore/${noteId}`,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: author.handle,
      authorName: author.name,
      title: note.display_title || null,
      rawMetadata: {
        noteId,
        // The note's OWN kind, from the feed. 30 of 37 rows in the live capture were
        // "video" — on a video note the cover is a poster still, which is all K3a can
        // capture; K4 resolves the stream.
        kind: note.type === "video" ? "video" : "image",
        userId: author.userId,
        width: cover.width ?? null,
        height: cover.height ?? null,
      },
    }),
  };
}

/**
 * Parse one intercepted board-feed response into `{ items, endOfFeed, cursor, error }`.
 *
 *   · `items`     — one per note, cover-keyed.
 *   · `endOfFeed` — `has_more !== true` OR no next cursor. The genuine terminator is
 *                   `{ has_more: false, notes: [], cursor: "" }` (captured live). The
 *                   second clause is the real guard: Instagram's `next_max_id != null`
 *                   idiom would read `""` as a live cursor and page forever.
 *   · `cursor`    — the NEXT cursor, stamped onto each item. Informational only: an
 *                   intercept source declares `resumable: "scroll"` and cannot seek to it
 *                   (098 R1); dedup-skip is what makes a resume safe.
 *   · `error`     — a `RednoteChallengeError` when the body is not a normal page. Never
 *                   throws: a throw from `parsePage` is swallowed by the source as an
 *                   unparseable capture, which for a challenge would silently keep the
 *                   sweep running against a flagged account (098 R10).
 */
export function parseBoardFeedPage(json, { host = "www.rednote.com" } = {}) {
  const challenge = detectRednoteChallenge(json);
  if (challenge) {
    return { items: [], endOfFeed: false, cursor: null, error: new RednoteChallengeError(challenge) };
  }

  const data = json.data;
  const cursor = firstNonEmpty([data.cursor == null ? null : String(data.cursor)]);
  const items = [];
  for (const note of data.notes) {
    const item = mapBoardNote(note, { host, cursor });
    if (item) items.push(item);
  }
  return { items, endOfFeed: data.has_more !== true || !cursor, cursor, error: null };
}
