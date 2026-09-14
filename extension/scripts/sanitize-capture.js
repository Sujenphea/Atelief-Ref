// Sanitize a live platform capture into a committable fixture.
//
// The sweep is KEY-INDEPENDENT: what a value IS decides whether it is replaced, not what
// it is called. That rule exists because the 2026-08-13 X capture leaked profile-image
// urls through `avatar.image_url` when the sweep was keyed on `profile_image_url_https`.
//
// Structure is preserved EXACTLY — same keys, same nesting, same array lengths, same
// types. Only leaf values change, and only when their shape says they carry identity.
//
//   node sanitize-capture.js <raw.json> <out.json>

import { readFileSync, writeFileSync } from "node:fs";
// The ONE shape this script keeps out of a query string, imported from the module that
// strips it rather than respelled here — see the query note in `syntheticUrl`.
import { isTransformDirective } from "../src/extractors/rednote.js";
// The audit is not a separate step you may forget to run — see THE GATE at the foot of
// this file. Imported, never respelled, for the same reason as the line above.
import { auditCapture } from "./audit-capture.js";
// The two key rules the audit has to agree with, single-sourced for that reason.
import { IDENTITY_KEY, SCHEMA_KEY } from "./capture-keys.js";

const [, , inPath, outPath] = process.argv;
const rawText = readFileSync(inPath, "utf8");
const raw = JSON.parse(rawText);

// ---------------------------------------------------------------------------
// Shape predicates — the whole policy, in one place
// ---------------------------------------------------------------------------

const isUrl = (s) => /^https?:\/\//.test(s);
// A trailing letter suffix is still an id: IG ships `814154277899006v`. The first pass
// required all-digits and leaked exactly those.
//
// SIGNED, because Pinterest's board-feed `id` can be negative (`-8491549942718880421`),
// and the floor is SIX rather than eight because the shortest standalone id in any capture
// here is seven digits and there are two of them — IG's `pk`/`pk_id`/`strong_id__`
// `8046568` and X's `rest_id`/`user_id_str` `9655742`. The same floor the composite rule
// draws, and the same one `isRouteToken` draws. Nothing legitimate is caught by widening
// it: every five- and six-digit string in every capture in `resources/` sits under a
// `*_count` key, and `COUNT_KEY` zeroes those in `walk` before any value rule sees them.
const isLongDigits = (s) => /^-?\d{6,}[A-Za-z]?$/.test(s);
// A COMPOSITE id: two or more all-digit runs joined by underscores. The underscore is
// what made this invisible — it breaks `isLongDigits`, and `isOpaqueId`/`isToken` both
// demand a LETTER (`/[A-Za-z]/`) that a digits-and-underscore value does not have, so it
// fell through every rule and rode out of the sweep verbatim. Two platforms ship one:
//
//   instagram  3936199039845197488_291775034   <media_pk>_<user_pk>
//   x          13_2023807562760826880          <media_type>_<media_id>
//
// It was MASKED, never handled. The 2026-08-14 IG raw's composites all carry an 11-digit
// user pk, so at 31 characters `isFreeText`'s `length > 30` swallowed every one of them;
// today's capture also carries 7-to-10-digit pks, and at 29-30 characters 87 distinct
// real ids walked straight through (audit `LEAKED: 176`). A rule that only holds while a
// platform keeps issuing long enough user ids is not a rule.
//
// The gate is "at least one run long enough to BE an id", not "every run is": X's leading
// run is the media-type discriminator (`3` photo, `13` video, `7` gif — the only three
// values across every X raw here) and is kept verbatim below. Six is the floor because
// the shortest identity run observed anywhere in `resources/` is IG's 7-digit
// `profile_pic_id` owner (`3236034018967612385_8046568`) — an `\d{8,}` floor, the obvious
// one to copy from `isLongDigits`, would have leaked exactly that, the same way the
// all-digits first pass leaked `814154277899006v`. It is also the boundary `isRouteToken`
// already draws: under six digits is too short to be an id or an epoch.
//
// SEPARATOR IS DELIBERATELY ONLY THE UNDERSCORE. The other two separators that join bare
// digit runs in these captures are content or format that this must not touch: `.` joins
// version numbers (`153.0.0`, `10.15.7`) and `,` joins rednote's display-formatted counts
// (`5,123`), which the `COUNT_KEY` rule zeroes by key. Widening to `[^A-Za-z0-9]` would
// rewrite both — the same over-reach that once let `SCHEMA_CONSTANT` shield `testing2`.
const isCompositeDigits = (s) => /^\d+(_\d+)+[A-Za-z]?$/.test(s) && /\d{6,}/.test(s);

