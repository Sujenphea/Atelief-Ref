// Atelier Capture — rednote (Xiaohongshu) extractor.
//
// One product on TWO domains — `rednote.com` (international) and
// `xiaohongshu.com` (mainland) — so both are matched here and both appear in
// `manifest.json` host_permissions. Client-rendered like the other SPA sites:
// the note URL comes from the right-clicked link (`/explore/{noteId}`) when the
// capture starts from a feed or board, else the live URL; og:* is stale/generic.
//
// MEDIA (verified 2026-07-31 against a live note, re-verified 2026-09-13 against
// two live captures): the page renders a SIGNED, RESIZED webp —
//   https://sns-web-i10.rednotecdn.com/<ts>/<sig>/<key>!nc_n_webp_mw_1
// — typically a 270 px thumbnail. Dropping the timestamp/signature segments and
// the `!…` transform suffix, and asking a plain image node for the bare key —
//   http://sns-i27.rednotecdn.com/<key>
// — is PUBLIC, UNSIGNED, and returns the full-resolution original (2022×2696 and
// up). So the bare form is preferred and the signed webp is kept as
// `mediaUrlFallback`, the same prefer-original/keep-fallback rule Pinterest uses
// for `/originals/`.
//
// `<key>` IS NOT ALWAYS ONE SEGMENT — a note's `image_list` images are keyed
// `oss-sg/spectrum/<id>`. See `toRednoteOriginal` below; getting this wrong is a
// silent 404 masked by the fallback, not a visible failure.

import {
  hostname, hostIs, firstMeta, pathSegments, splitPathname, liveURL, firstPostURL,
  largestMedia, ogImage,
} from "./base.js";

/** The plain image node that serves unsigned, untransformed originals. Exported because
 * the drift canary asserts every swept `mediaUrl` lands on it (`checkRednoteBoard`), and
 * the two must agree by construction — a hardcoded copy there would go on passing after
 * this one moved, which is the exact drift that check exists to catch. */
export const ORIGIN_HOST = "sns-i27.rednotecdn.com";

/** Any rednote CDN URL (images `sns-i*` / `sns-web-i*`, video `sns-v*`). */
const CDN = /(^|\/\/|\.)rednotecdn\.com\//;

/** True when a path's first two segments are signing material AND something is left
 * over to be the key. Live shapes: `202609131332` (yyyyMMddHHmm) then 32 hex, matched
 * case-insensitively because a hex digest is case-insensitive by definition. The width
 * bounds sit loosely around what the captures show; see `toRednoteOriginal` for why
 * strict wins. */
function hasSigningPrefix(segments) {
  return segments.length >= 3
    && /^\d{10,14}$/.test(segments[0]) && /^[0-9a-f]{32}$/i.test(segments[1]);
}

/**
 * Rewrite a SIGNED rednote CDN URL to its unsigned full-resolution original, or
 * return `src` unchanged — already unsigned, not rednote, or unparseable.
 *
 * A signed URL is `/<timestamp>/<signature>/<key>` — the first TWO segments are
 * signing material and everything after them is the object key. The key is NOT
 * always one segment, and NOT only on note-detail images: across the 37 rows of
 * the live board feed the covers are keyed `<id>` on 15, `spectrum/<id>` on 16
 * and `oss-sg/notes_pre_post/<id>` on 6. Reading only the LAST segment silently
 * dropped those prefixes and built a 404 on 22 of 37 ordinary board rows, which
 * `mediaUrlFallback` then masked as a 5x quality loss (240 KB original -> 47 KB
 * signed webp) with no error — see 098 D2 / changelog 467.
 *
 * WHICH URLs get that rewrite is decided by the SHAPE of the first two segments,
 * never by segment COUNT. "Three or more segments" was the earlier test and it is
 * the same mistake one level up, because rednote serves video and subtitles
 * ALREADY UNSIGNED, with real path where a signing prefix would sit:
 * `/stream/1/110/258/<id>_258.mp4` and `/subtitle/1/110/1/<id>_12.srt` (signed by
 * a `?sign=` query, if at all). A count test eats `stream/1` as signing material
 * and rehosts a working 206 into a 404 — verified live 2026-09-14, input 206
 * `video/mp4`, rewrite 404. The shape test is deliberately strict because the two
 * failure directions are not symmetric: declining to strip yields the signed URL,
 * which still loads at lower resolution, while stripping what is not a signature
 * yields a URL that does not exist.
 *
 * Host is NOT part of the test. `sns-web-i10` happens to serve every signed URL
 * in the captures and `sns-v11`/`sns-v27`/`sns-subtitle-s10` the unsigned ones,
 * but an enumerated shard list is one new shard away from being wrong, and the
 * signing shape is the actual invariant.
 *
 * Verified over the three live captures (2026-09-14): 138 distinct CDN URLs, of
 * which the shape test strips 94 and passes 44 through, changing the answer on
 * exactly the 5 unsigned stream/subtitle URLs. Where the API publishes its own
 * `file_id` (40 URLs) the stripped key equals it 40/40. `file_id` is still not
 * read here — it would corroborate, not correct, and it is `""` on all 37 board
 * covers, precisely where the multi-segment keys are least expected.
 *
 * Idempotent: output always lands on `ORIGIN_HOST`, and a URL already there is
 * returned untouched rather than re-parsed (its path is a bare key, so dropping
 * two segments would mangle a multi-segment one). A path too short to hold a
 * signing prefix AND a key (`/avatar/<id>`) cannot match the shape either.
 */
