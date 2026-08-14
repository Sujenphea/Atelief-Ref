// Atelier Capture — the producer host-table agreement check (review issue 4).
//
// There are TWO producers of one capture contract: this extension, and the iOS share
// sheet (`AtelierCapture/Sources/AtelierCapture/ShareCapture.swift`, 092 · S4b-ii). Both
// turn a URL's host into a platform, and that file's own header states the rule — a host
// that means `twitter` in one of them cannot mean `web` in the other. Nothing checked it.
//
// The failure mode is why this is worth a check rather than a comment. Add a domain to a
// JS extractor and the phone keeps filing that site as `.web`; 18A dedup keys on
// provenance, so the two producers then FORK two assets off the same bytes instead of
// colliding on one. It presents as duplicates in the library, not as an error, which is
// the class of bug that lives for months.
//
// ── THE INVARIANT ────────────────────────────────────────────────────────────────────
//
//   For every domain D that the JS side classifies as a concrete platform P, running the
//   Swift `hostPlatforms` lookup on D must return P.
//
// It is deliberately stated as BEHAVIOUR ("what would the phone do with this host") and
// not as set equality between two lists, which buys three things:
//
//   · A domain a JS extractor knows and Swift does not resolves to `web` → drift, named.
//   · A domain both sides know but disagree about → drift, with both platforms named.
//   · A JS domain that is a SUBDOMAIN of a Swift row with the same platform is NOT drift.
//     Swift matches with `hostIs` (equal, or a subdomain), so `abs.twimg.com` under a
//     `twimg.com` row already resolves to `.twitter`. Set equality would have called that
//     a difference and taught everyone to ignore the check.
//
// ── THE ASYMMETRY IT PERMITS, AND WHY ────────────────────────────────────────────────
//
// Swift may carry domains no JS extractor names. That is not laxity; the two tables
// answer different questions. The extension classifies a page it is ALREADY RUNNING
// INSIDE. The share sheet classifies a string another app handed over. A domain can be
// reachable by the second and unreachable by the first, and `t.co` is exactly that: a
// shortener that 302s, so by the time a content script runs, `location.href` is already
// the destination and no extractor can ever observe `t.co`. Demanding symmetry would
// require the extension to declare a domain it can never see — a check satisfied by
// writing something untrue is worse than no check.
//
// The other direction is the unsafe one, and it is the one asserted. Swift-only rows are
// REPORTED rather than tolerated in silence, so a new one shows up in CI output where a
// reviewer can ask why it is only on one side.
//
// Deliberately out of scope: `ALLOWED_BUNDLE_HOSTS` in media-hosts.js. It is a script-
// fetch allowlist, not a platform classification — it declares no platform for its hosts,
// so any platform this check assigned them would be invented. (`abs.twimg.com` resolves
// to `.twitter` through the `twimg.com` row anyway, per the subdomain rule above.)

/** A `{ ok, problems, signals }` verdict — the same shape `drift.js` checks return, so
 * the CLI reports this one through the identical path. */
function verdict(problems, signals) {
  return { ok: problems.length === 0, problems, signals };
}

/** Files in `src/extractors/` that are NOT SiteExtractors. Everything else in that
 * directory must parse to a platform and at least one domain — which is the point of
 * naming the exclusions rather than the inclusions: a NEW extractor file is covered the
 * day it lands, instead of being invisible until someone remembers to list it.
 * `registry.js` holds the `web` catch-all, which matches everything and therefore names
 * no domain; `base.js` is helpers. */
const NOT_EXTRACTORS = new Set(["base.js", "registry.js"]);

/** Sanity floors. A regex that silently stops matching passes forever, so "we parsed
 * something plausible" is itself an invariant. These sit BELOW today's counts (15 Swift
 * rows, 9 extractor domains, 5 CDN domains) so that legitimately retiring one domain
 * doesn't trip them, and far enough above zero that a broken parser cannot. */
const FLOORS = { swiftRows: 12, extractorDomains: 7, cdnDomains: 4, extractorFiles: 4 };

/** The text between `source[openIndex]` and its matching close bracket. Depth-counted;
 * good enough here because neither table contains a bracket inside a string literal, and
 * a change that introduced one would break the row regexes loudly rather than quietly. */
