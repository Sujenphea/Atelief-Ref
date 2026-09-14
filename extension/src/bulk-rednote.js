// Atelier Capture — rednote board-feed + note-detail parsers (098 T2/T5a, K3a + K3b).
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
// video need a per-note detail fetch (K3b, 098 D4) — which is `parseNoteDetail` at the
// foot of this file, fanning out one item per `image_list[]` entry. The DRIVING that
// produces those responses (opening each note through the SPA) is a separate half again.
//
// A yielded `BulkItem` matches the engine seam:
//   { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor, xsecToken }
// `cursor` and `xsecToken` are LOCAL fields — the relay sends only `sourceId` and
// `provenance` (the twitter driver's `content` field works the same way).

import { makeProvenance } from "./extractors/base.js";
import { toRednoteOriginal } from "./extractors/rednote.js";
import { videoCandidates, videoLadder, withVideoCandidates } from "./rednote-video.js";

/** The board-feed path. Pinned to the PATH, deliberately not to a host: rednote's own
 * telemetry rides adjacent hosts the page also calls (`t2.rnote.com/api/v2/collect`,
 * `apm-fe.rnote.com/api/data`), and a host-shaped matcher would hoover those up. */
export const BOARD_FEED_PATH = "/api/sns/web/v1/board/note";

/** A base for parsing the protocol-relative request URLs the XHR path reports. Never used
 * to make a request — only to read the query off a string `new URL()` would otherwise
 * reject. */
const URL_BASE = "https://www.rednote.com";

/** The note-detail path (098 D4, K3b). A POST where the board feed is a GET, and signed
 * the same way — so it too is intercepted and never issued. Pinned to the path for the
 * same reason as above. */
export const NOTE_DETAIL_PATH = "/api/sns/web/v1/feed";

/** True for a board-feed request URL (absolute or protocol-relative, ± query). */
export function isBoardFeedRequest(url) {
  return typeof url === "string" &&
    new RegExp(`${BOARD_FEED_PATH.replace(/\//g, "\\/")}(?:$|[/?])`).test(url);
}

/** True for a note-detail request URL. Matched on the path ENDING, not merely containing,
 * `…/v1/feed`: rednote ships a family of feed routes below it (`/v1/feed/…`), and a
 * prefix match would hand this parser a homefeed page whose payload it cannot read. */