export function toRednoteOriginal(src) {
  if (!src || !CDN.test(src)) return src || null;
  try {
    const url = new URL(src);
    const host = url.hostname.toLowerCase();
    if (!hostIs(host, "rednotecdn.com")) return src;
    // Already canonical — the only URLs on this host are bare keys.
    if (host === ORIGIN_HOST) return src;
    const segments = splitPathname(url.pathname);
    // No signing prefix to strip: the path is already the object key, whether it
    // is a `/stream/…` mp4 or a two-segment `/avatar/<id>`. Leave it alone.
    if (!hasSigningPrefix(segments)) return src;
    const key = segments.slice(2).join("/").split("!")[0];
    if (!key) return src;
    return `http://${ORIGIN_HOST}/${key}`;
  } catch {
    return src;
  }
}

/** A note id, as every rednote route spells it: 24 hex in every capture, bounded the way
 * `bulk-context.js` bounds a board id. Used ONLY where a route's namespace is shared (see
 * `rednoteNoteId`), never as a general id test. */
const NOTE_ID_SHAPE = /^[0-9a-f]{16,32}$/i;

/**
 * The note id in a rednote note URL — a full URL, or a bare `location.pathname` — or null.
 *
 * THREE routes carry a note, and this is the one place that knows all three, because a
 * second copy is how the extractor and the sweep's page driver come to disagree about what
 * a note URL is:
 *
 *   · `/explore/<note_id>`              — a note opened from a feed.
 *   · `/discovery/item/<note_id>`       — a note opened from a profile or a search result
 *                                         (observed live 2026-09-14, carrying
 *                                         `xsec_source=pc_user`).
 *   · `/board/<board_id>/<note_id>`     — what a BOARD CARD renders, and what the board
 *                                         routes to. Probed live 2026-09-14 on
 *                                         `/board/69322476000000001202811f`.
 *
 * The third is the one that needs a shape test on its id, and the reason is asymmetry of
 * namespace: nothing but a note lives under `/explore/`, while `/board/<id>/…` shares its
 * namespace with the board page itself, so a future `/board/<id>/edit` must not read as a
 * note. Two segments (`/board/<board_id>`) is the board and is not a note — the extractor
 * has always relied on that.
 *
 * The query string is deliberately NOT part of the test. `xsec_token` is a short-lived
 * credential that `cleanURL` strips before anything is stored, and `xsec_source` varies by
 * where the reader came from (`` empty on a board card, `pc_user` on a hand-opened note),
 * so neither can be a precondition for recognising the route.
 */
export function rednoteNoteId(url) {
  const segments = /^[a-z][a-z0-9+.-]*:\/\//i.test(url || "")
    ? pathSegments(url) : splitPathname(url);
  if (segments[0] === "explore") return segments[1] || null;
  if (segments[0] === "discovery" && segments[1] === "item") return segments[2] || null;
  if (segments[0] === "board" && NOTE_ID_SHAPE.test(segments[2] || "")) return segments[2];
  return null;
}

export const rednote = {
  platform: "rednote",

  match(url) {
    const host = hostname(url);
    // `hostIs` matches the apex or a subdomain but NOT a suffix spoof
    // (`rednote.com.evil.com` ends with `.evil.com`).
    return hostIs(host, "rednote.com") || hostIs(host, "xiaohongshu.com");
  },

  extract(harvest, context = {}) {
    // What a note URL is lives in `rednoteNoteId` — all three routes, one definition,
    // shared with the sweep's page driver.
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], (u) => !!rednoteNoteId(u)) ||
      liveURL(harvest);
    const noteId = rednoteNoteId(url);

    // Exact clicked image, else the biggest rednote CDN image on the note page.
    const clicked = CDN.test(context.srcUrl || "") ? context.srcUrl : null;
    const rendered = clicked || largestMedia(harvest, CDN)?.src || null;
    const mediaUrl = toRednoteOriginal(rendered) || ogImage(harvest);
    // The signed webp always loads; the bare original is the one that could 404,
    // so keep the rendered URL as the fetch fallback.
    const mediaUrlFallback = rendered && mediaUrl !== rendered ? rendered : null;

    return {
      platform: "rednote",
      originalURL: url,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: noteId ? { noteId } : {},
    };
  },
};