// Values that are part of the response FORMAT, not its content. Kept verbatim so the
// fixture still looks like the thing it is a fixture of. Everything here is eyeballed —
// the list is short on purpose, and the audit re-reports whatever survives regardless.
// NOTE the lowercase rule is deliberately NOT `^[a-z][a-z0-9_]*$`. That shape also
// matches user content — `testing2` is a pin description, `mariosworld343` is an author
// name — and shielding it here stopped `isOpaqueId` from ever firing on it. A real
// snake_case enum has an underscore; a bare lowercase word has no digits.
const SCHEMA_CONSTANT = [
  /^XDT[A-Za-z]+$/,               // GraphQL typenames: XDTFeedMedia
  /^[a-z][a-z0-9]*(_[a-z0-9]+)+$/, // snake_case enums: carousel_container, react_grid_pin
  /^[a-z]+$/,                     // bare lowercase words: clips, board, pin
  /^[A-Z][A-Z0-9_]*$/,            // UPPER_SNAKE enums: NONE, DEFAULT, NZD
  /^[A-Z][a-z]+$/,                // single capitalised words: Active
];
const isSchemaConstant = (s) => SCHEMA_CONSTANT.some((re) => re.test(s));

// An opaque handle-shaped identifier: IG post shortcodes (`C-rig7dCqdD`), signed-url
// fragments, anything that mixes character classes without being prose. These are
// content — `instagram.com/p/C-rig7dCqdD/` addresses a real post — and the first pass
// let them through because they are short and have no whitespace.
const isOpaqueId = (s) =>
  s.length >= 8 && /^[A-Za-z0-9_-]+$/.test(s) && !isSchemaConstant(s)
  && ((/[A-Z]/.test(s) && /[a-z]/.test(s)) || (/[A-Za-z]/.test(s) && /\d/.test(s)));
// An opaque token: long, url-safe-alphabet, and mixing character classes. Cursors,
// tracking tokens, signed-url params. Deliberately NOT matching snake_case enums.
const isToken = (s) =>
  s.length >= 20 && /^[A-Za-z0-9_\-=+/.:]+$/.test(s) && /\d/.test(s) && /[A-Za-z]/.test(s)
  && !/^[a-z][a-z0-9_]*$/.test(s);
// A Base64 node id. X's GraphQL `id` is `base64("User:<pk>")` — `VXNlcjoyODQwNzIzMTg=`
// decodes to `User:284072318`, a real account. It reached the end of the sweep because
// base64 of a short numeric id happens to contain NO ASCII DIGIT, and `isToken` demands
// one; `=` is outside `isOpaqueId`'s alphabet, so that missed it too. The same "the value
// lacks a character class the rule insists on" failure as the composite id above.
//
// Decoding is the discriminator, and it has to be: `application/x-mpegURL` is 21 url-safe
// characters with no digit either, and it is a CONTENT TYPE the X video mapper picks
// against. Requiring valid padded base64 that decodes to printable ASCII separates them —
// the mime type is not base64 at all (21 is not a multiple of four, and `-` is outside the
// alphabet). Across every capture in `resources/` this matches three values and all three
// are `User:<pk>`. Simply dropping `isToken`'s digit rule was the obvious alternative and
// is WRONG: it would swallow `TimelineTimelineItem`, `XDTCarouselContainerMedia` and
// `VerticalConversation` — the `__typename`s every X and IG parser branches on.
const isBase64Id = (s) =>
  s.length >= 12 && s.length % 4 === 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(s)
  && /^[\x20-\x7E]+$/.test(Buffer.from(s, "base64").toString("latin1"));