function balancedSlice(source, openIndex, open, close) {
  let depth = 0;
  for (let i = openIndex; i < source.length; i += 1) {
    if (source[i] === open) depth += 1;
    else if (source[i] === close) {
      depth -= 1;
      if (depth === 0) return source.slice(openIndex + 1, i);
    }
  }
  return null;
}

/**
 * The `ShareCapture.hostPlatforms` rows, as `[{ domain, platform }]`.
 *
 * `platform` is the Swift CASE NAME (`.twitter` → `"twitter"`). For every case this
 * table uses, `Platform`'s rawValue equals its case name (`AtelierCore/Domain/Enums.swift`
 * gives explicit rawValues only to `localPaste` / `localDrag`, which no host maps to), so
 * comparing case names against the JS platform strings compares like with like.
 *
 * Throws rather than returning `[]` when the table cannot be found: "the file moved" and
 * "the tables agree" must never produce the same result.
 */
export function parseSwiftHostPlatforms(source) {
  const anchor = source.indexOf("static let hostPlatforms");
  if (anchor < 0) throw new Error("hostPlatforms table not found in ShareCapture.swift");
  // The `=` first, because the TYPE annotation `[(domain: String, platform: Platform)]`
  // carries a `[` of its own that is not the literal.
  const equals = source.indexOf("=", anchor);
  const open = equals < 0 ? -1 : source.indexOf("[", equals);
  const body = open < 0 ? null : balancedSlice(source, open, "[", "]");
  if (body == null) throw new Error("hostPlatforms table literal is unbalanced or empty");
  const rows = [];
  const ROW = /\(\s*"([^"]+)"\s*,\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*\)/g;
  for (const match of body.matchAll(ROW)) {
    rows.push({ domain: match[1].toLowerCase(), platform: match[2] });
  }
  return rows;
}

/** The platform a `hostPlatforms` table gives `domain`, by Swift's OWN rule — equal to a
 * row's domain, or a subdomain of it — falling back to `"web"` exactly as
 * `ShareCapture.platform(forURLString:)` does. This is the check's whole comparison:
 * simulate the phone rather than diff two lists. */
export function swiftPlatformFor(rows, domain) {
  const host = String(domain).toLowerCase();
  for (const row of rows) {
    if (host === row.domain || host.endsWith("." + row.domain)) return row.platform;
  }
  return "web";
}

/** The `{ platform, match(url) }` domains of ONE extractor module, as
 * `[{ domain, platform, origin }]`. Domains are read from inside the `match` body only —
 * rednote.js calls `hostIs` again in `toRednoteOriginal`, and a file-wide sweep would
 * have picked that up by luck rather than by rule. */
