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
//
// THE TRANSFORM HAS TWO SPELLINGS. `!nc_n_webp_mw_1` rides on the path; a board's
// covers instead ride `?imageView2/2/w/540/format/jpg/q/75` in the QUERY, and that
// one is worth 35-57x (measured 2026-09-14). Both come off; `?sign=` does not.

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
 * ONE `&`-separated query component that is a rendering directive rather than a
 * parameter — rednote's second transform spelling, beside the `!…` path suffix:
 *
 *   ?imageView2/2/w/540/format/jpg/q/75      (a board cover)
 *   ?imageView2/2/w/80/format/jpg            (an avatar)
 *
 * What makes "strip the transform" different from "strip the query string" — and the
 * difference is load-bearing, because rednote has UNSIGNED-IN-PATH families whose
 * authorization rides in the query (`/subtitle/1/110/1/<id>_12.srt?sign=…&t=…`, 487),
 * so a blanket query drop breaks a url that works today:
 *
 *  · Components are judged ONE AT A TIME, and only a named directive is dropped. The
 *    name list is enumerated rather than wildcarded: `imageView2` is the only spelling
 *    live traffic shows, `imageView` and `imageMogr2` are its two siblings in the same
 *    documented resize family and mean the same thing. Anything else is left alone,
 *    which costs a thumbnail — the cheap direction, exactly as in `hasSigningPrefix`.
 *    THIS is the half that keeps `sign=…` and `t=…`: neither begins with a directive
 *    name. Both directions are pinned in `extractors.test.js`.
 *  · `[^=]*$` then says a directive is a bare path and never a key/value pair. It is
 *    belt-and-braces: no live shape spells a directive with an `=` in it, so dropping
 *    this clause fails no test, and it is recorded as a deliberate surviving mutant
 *    rather than defended with an invented case. It is kept because the cost is nil
 *    and it states the shape the name list is standing in for.
 */
const TRANSFORM_QUERY = /^image(View2?|Mogr2)\/[^=]*$/i;

/** True when one `&`-separated query component is a transform directive. Exported for
 * `sanitize-capture.js`, which must KEEP this shape verbatim in a fixture (it is a
 * rendering instruction, never identity) while still dropping every other query
 * component, and which has flattened four such shapes already. A second copy of the
 * spelling there is how a fixture comes to prove the opposite of what the canary asks. */
export function isTransformDirective(part) {
  return TRANSFORM_QUERY.test(String(part || ""));
}

/** `search` (with or without its `?`) minus every transform directive, re-spelled as a
 * query string — `""` when nothing survives. Whatever is not a directive is kept, in
 * order, untouched. */
function withoutTransformQuery(search) {
  const kept = String(search).replace(/^\?/, "").split("&")
    .filter((part) => part && !isTransformDirective(part));
  return kept.length ? `?${kept.join("&")}` : "";
}

/**
 * True when `src` STILL carries a rendering directive in either spelling — the `!…`
 * path suffix or an `imageView2`-family query.
 *
 * Exported because `drift.js` asserts that no swept `mediaUrl` carries one, and the two
 * must agree by construction: a second copy of these shapes over there is how the canary
 * comes to pass on a url this module would still rewrite. That is not hypothetical — the
 * canary already tested `.includes("!")` and said nothing about the query form while
 * every cover in a live `board/info` response carried it.
 */
export function hasTransform(src) {
  const text = String(src || "");
  if (text.includes("!")) return true;
  const at = text.indexOf("?");
  if (at < 0) return false;
  return text.slice(at + 1).split("#")[0].split("&").some(isTransformDirective);
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
 * THE TRANSFORM HAS TWO SPELLINGS and stripping only one of them is a 35-57x
 * quality loss. `!nd_dft_wlteh_webp_3` rides on the path; `?imageView2/2/w/540/
 * format/jpg/q/75` rides in the QUERY, which is what every cover in a live
 * `board/info` response carries. Measured 2026-09-14 — both bare forms 200
 * `image/jpeg`: a cover 35,900 B with the query, 1,266,867 B without; a
 * `spectrum/` cover 18,241 -> 1,038,214; an avatar 1,013 -> 86,223. The query
 * form is stripped WHEREVER it rides, signed path or not, because it is a
 * request for a rendering and nothing else in the url depends on it.
 *
 * Removing the transform is NOT removing the query — see `TRANSFORM_QUERY`.
 * rednote's unsigned-in-path subtitles are authorized by `?sign=…`, so the rule
 * names the directives it drops and keeps everything else.
 *
 * A query-transformed url is de-transformed IN PLACE, on the host it came from,
 * and NOT rehosted onto `ORIGIN_HOST`. Same reason the signing-shape guard exists:
 * rehosting is only sound where the path is known to be a bare object key, which
 * only the signing prefix proves. These urls have 1-2 segments and no such proof,
 * and the measurement settles it — `sns-avatar-qc…/avatar/<key>` is 200 / 86,223 B
 * where the same key on `ORIGIN_HOST` is 404. De-transforming in place already
 * recovers the full-resolution original, so rehosting would buy nothing and risk
 * everything.
 *
 * Idempotent: a rewritten path lands on `ORIGIN_HOST` and a URL already there is
 * not re-split (its path is a bare key, so dropping two segments would mangle a
 * multi-segment one), while a de-transformed url no longer carries a directive to
 * strip. A path too short to hold a signing prefix AND a key (`/avatar/<id>`)
 * cannot match the shape either.
 */
export function toRednoteOriginal(src) {
  if (!src || !CDN.test(src)) return src || null;
  try {
    const url = new URL(src);
    const host = url.hostname.toLowerCase();
    if (!hostIs(host, "rednotecdn.com")) return src;
    // The query transform comes off first and independently of the path rules, so
    // every branch below hands back a de-transformed url. When there was nothing to
    // strip the INPUT is handed back verbatim rather than a re-serialized copy, so
    // passthrough stays byte-for-byte passthrough.
    const kept = withoutTransformQuery(url.search);
    let bare = src;
    if (kept !== url.search) {
      url.search = kept;
      bare = url.toString();
    }
    // Already canonical — the only URLs on this host are bare keys.
    if (host === ORIGIN_HOST) return bare;
    const segments = splitPathname(url.pathname);
    // No signing prefix to strip: the path is already the object key, whether it
    // is a `/stream/…` mp4 or a two-segment `/avatar/<id>`. Leave the path alone.
    if (!hasSigningPrefix(segments)) return bare;
    const key = segments.slice(2).join("/").split("!")[0];
    if (!key) return bare;
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