// Free text: anything a human wrote. Whitespace, non-ASCII, or simply long.
const isFreeText = (s) => /\s/.test(s) || /[^\x20-\x7E]/.test(s) || s.length > 30;
// Contact details. `redacted@example.com` fell through every other predicate: too short
// to be free text, and `@` is in none of the token/id character classes.
const isEmail = (s) => /^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$/.test(s);
const isPhone = (s) => /^\+?[\d\s()-]{7,}$/.test(s) && (s.match(/\d/g) || []).length >= 7;
// A site-relative path. Not a URL (no scheme) so the URL rule never saw it, but
// `/sujenphea0843/test2/` names both a person and a board, and the Pinterest mapper
// reads exactly this field.
const isPath = (s) => /^\/[^\s?#]*\/?$/.test(s) && s.length > 1;
// Money. `NZ$76.00` is the price of a pinned product — content, and it matched nothing:
// no whitespace, under the free-text length, and `$` is outside every id/token class.
const isMoney = (s) => /[$\u20ac\u00a3\u00a5]/.test(s) && /\d/.test(s);

// ---------------------------------------------------------------------------
// Identity strings, collected STRUCTURALLY then replaced GLOBALLY by value
// ---------------------------------------------------------------------------
// Handles and display names are the one class shape alone cannot catch: `framer` is
// indistinguishable from an enum. So they are collected wherever they appear under an
// identity-ish key, and then every occurrence of that VALUE is replaced everywhere in
// the document — including keys the collector never looked at. Collection is key-
// assisted; replacement is not.

// `author_name` was missing and leaked `mariosworld343`; `site_name` names the source
// brand of a pin. Collection is broad on purpose — a false positive costs one synthetic
// string, a false negative is a leak.
// `nick_?name` covers BOTH of rednote's spellings — the board feed says `nick_name`, note
// detail says `nickname` (098 D6) — and the underscored one is why this is here: the
// 2026-09-13 board capture carried `Neurobin`, `LEE`, `ruirui` and `snow`, display names
// that are shape-identical to the schema constants below and so survived every value
// rule. Exactly the class the note at the top of this section describes.
// The key list lives in `capture-keys.js`, because the AUDIT needs the same one — a
// survivor that arrived under an identity key is never excusable there, whatever it looks
// like, and the two lists silently disagreeing is what let `creativemints` and `framer`
// report as STRUCTURAL survivors for a month. `top_likers` is the sharpest case for a rule
// like this: it is a bare ARRAY OF HANDLES with no identity-ish key on any leaf, and all
// three it carries on 2026-09-14 were invisible to shape — `the__divyabansal` has a DOUBLED
// underscore so it is neither snake_case nor a schema constant, yet `isOpaqueId` still
// refused it for having neither a capital nor a digit, while `nabiistudio` and
// `lainyschulz` are bare lowercase words that shape treats as enums by design.
const identity = new Set();

function collectIdentity(node, key = "") {
  if (Array.isArray(node)) return node.forEach((v) => collectIdentity(v, key));
  if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) collectIdentity(v, k);
    return;
  }
  if (typeof node === "string" && node && IDENTITY_KEY.test(key) && !isUrl(node)) {
    identity.add(node);
  }
}
collectIdentity(raw);

// Viewer-context subtrees: everything below them describes the requester, not the
// content. Pinterest's BoardsResource ships `client_context` with the account email,
// gender and IP region sitting beside ordinary enums.
const VIEWER_KEY = /^(client_context|viewer|request_identifier|user_context|context)$/i;
const viewer = new Set();

function collectViewer(node, inside = false) {
  if (Array.isArray(node)) return node.forEach((v) => collectViewer(v, inside));
  if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) collectViewer(v, inside || VIEWER_KEY.test(k));
    return;
  }
  if (inside && typeof node === "string" && node) viewer.add(node);
}
collectViewer(raw);

// ---------------------------------------------------------------------------
// Stable synthetic replacements — same input value → same output value, so the
// document stays internally consistent (a pk referenced twice stays one pk).
// ---------------------------------------------------------------------------

const memo = new Map();
const counters = { url: 0, id: 0, composite: 0, token: 0, text: 0, handle: 0, code: 0, path: 0, contact: 0, forced: 0, host: 0, money: 0, num: 0 };

