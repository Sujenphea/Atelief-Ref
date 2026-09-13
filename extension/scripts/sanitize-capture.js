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

const [, , inPath, outPath] = process.argv;
const rawText = readFileSync(inPath, "utf8");
const raw = JSON.parse(rawText);

// ---------------------------------------------------------------------------
// Shape predicates — the whole policy, in one place
// ---------------------------------------------------------------------------

const isUrl = (s) => /^https?:\/\//.test(s);
// A trailing letter suffix is still an id: IG ships `814154277899006v`. The first pass
// required all-digits and leaked exactly those.
const isLongDigits = (s) => /^\d{8,}[A-Za-z]?$/.test(s);

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
const IDENTITY_KEY = /username|full_name|biography|^name$|nick_?name|profile_grid|owner_name|author_name|site_name|creator|pinner/i;
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
const counters = { url: 0, id: 0, token: 0, text: 0, handle: 0, code: 0, path: 0, contact: 0, forced: 0, host: 0, money: 0, num: 0 };

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
const isBareHost = (s) => /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(s) && /\.[a-z]{2,}$/.test(s);
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
  return `${u.protocol}//${u.host}/${[...segs, last].join("/")}`;
}

function syntheticPath(s) {
  const segs = s.split("/").filter(Boolean).length;
  const n = ++counters.path;
  const parts = Array.from({ length: segs }, (_, i) => (i === 0 ? `sampleuser${n}` : `sample${n}`));
  return `/${parts.join("/")}${s.endsWith("/") ? "/" : ""}`;
}

function replaceString(s) {
  if (memo.has(s)) return memo.get(s);
  let out = s;
  if (identity.has(s)) out = `sampleuser${++counters.handle}`;
  else if (isEmail(s)) out = `sample${++counters.contact}@example.invalid`;
  else if (isMoney(s)) out = `$${++counters.money}.00`;
  else if (isPhone(s)) out = `+10000000${counters.contact++}`;
  else if (isUrl(s)) out = syntheticUrl(s);
  else if (isBareHost(s)) out = normaliseHost(s);
  else if (isPath(s)) out = syntheticPath(s);
  else if (isLongDigits(s)) {
    const n = String(++counters.id).padStart(4, "0");
    out = `1${"0".repeat(Math.max(s.length - 5, 0))}${n}`.slice(0, s.length).padEnd(s.length, "0");
  } else if (isToken(s)) out = `SAMPLE_TOKEN_${++counters.token}`;
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
    if (COUNT_KEY.test(key)) return "0";
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
writeFileSync(outPath, JSON.stringify(clean, null, 1));

console.log(JSON.stringify({
  in: inPath, out: outPath,
  identityValues: identity.size,
  replaced: counters,
  bytes: JSON.stringify(clean).length,
}, null, 1));
