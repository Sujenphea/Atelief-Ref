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

import { readFileSync } from "node:fs";

const [, , rawPath, cleanPath] = process.argv;
const raw = JSON.parse(readFileSync(rawPath, "utf8"));
const cleanText = readFileSync(cleanPath, "utf8");

const leaves = new Set();
(function walk(n) {
  if (Array.isArray(n)) return n.forEach(walk);
  if (n && typeof n === "object") return Object.values(n).forEach(walk);
  if (typeof n === "string" && n.length > 0) leaves.add(n);
})(raw);

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
  /^[a-z]+\/[a-z0-9.+-]+$/,   // mime types: application/json
  /^\d{1,7}$/,                // short numeric literals ("0") — too short to be an id
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

const survivors = [...leaves].filter((s) => cleanText.includes(s));
const structural = survivors.filter(looksStructural);
const leaked = survivors.filter((s) => !looksStructural(s));

console.log(JSON.stringify({
  distinctLeafStrings: leaves.size,
  survived: survivors.length,
  LEAKED: leaked.length,
  leakedSamples: leaked.slice(0, 25),
  structuralSurvivors: structural.length,
  structuralSamples: structural,
}, null, 1));

process.exit(leaked.length ? 1 : 0);
