// Audit a sanitized fixture against the raw capture it came from.
//
// The check is deliberately blunt and one-directional: take EVERY leaf string in the
// ORIGINAL and assert it does not appear anywhere in the sanitized text. Not "every
// field we thought to sanitize" — every leaf, including ones the sweep never reasoned
// about. That is what caught the avatar.image_url leak on X after two clean-looking
// passes.
//
// What may legitimately survive is a schema constant: a value that is part of the
// response FORMAT rather than its content (enum codes, mime types, field-ish literals).
// Those are reported separately so they can be eyeballed, never auto-approved.
//
//   node audit-capture.js <raw.json> <clean.json>
//
// `auditCapture` is EXPORTED because `sanitize-capture.js` calls it before it writes and
// refuses to produce a leaking fixture (498). That is what turned this from a report into
// a gate: the number was always here, but only a human reading stdout ever acted on it,
// and the composite-id hole rode out of six sweeps at `LEAKED: 176` unnoticed. Imported
// rather than respelled over there, for the same reason `isTransformDirective` is.

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
// The same two key rules the sweep uses — imported, never respelled, because the whole
// failure this closes was the two files quietly disagreeing about them.
import { IDENTITY_KEY, SCHEMA_KEY } from "./capture-keys.js";

/** Every leaf string of `raw` that survives verbatim into `cleanText`, split into the ones
 * that are excusable as response FORMAT and the ones that are a leak. */
export function auditCapture(raw, cleanText) {
  // Leaves are collected WITH the keys they sat under, for one reason only: see
  // `onlyADiscriminator` below. Nothing else here looks at a key — the sweep this audits is
  // key-independent and so is the check.
  const leaves = new Map();
  (function walk(n, key = "") {
    if (Array.isArray(n)) return n.forEach((v) => walk(v, key));
    if (n && typeof n === "object") { for (const [k, v] of Object.entries(n)) walk(v, k); return; }
    if (typeof n === "string" && n.length > 0) {
      if (!leaves.has(n)) leaves.set(n, new Set());
      leaves.get(n).add(key);
    }
  })(raw);

  const onlyADiscriminator = (s) => [...leaves.get(s)].every((k) => SCHEMA_KEY.test(k));
  // The other direction, and the one that closes the biggest hole in this check: a survivor
  // that arrived under an IDENTITY key is never excusable, whatever it looks like. X's
  // handles are `creativemints`, `framer`, `figma` and `awwwards` — bare lowercase words,
  // which `^[a-z]+$` above waves through as schema — and this audit reported all four as
  // STRUCTURAL survivors while they sat verbatim in the output. Shape cannot tell a handle
  // from an enum. The key it arrived under can, and it is the same key list the sweep
  // collects identities with, so the two can no longer drift apart.
  const namesSomebody = (s) => [...leaves.get(s)].some((k) => IDENTITY_KEY.test(k));
  const excusable = (s) => !namesSomebody(s) && (looksStructural(s) || onlyADiscriminator(s));

  const survivors = [...leaves.keys()].filter((s) => cleanText.includes(s));
  const structural = survivors.filter(excusable);
  const leaked = survivors.filter((s) => !excusable(s));

  return {
    distinctLeafStrings: leaves.size,
    survived: survivors.length,
    LEAKED: leaked.length,
    leakedSamples: leaked.slice(0, 25),
    structuralSurvivors: structural.length,
    structuralSamples: structural,
  };
}