export function parseExtractorDomains(filename, source) {
  const platforms = [...source.matchAll(/platform\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
  const distinct = [...new Set(platforms)];
  if (distinct.length !== 1) {
    throw new Error(`${filename}: expected one platform string, found [${distinct.join(", ")}]`);
  }
  const head = source.match(/\bmatch\s*\([^)]*\)\s*\{/);
  if (!head) throw new Error(`${filename}: no match(url) body found`);
  const open = source.indexOf("{", head.index + head[0].length - 1);
  const body = balancedSlice(source, open, "{", "}");
  if (body == null) throw new Error(`${filename}: match(url) body is unbalanced`);
  const domains = [...body.matchAll(/hostIs\s*\([^,]*,\s*"([^"]+)"\s*\)/g)].map((m) => m[1]);
  if (domains.length === 0) throw new Error(`${filename}: match(url) names no hostIs domain`);
  return domains.map((domain) => ({
    domain: domain.toLowerCase(), platform: distinct[0], origin: `extractors/${filename}`,
  }));
}

/**
 * The per-platform CDN domains of `media-hosts.js`'s `ALLOWED`, as
 * `[{ domain, platform, origin }]`.
 *
 * These are on the JS side too, which is what makes the invariant clean: the CDN hosts
 * the Swift table carries deliberately ("an image shared out of a browser carries the
 * media URL, not the page URL") are not Swift-only at all, so they need no exclusion.
 */
export function parseMediaHostDomains(source) {
  const anchor = source.indexOf("const ALLOWED");
  if (anchor < 0) throw new Error("ALLOWED map not found in media-hosts.js");
  const open = source.indexOf("{", anchor);
  const body = open < 0 ? null : balancedSlice(source, open, "{", "}");
  if (body == null) throw new Error("ALLOWED map is unbalanced or empty");
  // Line-walked rather than regexed whole: a key opens a platform and every domain up to
  // the next key belongs to it, so a predicate that grows onto a second line still lands
  // under the right platform.
  const rows = [];
  const seen = new Map();
  let platform = null;
  for (const line of body.split("\n")) {
    const key = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/);
    if (key) platform = key[1];
    if (!platform) continue;
    for (const match of line.matchAll(/hostIs\s*\([^,]*,\s*"([^"]+)"\s*\)/g)) {
      rows.push({ domain: match[1].toLowerCase(), platform, origin: "media-hosts.js" });
      seen.set(platform, (seen.get(platform) || 0) + 1);
    }
  }
  for (const key of body.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/gm)) {
    if (!seen.has(key[1])) throw new Error(`ALLOWED.${key[1]} yielded no host (predicate shape moved?)`);
  }
  return rows;
}

/**
 * The check. `sources` is `{ swift, mediaHosts, extractors: [{ filename, source }] }` —
 * every file already read, so this stays pure and unit-testable and the CLI keeps the
 * I/O, the same split `drift.js` / `scripts/drift-check.js` already use.
 *
 * `floors` is injectable so a unit test can build a two-row synthetic table and assert on
 * the INVARIANT alone, without the liveness floors drowning the verdict. Nothing but a
 * test ever passes it; the CLI takes the real ones.
 */
export function checkHostTableAgreement(sources, { floors = FLOORS } = {}) {
  const problems = [];
  let swiftRows = [];
  try {
    swiftRows = parseSwiftHostPlatforms(sources.swift);
  } catch (error) {
    return verdict([`Swift side: ${error.message}`], { swiftRows: 0 });
  }

  const jsRows = [];
  const extractorFiles = sources.extractors.filter((f) => !NOT_EXTRACTORS.has(f.filename));
  for (const file of extractorFiles) {
    try {
      jsRows.push(...parseExtractorDomains(file.filename, file.source));
    } catch (error) {
      problems.push(`JS side: ${error.message}`);
    }
  }
  const extractorDomains = jsRows.length;
  try {
    jsRows.push(...parseMediaHostDomains(sources.mediaHosts));
  } catch (error) {
    problems.push(`JS side: ${error.message}`);
  }
  const cdnDomains = jsRows.length - extractorDomains;

  // Liveness before agreement. A parser that matched nothing agrees with everything, so
  // the floors are checked FIRST and reported as drift in their own right.
  if (swiftRows.length < floors.swiftRows) {
    problems.push(`only ${swiftRows.length} rows parsed from hostPlatforms`
      + ` (expected >= ${floors.swiftRows} — did the table's shape change?)`);
  }
  if (extractorFiles.length < floors.extractorFiles) {
    problems.push(`only ${extractorFiles.length} extractor modules found in src/extractors/`
      + ` (expected >= ${floors.extractorFiles})`);
  }
  if (extractorDomains < floors.extractorDomains) {
    problems.push(`only ${extractorDomains} domains parsed from the extractors`
      + ` (expected >= ${floors.extractorDomains} — did match(url) change shape?)`);
  }
  if (cdnDomains < floors.cdnDomains) {
    problems.push(`only ${cdnDomains} CDN domains parsed from media-hosts.js`
      + ` (expected >= ${floors.cdnDomains} — did ALLOWED change shape?)`);
  }

  // The invariant itself.
  for (const row of jsRows) {
    const swiftSays = swiftPlatformFor(swiftRows, row.domain);
    if (swiftSays === row.platform) continue;
    if (swiftSays === "web") {
      problems.push(`${row.domain} is ${row.platform} in ${row.origin} but MISSING from the`
        + ` Swift table — the phone would file it as .web (add it to`
        + ` ShareCapture.hostPlatforms)`);
    } else {
      problems.push(`${row.domain} is ${row.platform} in ${row.origin} but .${swiftSays}`
        + ` in the Swift table — the two producers disagree`);
    }
  }

  // Reported, never failed: see the asymmetry note at the top of this file.
  const claimed = new Set(jsRows.map((row) => row.domain));
  const swiftOnly = swiftRows.filter((row) => !claimed.has(row.domain)).map((row) => row.domain);

  return {
    ...verdict(problems, {
      swiftRows: swiftRows.length,
      jsDomains: jsRows.length,
      extractors: extractorFiles.length,
      cdnHosts: cdnDomains,
      swiftOnly: swiftOnly.length,
    }),
    swiftOnly,
  };
}