export function isNoteDetailRequest(url) {
  return typeof url === "string" &&
    new RegExp(`${NOTE_DETAIL_PATH.replace(/\//g, "\\/")}\\/?(?:$|[?#])`).test(url);
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

/**
 * True for the board feed's FIRST page — the request the board issues on navigation,
 * whose `cursor` is EMPTY: `…/board/note?board_id=<24-hex>&num=30&cursor=&image_formats=…`
 * (the form captured live; every later page carries the previous response's cursor).
 *
 * It is the only proof a run can have that it holds the TOP of the feed, and the feed
 * gives no other: it pages FORWARD only — a cursor buys the NEXT slice and no request
 * walks back — while the sweep's single lever is a scroll to the bottom. So a board that
 * was ALREADY SCROLLED when the sweep started fetched its opening slice in an earlier page
 * session: that response is long out of the hook's replay buffer and can never be
 * re-requested for this run. Measured on a live 116-note board (2026-09-14): the sweep saw
 * pages B·C·D, captured 78 notes, reported `complete`, and page A's 38 were simply gone.
 *
 * The `board_id` clause is what keeps this honest rather than merely convenient:
 * `cursorFromRequestURL` cannot tell an EMPTY cursor from a url it could not parse at all
 * (both read null), so an unreadable url would otherwise present itself as the first page
 * — the exact mistake this predicate exists to catch. A query that parsed has the board id;
 * one that did not, has nothing.
 */
export function isFirstBoardFeedRequest(url) {
  return isBoardFeedRequest(url)
    && boardIdFromRequestURL(url) !== null
    && cursorFromRequestURL(url) === null;
}

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
 * Recognize a response that is NOT a normal rednote payload → a challenge kind, else null.
 *
 * The hook forwards responses status-blind (it has no HTTP status to give us), so this
 * reads the BODY alone. A healthy body is `{ code: 0, success: true, data: { <payload>: [] } }`
 * — and note that the board feed's genuine LAST page is `has_more: false, notes: [],
 * cursor: ""`, an empty ARRAY, so an exhausted feed is not mistaken for a refusal.
 *
 * Deliberately biased toward halting. A false halt costs the user a resume; a false
 * CONTINUE keeps hammering a session rednote has already flagged. The observed refusal
 * (HTTP 461 during the 2026-09-13 signing experiment) came back `success: true, code: 0,
 * msg: ""` where every genuine response says `msg: "成功"` — a rejection wearing a success
 * shape — which is why the presence of a real payload ARRAY, not the status fields, is the
 * load-bearing check.
 *
 * `payloadKey` is the ONE thing that differs between the two rednote endpoints the sweep
 * reads: the board feed answers with `data.notes`, note detail with `data.items`. It is a
 * parameter rather than a second copy of this function because the envelope rules above
 * were all learned the hard way and a copy would inherit only the ones that were true on
 * the day it was made (098 D6).
 */
function detectChallengeKind(json, payloadKey) {
  if (!json || typeof json !== "object") return "unparseable";
  if (json.code != null && json.code !== 0) return `code_${json.code}`;
  if (json.success === false) return "request_failed";
  const data = json.data;
  if (!data || typeof data !== "object" || !Array.isArray(data[payloadKey])) return "no_feed_payload";
  return null;
}

/** The board feed's refusal recognizer — `data.notes` is the payload that must be there. */
export function detectRednoteChallenge(json) {
  return detectChallengeKind(json, "notes");
}

/** The note-detail refusal recognizer — same envelope, `data.items` instead. Note what it
 * does NOT cover: an `items: []` is a note that did not come back (deleted, private,
 * gone), not a refusal, and is handled by `parseNoteDetail` as a per-note degradation. A
 * deleted note must not halt a 400-note sweep. */
export function detectRednoteDetailChallenge(json) {
  return detectChallengeKind(json, "items");
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

// ---------------------------------------------------------------------------
// K3b — note detail (098 D4): one BulkItem per image_list[] entry
// ---------------------------------------------------------------------------
//
// The detail body arrives the same way the board feed does — the SPA opens a note, issues
// its own correctly signed `POST /api/sns/web/v1/feed`, and the hook forwards the
// response. Nothing here requests anything; this half is pure (098 T5a), and the driving
// that produces the responses is T5b's.
//
// Envelope, verified live 2026-09-13 (`resources/rednote-note-02.json`):
//   { code, success, msg, data: { cursor_score, items: [ { id, model_type, note_card } ],
//                                 current_time } }
// with `note_card` carrying `type · note_id · title · desc · time · last_update_time ·
// ip_location · user · image_list[] · tag_list · at_user_list · share_info ·
// interact_info · note_translation`. NO note-level `xsec_token` and, on this `normal`
// note, NO `video` key.
//
// The fan-out is per IMAGE (`<note_id>:<index>`), the Instagram carousel shape, because
// the detail response is the first place a note's images exist at all — the board row
// carries one cover and nothing else (098 D3).

/** A note that produced no items but was NOT a refusal — the caller keeps its cover item
 * rather than treating the note as empty. Every one of these is a per-note degradation
 * the sweep should count and log (098 R7's `onExpandFailure`), never a silent drop. */
const detailRefusal = (unsupported, noteId = null, noteKind = null) =>
  ({ items: [], noteId, noteKind, unsupported, error: null });

/** The suffix that keys a video note's STREAM item: `<note_id>:v` (098 T6c).
 *
 * A LETTER, beside the image children's `<note_id>:0…:n`, and the whole decision is in that
 * one character. Three properties had to hold at once:
 *
 *   · It must contain a `:`, because `knownNoteIndex` counts a note as expanded only when a
 *     known id has one (`id.indexOf(":") > 0`). Upgrading the COVER item in place — keying
 *     the stream `<note_id>` — would leave no expanded child at all, and every video note
 *     on an 81 %-video board would be re-opened on every future sweep, burning the 400-note
 *     budget forever. That is the exact failure the T5 addendum exists to prevent.
 *   · It must not collide with an image index, now or later. `:v` cannot be a number, so a
 *     note that one day carries both a stream and a carousel keys them apart for free.
 *   · It must leave `<note_id>` — the cover the K3a pass already ingested — untouched. It
 *     does: the stream is a SECOND item beside the poster, not a replacement for it, which
 *     is also what makes "exhaust the ladder, keep the cover" true rather than aspirational.
 */
export const VIDEO_SOURCE_SUFFIX = "v";

/** The stream item's key for a note. One spelling, one place. */
export const videoSourceId = (noteId) => `${noteId}:${VIDEO_SOURCE_SUFFIX}`;

/**
 * Map ONE `image_list[]` entry to a `BulkItem`, or null when it yields no usable URL.
 *
 * `ctx` carries the note-level fields every image of a note shares (`noteId`, `author`,
 * `title`, `desc`, `host`, `xsecToken`, `imageCount`) plus this entry's `index`.
 *
 * The index is the entry's POSITION IN THE ARRAY, never a count of items produced so far.
 * If image 4 of 9 ever loses its URL, images 5–9 must keep the keys they had on the last
 * sweep, or a re-sweep re-ingests every one of them under shifted ids.
 */
export function mapNoteImage(image, ctx) {
  if (!image || typeof image !== "object") return null;
  const { mediaUrl, mediaUrlFallback } = pickRednoteImage(image);
  if (!mediaUrl) return null;

  return {
    sourceId: `${ctx.noteId}:${ctx.index}`,
    mediaUrl,
    mediaUrlFallback,
    cursor: ctx.cursor ?? null,
    // Local field, never provenance — the same rule the cover pass follows, and the reason
    // is the same: a short-lived credential has no business being stored. The detail body
    // carries no note-level token of its own (only `user.xsec_token`, which authorizes the
    // AUTHOR's profile, not this note), so it is threaded in from the cover item that the
    // note-open started from.
    xsecToken: ctx.xsecToken ?? null,
    provenance: makeProvenance({
      platform: "rednote",
      originalURL: `https://${ctx.host}/explore/${ctx.noteId}`,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: ctx.author.handle,
      authorName: ctx.author.name,
      title: ctx.title,
      rawMetadata: {
        noteId: ctx.noteId,
        kind: "image",
        // The note's literal `type`. Carried rather than collapsed so a kind rednote
        // invents later shows up in stored provenance instead of vanishing into "image".
        noteType: ctx.noteType,
        userId: ctx.author.userId,
        width: image.width ?? null,
        height: image.height ?? null,
        imageIndex: ctx.index,
        imageCount: ctx.imageCount,
        // 098 Open question 4 defers Live Photos. Deferred means the MOTION half: the
        // entry's urls still serve a perfectly good still, so the still is captured and
        // flagged, rather than the whole image being dropped for the sake of the part we
        // are not taking. The motion lives in the entry's `stream`, which nothing reads
        // yet; this flag is how a later pass finds the notes worth revisiting.
        livePhoto: image.live_photo === true,
        // `desc` and `title` exist ONLY on the detail response — the board row has just
        // `display_title` — so this is the one chance to record them.
        desc: ctx.desc,
      },
    }),
  };
}

/**
 * Map a VIDEO note's stream ladder to ONE `BulkItem` carrying the note's mp4 — or a typed
 * refusal (098 T6c, K4).
 *
 * Returns `{ item, refusal }`: exactly one of them is set. `refusal` is a `STREAM_REFUSAL`
 * reason from `rednote-video.js`, and every one of them means the same thing to the caller —
 * keep the poster the cover pass already captured and record a typed skip. 020 names that
 * outcome for an `ef*`-only note: "the honest outcome is cover-still-only for that note;
 * record it as a typed skip, do not fail the sweep."
 *
 * Three things the item deliberately does NOT have:
 *
 *   · **No `mediaUrl`.** A video note's `image_list` is ONE entry — the poster — and the
 *     cover pass has already ingested that exact picture as `<note_id>`. Giving this item
 *     the poster as a still fallback would make a failed stream re-download it under a
 *     second key: one picture, two keys, a dedup-skip that cannot see the duplicate. That
 *     is the whole reason 098 T5a refused video notes, and lifting the refusal must not
 *     lift it by re-introducing the duplicate. With no still, an exhausted ladder is a
 *     typed skip (`sw.js`), and the poster survives at `<note_id>` where it already was.
 *   · **No stream url in `rawMetadata`.** 020 B3: the same note offered a DIFFERENT ladder
 *     on two visits minutes apart, so a persisted `master_url` comes back 404 or points at
 *     a rung that is no longer right. `provenance` IS persisted — it is what ships to the
 *     app and what a checkpointed item would carry — so the ladder rides OUTSIDE it, on the
 *     non-enumerable property `withVideoCandidates` attaches. What is kept here is the
 *     rung's DESCRIPTION (bucket, stream type, dimensions): facts about the chosen rung
 *     that cannot rot into a dead fetch, and the only way the "stream_type is the real
 *     discriminator" hypothesis could ever gather evidence.
 *   · **No re-sorting.** `videoCandidates` has already ordered the ladder (020 rule 1:
 *     by codec bucket, never by size). This hands that order on untouched.
 */
export function mapNoteVideo(note, ctx) {
  const ladder = videoLadder(note);
  const { rungs, refusal } = videoCandidates(ladder);
  if (refusal) return { item: null, refusal };

  const chosen = rungs[0];
  const item = {
    sourceId: videoSourceId(ctx.noteId),
    mediaUrl: null,
    mediaUrlFallback: null,
    cursor: ctx.cursor ?? null,
    xsecToken: ctx.xsecToken ?? null,
    provenance: makeProvenance({
      platform: "rednote",
      originalURL: `https://${ctx.host}/explore/${ctx.noteId}`,
      mediaUrl: null,
      mediaUrlFallback: null,
      authorHandle: ctx.author.handle,
      authorName: ctx.author.name,
      title: ctx.title,
      rawMetadata: {
        noteId: ctx.noteId,
        kind: "video",
        noteType: ctx.noteType,
        userId: ctx.author.userId,
        width: chosen.width,
        height: chosen.height,
        // The rung we took, described rather than linked. `streamBucket` is the
        // `EF4`…`EF7` label selection ran on; `streamType` is the numeric type 020's
        // undecodable pick (`_330`) and this capture's working one (258) disagree on.
        streamBucket: chosen.bucket,
        streamType: chosen.streamType,
        // How many rungs the ladder offered, so a note that quietly lost its alternatives
        // is visible in stored provenance without any url being stored.
        streamRungs: rungs.length,
        desc: ctx.desc,
      },
    }),
  };
  // The ladder is attached NON-ENUMERABLY, and that is the whole of where it lives: frozen,
  // invisible to every copy a checkpoint or a message could make, readable only by name
  // (`readVideoCandidates`). See `withVideoCandidates`.
  return { item: withVideoCandidates(item, ladder), refusal: null };
}

/**
 * Parse one intercepted note-detail response into
 * `{ items, noteId, noteKind, unsupported, error }`.
 *
 *   · `items`       — one per `image_list[]` entry, keyed `<note_id>:<index>`; or, for a
 *                     video note with `resolveVideo` on, the ONE stream item keyed
 *                     `<note_id>:v` (see `mapNoteVideo`).
 *   · `noteKind`    — `"video"` | `"image"` | null. The caller branches on it for one
 *                     reason: a video note's cover item must RIDE ALONGSIDE its stream
 *                     rather than be replaced by it (the poster is the fallback 020 asks
 *                     for when the ladder fails at ingest time, long after this parse).
 *   · `noteId`      — the note this body is about, for the caller to check against the
 *                     note it opened (the hook's replay buffer can hand over a detail
 *                     response from an EARLIER note in the same tab — the same hazard
 *                     `matchesScope` guards on the board pass).
 *   · `unsupported` — non-null when the note yielded nothing for a reason that is NOT a
 *                     refusal. **`items: []` with `unsupported` set means "keep this
 *                     note's cover item"**, not "this note is empty": the cover pass has
 *                     already captured something usable for it and expansion must degrade
 *                     to that, never replace it with nothing (098 D4 / R7).
 *   · `error`       — a `RednoteChallengeError` when the BODY is not a detail payload at
 *                     all. Unlike `unsupported`, this one must be re-raised so the sweep
 *                     halts resumable; degrading past a refusal keeps opening notes
 *                     against a session rednote has already flagged.
 *
 * Never throws, for the reason `parseBoardFeedPage` never throws: a throw is swallowed by
 * the intercept seam as an unparseable capture, and a swallowed challenge is a sweep that
 * keeps running against a flagged account (098 R10).
 *
 * The `unsupported` reasons, all of them observed-shape-driven:
 *   `no_note`         `data.items` is empty — deleted, private, or withheld.
 *   `no_note_card`    the item arrived without its card.
 *   `no_note_id`      the card cannot be keyed, so no `<note_id>:<index>` exists.
 *   `video`           a video note with `resolveVideo` off — see below.
 *   `no_ladder` · `empty_ladder` · `no_usable_rung` · `undecodable_codec`
 *                     a video note with `resolveVideo` ON whose stream ladder yielded
 *                     nothing. `STREAM_REFUSAL`'s own vocabulary, unwrapped rather than
 *                     collapsed, so the sweep can say which.
 *   `no_images`       `image_list` missing or empty.
 *   `no_usable_images` every entry was there but none yielded a URL.
 *
 * **A video note's `image_list` is NEVER fanned out** (098 T6c). The live capture settled
 * what T5a could only suspect: a `type: "video"` note carries exactly ONE `image_list`
 * entry, and it is the poster — the same picture the cover pass already ingested as
 * `<note_id>`. Fanning it out would enqueue `<note_id>:0` for one picture under a second
 * key: two downloads and a dedup-skip that cannot see the duplicate. So T6c lifts the
 * refusal WITHOUT lifting that: a video note contributes its STREAM (`<note_id>:v`), or
 * nothing at all.
 *
 * `resolveVideo` is the existing popup toggle, meaning what it has always meant — relay the
 * resolved MP4 rather than the still. OFF (the default), a video note is refused exactly as
 * it was before T6c: `unsupported: "video"`, cover kept, no stream. ON, the ladder is read
 * and the stream item is built; when the ladder yields nothing the `unsupported` reason is
 * the `STREAM_REFUSAL` string that says WHICH nothing (`undecodable_codec` is 020's
 * `ef*`-only, cover-still-only case by name).
 */
export function parseNoteDetail(
  json,
  { host = "www.rednote.com", xsecToken = null, resolveVideo = false } = {}
) {
  const challenge = detectRednoteDetailChallenge(json);
  if (challenge) {
    return {
      items: [], noteId: null, noteKind: null, unsupported: null,
      error: new RednoteChallengeError(challenge),
    };
  }

  const entry = json.data.items[0];
  if (!entry || typeof entry !== "object") return detailRefusal("no_note");
  const note = entry.note_card;
  if (!note || typeof note !== "object") return detailRefusal("no_note_card");

  const noteId = note.note_id != null && note.note_id !== "" ? String(note.note_id) : null;
  if (!noteId) return detailRefusal("no_note_id");

  const noteType = note.type != null ? String(note.type) : null;
  const ctx = {
    noteId, host, xsecToken, noteType,
    author: rednoteAuthor(note.user),
    title: note.title || null,
    desc: note.desc || null,
  };

  // A `video` key anywhere on the card outranks `type`: the key is the payload, the type
  // is a label, and a label can be renamed without the payload moving.
  if (note.video != null || noteType === "video") {
    // The toggle the user actually set. Off, this is T5a unchanged — and it is also the
    // cheaper answer, because the expander then never spends a paced note-open on a note
    // whose only contribution it has been told not to take.
    if (!resolveVideo) return detailRefusal("video", noteId, "video");
    const { item, refusal } = mapNoteVideo(note, ctx);
    if (!item) return detailRefusal(refusal, noteId, "video");
    return { items: [item], noteId, noteKind: "video", unsupported: null, error: null };
  }

  const images = Array.isArray(note.image_list) ? note.image_list : [];
  if (images.length === 0) return detailRefusal("no_images", noteId, "image");

  const items = [];
  images.forEach((image, index) => {
    const item = mapNoteImage(image, { ...ctx, index, imageCount: images.length });
    if (item) items.push(item);
  });

  return {
    items,
    noteId,
    noteKind: "image",
    unsupported: items.length === 0 ? "no_usable_images" : null,
    error: null,
  };
}