// A survivor is only excusable if it is structural, and "structural" means it looks like
// something a SCHEMA author wrote: a snake_case or UPPER_SNAKE enum, a capitalised word,
// a GraphQL typename. The first version of this predicate accepted any short alphanumeric
// run — which quietly excused three Instagram post shortcodes (`C-rig7dCqdD`), values
// that address real posts. Mixing character classes is now disqualifying, because that is
// what opaque identifiers do and schema constants do not.
const STRUCTURAL = [
  /^XDT[A-Za-z]+$/,
  // Mirrors the sanitizer: an enum has an underscore, a bare word has no digits. The
  // permissive `^[a-z][a-z0-9_]*$` this replaced excused `testing2` (a pin description)
  // and `mariosworld343` (an author name) as though they were schema.
  /^[a-z][a-z0-9]*(_[a-z0-9]+)+$/,
  /^[a-z]+$/,
  /^[A-Z][A-Z0-9_]*$/,
  /^[A-Z][a-z]+$/,
  // Mime types: application/json — and `application/x-mpegURL`, X's HLS variant, which the
  // all-lowercase subtype this replaced could not spell. That value is load-bearing: the X
  // video mapper picks the MP4 variant BY content type, so a fixture that lost it would
  // stop proving the HLS one gets rejected.
  /^[a-z]+\/[A-Za-z0-9.+-]+$/,
  // A locale. `en_US` rides IG's `video_subtitles_locale` and describes the POST's
  // subtitles, not the viewer — a viewer's locale sits under `client_context`, which the
  // sanitizer empties wholesale rather than leaving to this list. Lowercase language plus a
  // separator plus a region; a handle does not look like this.
  /^[a-z]{2,3}[_-][A-Za-z]{2,4}$/,
  // A dotted version. Pinterest ships `0.16.0` / `0.8.0` on `story_pin_data.metadata`,
  // which is a SCHEMA version of the story-pin document. The version-shaped values that
  // are NOT schema — `browser_version`, `os_version` — are viewer facts, and they are gone
  // before this list sees them because they live inside `client_context`. If a capture ever
  // moves one OUT of that subtree this rule would wave it through, so that is the thing to
  // check when Pinterest reshapes its envelope.
  /^\d{1,3}(\.\d{1,4}){1,3}$/,
  // Pinterest's field mask: `add_fields: "board.{meal_plan}"` requests one extra field on
  // the board type, and sits beside `field_set_key` and `sort` in the request options it
  // echoes back. Braces make it unmistakable — a person's board is never named this.
  /^[a-z][a-z0-9_]*\.\{[a-z0-9_,()]+\}$/,
  // Short numeric literals ("0", a pixel width) — too short to be an id. FIVE, not seven:
  // the shortest standalone id in any capture here is IG's 7-digit `pk` `8046568`, and at
  // `\d{1,7}` this rule excused it and X's `9655742` outright. Five is the floor the sweep
  // itself draws (`isLongDigits`, `isRouteToken`, the composite rule), and nothing is lost
  // by it: every five- and six-digit string in every capture in `resources/` sits under a
  // `*_count` key, which the sweep zeroes.
  /^\d{1,5}$/,
  /^#[0-9a-fA-F]{3,8}$/,      // dominant_color hex — derived from pixels, names nobody
  /^\s+$/,                    // whitespace-only leaves
  /^-end-$/,                  // Pinterest's end-of-feed cursor sentinel — load-bearing
  // Container/codec literals. `mp4` is a bare word with a DIGIT in it, so the lowercase
  // rule cannot reach it and every rednote video rung's `format` reported as a leak.
  // Enumerated rather than loosened: `^[a-z][a-z0-9]*$` would re-excuse `testing2` and
  // `mariosworld343`, the exact two the lowercase rule was tightened for.
  /^(mp4|m3u8|mpd|webm|mov|h264|h265|hevc|av1|avc1|hvc1|aac|mp3|opus)$/,
  // Hosts survive by design (see normaliseHost in the sanitizer). Listed explicitly so
  // that a host is a DECISION recorded here, not something the shape rules waved through.
  /^(www\.pinterest\.com|i\.pinimg\.com|instagram\.com|www\.instagram\.com|[a-z0-9-]+\.cdninstagram\.com|[a-z0-9-]+\.fbcdn\.net|x\.com|pbs\.twimg\.com|video\.twimg\.com)$/,
  /^https:\/\/(www\.pinterest\.com|instagram\.com|www\.instagram\.com|x\.com)\/?$/,
];
const looksStructural = (s) => s.length <= 40 && STRUCTURAL.some((re) => re.test(s));

// `SCHEMA_KEY` (imported) names the envelope's TYPE DISCRIMINATORS, which the sweep keeps
// verbatim. They are excused by that same test rather than by a new shape rule, because the
// shape in question is PascalCase and that is also what `JayBorda` and `RasmusNielsen` look
// like: a `/^[A-Z][a-z]+([A-Z][a-z]+)+$/` on the list above would excuse a surviving real
// name for the rest of this file's life. A value is excused only if EVERY place it appears
// in the original is such a key — one appearance under a content key and it is a leak.

// Run as a CLI only when invoked directly — `sanitize-capture.js` imports `auditCapture`
// and must not trip this.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , rawPath, cleanPath] = process.argv;
  const report = auditCapture(JSON.parse(readFileSync(rawPath, "utf8")),
    readFileSync(cleanPath, "utf8"));
  console.log(JSON.stringify(report, null, 1));
  process.exit(report.LEAKED ? 1 : 0);
}