// PLATFORM hosts are kept — the mappers branch on them (i.pinimg.com's size segment, the
// pbs/video.twimg split), so replacing them would break the very signal the fixture exists
// to prove. Everything else is content: a board feed carries the SOURCE domain of every
// pin, and keeping those both reveals what was pinned and smuggles handles through
// wholesale (`mightyape` survived inside `mightyape.co.nz`, `creativebysanchez` inside its
// own domain) because the audit matches substrings.
// rednote is the sharpest case for keeping a platform host: `toRednoteOriginal` returns
// its input UNCHANGED unless the host ends in `rednotecdn.com`, so replacing the host does
// not merely blur a signal — it switches the entire rewrite off, and a fixture whose
// covers were never rewritten proves the opposite of what the canary asks.
const PLATFORM_HOST = /^(www\.)?(pinterest\.com|pinimg\.com|instagram\.com|cdninstagram\.com|fbcdn\.net|twimg\.com|x\.com|twitter\.com|rednote\.com|xiaohongshu\.com|rednotecdn\.com)$|\.(pinimg\.com|cdninstagram\.com|fbcdn\.net|twimg\.com|rednotecdn\.com)$/;
// CASE-INSENSITIVE, because a host in a display string is whatever the person typed:
// `MindfulMotif.com` and `Motionsites.ai` ride X's `display_url`, `Deck.Gallery` and
// `LibroWorld.com` ride Pinterest's `full_name`, `JustInCase.co` a rednote `nick_name`.
// Anchored lowercase, the rule saw a dotted CamelCase name as not-a-host and passed it to
// predicates that all require a digit or a mixed case run, and it left every one verbatim.
const isBareHost = (s) => /^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(s) && /\.[a-z]{2,}$/i.test(s);
// A SCHEME-LESS url: a bare host with a path glued on. X's `display_url` is the whole of
// this class — `dribbble.com/creativemints` names a person, `pic.x.com/ThfGGeacLy` names a
// photo — and it matched nothing: no scheme for `isUrl`, a slash `isBareHost` rejects, no
// leading slash for `isPath`, under 31 characters for `isFreeText`, and no digit for
// `isToken`. The host half is what keeps this from reaching a mime type: `application` in
// `application/x-mpegURL` has no dot, so it is not a host and the content type survives.
const isHostPath = (s) => {
  const slash = s.indexOf("/");
  return slash > 0 && !/[\s?#]/.test(s) && isBareHost(s.slice(0, slash));
};
// rednote's own CDN, post-normalisation (its hosts survive by design — see PLATFORM_HOST).
const REDNOTE_CDN_HOST = /(^|\.)rednotecdn\.com$/;
// A path segment that is ROUTE rather than content: a bare lowercase word, or a number too
// short to be an id or an epoch. Deliberately narrow — `oss-sg`, `notes_pre_post` and every
// object key fail it and are still replaced.
const isRouteToken = (s) => /^[a-z]+$/.test(s) || /^\d{1,5}$/.test(s);

function normaliseHost(h) {
  // A locale subdomain says where the capture was taken; the driver targets `www`.
  const local = h.replace(/^[a-z]{2}\.pinterest\.com$/, "www.pinterest.com");
  if (PLATFORM_HOST.test(local)) return local;
  if (memoHost.has(h)) return memoHost.get(h);
  const tld = (h.match(/\.([a-z]{2,})$/) || [, "com"])[1];
  const out = `sample${++counters.host}.example.${tld}`;
  memoHost.set(h, out);
  return out;
}
const memoHost = new Map();

function syntheticUrl(s) {
  let u;
  try { u = new URL(s); } catch { return "https://example.invalid/SAMPLE"; }
  u.host = normaliseHost(u.host);
  // A `!…` suffix on the last segment is a CDN rendering directive, not identity:
  // rednote's signed urls end `!nc_n_webp_mw_1`, and stripping it is half of what
  // `toRednoteOriginal` does. Dropped, the fixture cannot show the strip happening — the
  // canary's "no transform suffix survived the rewrite" check would pass on a url that
  // never had one. Kept verbatim, beside the extension, for the same reason.
  const transform = (u.pathname.match(/!.*$/) || [])[0] || "";
  const ext = (u.pathname.replace(/!.*$/, "").match(/\.(jpg|jpeg|png|gif|webp|mp4|m3u8|webm)$/i) || [])[0] || "";
  // Host and path DEPTH are load-bearing (the Pinterest mapper rewrites the size segment
  // to /originals/; the X mapper splits on the pbs/video host; rednote's key rule drops
  // the first two segments of `<timestamp>/<signature>/<key>`, so a flattened path would
  // turn that rewrite into a passthrough). Keep both; replace the segments themselves.
  const raw = u.pathname.split("/").filter(Boolean);
  const depth = raw.length;
  const n = ++counters.url;
  const segs = [];
  // …and so is the SHAPE of that signing prefix, now that `toRednoteOriginal` strips on
  // shape rather than on depth: rednote's video streams are unsigned (`/stream/1/…`) and
  // depth alone cannot tell them from a signed image. `00/00` is not a
  // `<timestamp>/<signature>`, so a fixture sanitized to it would pass STRAIGHT THROUGH —
  // the same "proves the opposite of what the canary asks" trap the host and the `!`
  // suffix already fell into. The filler keeps the shape and stays all-zero.
  let i = 0;
  // The UNSIGNED half of the same CDN, and the third time this sweep has flattened
  // something the rednote rewrite is defined against. rednote serves video and subtitles
  // with no signing prefix at all and REAL ROUTE in that position —
  // `/stream/1/110/258/<id>_258.mp4` — where `stream` is the service, `1` the biz
  // version, `110` the biz_name and `258` the stream_type. Sanitized to `/00/00/00/00/`
  // the fixture still parses, but it can no longer show the one thing 098 T6 asks of it:
  // that the selector's chosen url is an unsigned stream path `toRednoteOriginal` leaves
  // alone, and that the rung's `_<stream_type>` suffix agrees with its `stream_type`
  // field. A route segment cannot carry identity by construction — it is a bare lowercase
  // word or a number under six digits, the same two classes the value sweep already
  // treats as schema — so it is kept verbatim, and anything else in that position is
  // still replaced.
  let streamSuffix = "";
  if (depth >= 3 && /^\d{10,14}$/.test(raw[0]) && /^[0-9a-f]{32}$/i.test(raw[1])) {
    segs.push("000000000000", "0".repeat(32));
    i = 2;
  } else if (REDNOTE_CDN_HOST.test(u.host)) {
    for (; i < Math.max(depth - 1, 0); i++) segs.push(isRouteToken(raw[i]) ? raw[i] : "00");
    // `_258` on the filename is the stream_type, not identity: it is the ONLY place the
    // rung's codec discriminator appears in a url, and 020's undecodable manual pick was
    // a `_330`. Kept beside the extension for the same reason the `!` directive is.
    const bare = String(raw[depth - 1] || "").replace(/!.*$/, "");
    const streamType = (bare.match(/_(\d{1,5})(?=\.[A-Za-z0-9]+$|$)/) || [, ""])[1];
    if (streamType) streamSuffix = `_${streamType}`;
  }
  for (; i < Math.max(depth - 1, 0); i++) segs.push("00");
  const last = `SAMPLE${n}${streamSuffix}${ext}${transform}`;
  // The QUERY was dropped WHOLESALE, which is right for everything that normally rides in
  // one — `?sign=…` and `xsec_token` are credentials — and wrong for the one thing in a
  // query that is not identity at all: rednote's OTHER transform spelling,
  // `?imageView2/2/w/540/format/jpg/q/75`, which is what a live `board/info` response puts
  // on every cover. Flattened away, such a fixture proves the opposite of what the canary
  // asks, the fifth time this sweep has erased the very shape `toRednoteOriginal` is
  // defined against (483 the CDN host, 485 the `!` suffix, 487 the signing prefix, 488 the
  // unsigned `/stream/` route). So a transform directive is kept VERBATIM and every other
  // query component is still dropped — `isTransformDirective` is imported, not respelled,
  // because a private copy here is exactly how the fixture and the rewrite drift apart.
  const directives = u.search.replace(/^\?/, "").split("&").filter(isTransformDirective);
  const search = directives.length ? `?${directives.join("&")}` : "";
  return `${u.protocol}//${u.host}/${[...segs, last].join("/")}${search}`;
}

// A path that names a ROUTE and an ID is not the same shape as one that names a person and
// a board, and the sweep had been flattening both to `/sampleuserN/sampleN/`. Pinterest
// ships `seo_url: "/pin/1084663891531274043/"` and `pinIdFrom` recovers a pin's id from it
// with `/\/pin\/(\d+)/` when the canonical `id` is missing, while `mapPinterestPin` builds
// the permalink from it directly — so a fixture sanitized to `/sampleuser1/sample1/` cannot
// show either working. Six-and-a-half weeks of Pinterest fixtures have had that url and
// nobody could have noticed, because every pin in them also carries `id`.
//
// The leading segment is kept ONLY when a LATER one is a bare long digit run, which is what
// makes it a route rather than a name. `/sujenphea0843/websites/` has no id segment, so it
// keeps flattening whole — and it must, because `websites` is a BOARD NAME and is
// character-for-character the shape of a route word. Keeping a leading lowercase word
// unconditionally would have leaked exactly that, and an all-lowercase Pinterest username
// (`nagomi`, `onukhan`) in the same position with it.
function syntheticPath(s) {
  const segs = s.split("/").filter(Boolean);
  const n = ++counters.path;
  const isIdSegment = (seg) => /^\d{6,}$/.test(seg);
  const routed = /^[a-z]+$/.test(segs[0] || "") && segs.slice(1).some(isIdSegment);
  const parts = segs.map((seg, i) => {
    if (routed && i === 0) return seg;
    if (isIdSegment(seg)) return syntheticDigits(seg);
    return i === 0 ? `sampleuser${n}` : `sample${n}`;
  });
  return `/${parts.join("/")}${s.endsWith("/") ? "/" : ""}`;
}

// Same treatment as a url, one level down: the host goes through `normaliseHost` (so a
// PLATFORM host is still kept, and `x.com/…` still reads as X) and every path segment is
// replaced while the depth and any trailing slash stay put.
function syntheticHostPath(s) {
  const slash = s.indexOf("/");
  const n = ++counters.path;
  const segs = s.slice(slash + 1).split("/").map((seg) => (seg ? `sample${n}` : ""));
  return `${normaliseHost(s.slice(0, slash))}/${segs.join("/")}`;
}

// Re-encoded rather than blanked, so the fixture still shows a BASE64 `id` beside the
// plain `rest_id` — that pairing is the shape, and a parser that started decoding node ids
// would want a decodable one to fail against. The payload inside is a placeholder.
function syntheticBase64Id(s) {
  return Buffer.from(`Sample:${++counters.token}`).toString("base64");
}

// Replace ONE all-digit run with a synthetic of the SAME LENGTH. Memoised on the run
// itself, not on the leaf that contains it, so a pk that appears both alone and as a
// component of a composite lands on one synthetic value and the document stays
// internally consistent — the same reason `memo` exists a level up.
const memoDigits = new Map();
function syntheticDigits(run) {
  if (memoDigits.has(run)) return memoDigits.get(run);
  // The sign rides along rather than being counted as a character — a Pinterest id that
  // came back negative goes back out negative and the same number of digits long.
  const sign = run.startsWith("-") ? "-" : "";
  const digits = run.slice(sign.length);
  const n = String(++counters.id).padStart(4, "0");
  const body = `1${"0".repeat(Math.max(digits.length - 5, 0))}${n}`
    .slice(0, digits.length).padEnd(digits.length, "0");
  const out = sign + body;
  memoDigits.set(run, out);
  return out;
}

// Rebuild a composite run by run, KEEPING its shape: same run count, same run lengths,
// same separators. Flattening it to one opaque `SAMPLE…` would cost the fixture the two
// things this value is actually read for — X's `media_key` is the per-ASSET `sourceId` in
// `bulk-twitter.js` and the canary fails the page if two of them collide, and its leading
// run is the photo/video discriminator. A run too short to be an id survives verbatim for
// exactly the reason `isRouteToken` keeps a short numeric path segment: one or two digits
// cannot name anybody. Everything else in the value is replaced.
function syntheticCompositeId(s) {
  const tail = (s.match(/[A-Za-z]$/) || [""])[0];
  const runs = s.replace(/[A-Za-z]$/, "").split("_");
  counters.composite += 1;
  return runs.map((run) => (run.length >= 6 ? syntheticDigits(run) : run)).join("_") + tail;
}

function replaceString(s) {
  if (memo.has(s)) return memo.get(s);
  let out = s;
  if (identity.has(s)) out = `sampleuser${++counters.handle}`;
  else if (isEmail(s)) out = `sample${++counters.contact}@example.invalid`;
  else if (isMoney(s)) out = `$${++counters.money}.00`;
  // ABOVE `isPhone`, which is a reorder and not a cosmetic one. `isPhone` accepts a BARE
  // RUN OF SEVEN OR MORE DIGITS, so it had been swallowing every id in every capture —
  // 898 distinct in `resources/` — and stamping them `+100000042`. Nothing leaked; the
  // SHAPE did. The X canary derives a tweet's identity from its permalink with
  // `/status\/(\d+)/`, and `https://x.com/sampleuser1/status/+100000002` does not match
  // it, so a freshly sanitized bookmarks fixture reported all seven of its tweets as
  // mapping to no item. The committed X fixtures never showed it because their ids were
  // written by hand. There is not one real phone number in any capture here: every
  // punctuated `isPhone` hit in the corpus is this sweep's OWN earlier output read back
  // out of a `-clean` file, so the rule keeps only the shapes a bare integer cannot have.
  else if (isLongDigits(s)) out = syntheticDigits(s);
  else if (isPhone(s)) out = `+10000000${counters.contact++}`;
  else if (isUrl(s)) out = syntheticUrl(s);
  else if (isBareHost(s)) out = normaliseHost(s);
  else if (isHostPath(s)) out = syntheticHostPath(s);
  else if (isPath(s)) out = syntheticPath(s);
  // BEFORE `isFreeText`, and that ordering is the whole point. A composite is only ever
  // 21-31 characters, so `length > 30` caught the longest ones and turned them into
  // `Sample text N` — which is why the hole read as "handled" for a month. Below the free-
  // text branch this rule would go on being shadowed for precisely the values that DID
  // get sanitized, and fire only for the ones that leaked.
  else if (isCompositeDigits(s)) out = syntheticCompositeId(s);
  else if (isToken(s)) out = `SAMPLE_TOKEN_${++counters.token}`;
  // AFTER `isToken`, so nothing that rule already handles changes hands, and BEFORE
  // `isFreeText`, so a node id long enough to trip `length > 30` is still re-encoded as
  // base64 instead of flattened to prose.
  else if (isBase64Id(s)) out = syntheticBase64Id(s);
  else if (isFreeText(s)) out = `Sample text ${++counters.text}`;
  else if (isOpaqueId(s)) out = `SAMPLECODE${++counters.code}`;
  // Inside a viewer-context subtree nothing is schema — it is all facts about the person
  // who made the request. `AUK` (an IP region) and `female` are shape-identical to enums,
  // so shape can never reach them; the subtree is collected wholesale instead and, like
  // the identity set, replaced GLOBALLY by value. This is the second key-assisted rule,
  // and like the first it only ever ADDS coverage.
  else if (viewer.has(s)) out = `sample${++counters.forced}`;
  memo.set(s, out);
  return out;
}

// Integers big enough to be an id or an epoch carry identity; small ones are geometry
// (width/height), enum codes, and bitrates the mappers actually choose on.
const NUM_FLOOR = 1_000_000;
const COUNT_KEY = /_count$|^count$/;

// Prose, and the third key-assisted rule — stated outright, like the count rule below,
// because shape CANNOT do this one. `Test-3` and `test-3` are Pinterest board descriptions
// and `(dream)`, `MONACO`, `addiction` and `Sunkissed` are IG music titles; every one is
// under the free-text length, none has whitespace, and each is character-for-character the
// shape of an enum. Widening a value predicate to reach them is the mistake this file
// already made once — a `SCHEMA_CONSTANT` loose enough to cover `testing2` was a pin
// description shielded as though it were schema.
//
// Scoped to the keys the platforms actually put prose in, and LOCAL rather than global-by-
// value like the identity set: a one-word description ("Home", "Websites") must not go on
// to rewrite every matching enum in the document. Across every capture in `resources/`
// these keys hold 238 distinct values and not one of them is a response-format constant,
// so there is nothing here to shield.
//
// `location` and `short_name` are here rather than in the identity set on purpose. They
// hold places — `Prague`, `Remote`, `Internet`, `Nantes` — and the identity set replaces
// GLOBALLY BY VALUE, so a profile whose location reads `Remote` would go on to rewrite
// every other `Remote` in the document. A place needs removing, not tracking across the
// document the way a handle does, so the local rule is the right one.
const TEXT_KEY = /^(description|desc|title|display_title|caption|subtitle|location|short_name)$/;

// `SCHEMA_KEY` (imported above) is the one key-assisted rule in this file that SHIELDS
// rather than replaces, which is the dangerous direction, so it is drawn as narrowly as the
// evidence allows — see capture-keys.js for what it holds and why shape cannot do it.
// Before it existed, `isOpaqueId` read `entryType: "TimelineTimelineItem"` as an opaque
// handle (eight or more characters, mixes upper and lower, matches no schema-constant rule)
// and rewrote it to `SAMPLECODE1`; the sanitized bookmarks capture then parsed to ZERO
// tweets and no cursor. The August X fixtures never showed it because their envelopes were
// kept by hand.
const memoText = new Map();
function syntheticText(s) {
  if (memoText.has(s)) return memoText.get(s);
  const out = `Sample text ${++counters.text}`;
  memoText.set(s, out);
  return out;
}

function walk(node, key = "") {
  if (Array.isArray(node)) return node.map((v) => walk(v, key));
  if (node && typeof node === "object") {
    const out = {};
    for (const [k, v] of Object.entries(node)) out[k] = walk(v, k);
    return out;
  }
  if (typeof node === "string") {
    // A count is not always a number. rednote ships `interact_info` counts as STRINGS,
    // already formatted for display — `"27.7K"`, `"5,123"`, `"795"` — so the numeric rule
    // below never saw them and every one survived the sweep verbatim. Same key-assisted
    // rule, same reasoning, the other type.
    if (SCHEMA_KEY.test(key)) return node;
    if (COUNT_KEY.test(key)) return "0";
    if (node && TEXT_KEY.test(key)) return syntheticText(node);
    return replaceString(node);
  }
  if (typeof node === "number" && Number.isFinite(node)) {
    // Engagement counts are keyed, not shaped — a like count and a pixel width are the
    // same shape. This is the one key-assisted rule in the sweep, and it is stated
    // outright rather than hidden behind a shape predicate that could not work.
    if (COUNT_KEY.test(key)) return 0;
    if (Number.isInteger(node) && Math.abs(node) >= NUM_FLOOR) return 1000000 + (++counters.num);
  }
  return node;
}

const clean = walk(raw);
const cleanText = JSON.stringify(clean, null, 1);

// THE GATE, and the reason it is here rather than in a README step. Every rule above is a
// GUESS about a value's shape, and this file has been wrong about one six times in a week
// — five times destroying a signal, once (498) keeping 87 real Instagram ids. The audit
// has always computed the one number that matters and has always exited non-zero on it,
// but nothing ever RAN it except a person deciding to, so `LEAKED: 176` sat in a terminal
// unread. Now a leaking fixture is never written at all: the sweep audits its own output
// and refuses. A new capture that carries a shape no rule here knows about fails loudly at
// the moment it is produced, which is the only moment anyone is looking.
const report = auditCapture(raw, cleanText);
if (report.LEAKED > 0) {
  console.error(JSON.stringify({ REFUSED: outPath, ...report }, null, 1));
  console.error(`\n${report.LEAKED} value(s) of ${inPath} survived the sweep verbatim.`
    + " Nothing was written."
    + "\nAdd a rule for the shape above, or — if every one of them is response FORMAT and"
    + " not content — say so on audit-capture.js's STRUCTURAL list, with the evidence.");
  process.exit(1);
}

writeFileSync(outPath, cleanText);

console.log(JSON.stringify({
  in: inPath, out: outPath,
  identityValues: identity.size,
  replaced: counters,
  audit: { survived: report.survived, LEAKED: report.LEAKED, structural: report.structuralSurvivors },
  bytes: cleanText.length,
}, null, 1));
