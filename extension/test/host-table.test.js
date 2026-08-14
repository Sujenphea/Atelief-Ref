// Atelier Capture — producer host-table agreement tests (review issue 4).
//
// Two things are pinned here, and the second is the one that matters. The invariant
// itself is exercised over synthetic sources, so every verdict — agreement, a missing
// domain, a contradiction, the permitted asymmetry — is asserted without waiting for a
// real divergence. And the PARSERS are run against the actual repo files, because a
// regex that silently stops matching passes forever: a check whose parser returned an
// empty list would agree with everything, cheerfully, until someone shipped duplicates.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  parseSwiftHostPlatforms, parseExtractorDomains, parseMediaHostDomains,
  swiftPlatformFor, checkHostTableAgreement,
} from "../src/host-table.js";

const here = (rel) => fileURLToPath(new URL(rel, import.meta.url));
const read = (rel) => readFileSync(here(rel), "utf8");

const SWIFT = read("../../AtelierCapture/Sources/AtelierCapture/ShareCapture.swift");
const MEDIA_HOSTS = read("../src/media-hosts.js");
const EXTRACTORS = readdirSync(here("../src/extractors"))
  .filter((filename) => filename.endsWith(".js")).sort()
  .map((filename) => ({ filename, source: read(`../src/extractors/${filename}`) }));

/** A minimal stand-in for the real sources, so a case can be built by changing one row. */
function sources({ swiftRows, extractorDomains = ["x.com"], cdn = ["twimg.com"] } = {}) {
  const rows = swiftRows.map(([d, p]) => `        ("${d}", .${p}),`).join("\n");
  return {
    swift: `    static let hostPlatforms: [(domain: String, platform: Platform)] = [\n${rows}\n    ]\n`,
    mediaHosts: `const ALLOWED = {\n  twitter: (host) => `
      + cdn.map((d) => `hostIs(host, "${d}")`).join(" || ") + `,\n};\n`,
    extractors: [{
      filename: "twitter.js",
      source: `export const twitter = {\n  platform: "twitter",\n  match(url) {\n    return `
        + extractorDomains.map((d) => `hostIs(host, "${d}")`).join(" || ") + `;\n  },\n};\n`,
    }],
  };
}

// The liveness floors would otherwise dominate every synthetic case (a two-row table
// trips all four), so they are stood down where the assertion is about the INVARIANT.
// They get their own test below, and the real sources are checked with the real floors.
const NO_FLOORS = { floors: { swiftRows: 0, extractorDomains: 0, cdnDomains: 0, extractorFiles: 0 } };

test("the real repo sources agree — the invariant holds today", () => {
  const result = checkHostTableAgreement({
    swift: SWIFT, mediaHosts: MEDIA_HOSTS, extractors: EXTRACTORS,
  });
  assert.deepEqual(result.problems, []);
  assert.equal(result.ok, true);
});

test("the parsers are alive against the real files (a dead regex agrees with everything)", () => {
  const rows = parseSwiftHostPlatforms(SWIFT);
  assert.ok(rows.length >= 15, `parsed ${rows.length} Swift rows`);
  // Spot-checked against the table as written, so a rewrite that parses to plausible
  // nonsense is caught as well as one that parses to nothing.
  assert.deepEqual(rows.find((row) => row.domain === "x.com"), { domain: "x.com", platform: "twitter" });
  assert.deepEqual(rows.find((row) => row.domain === "fbcdn.net"),
    { domain: "fbcdn.net", platform: "instagram" });

  const cdn = parseMediaHostDomains(MEDIA_HOSTS);
  assert.equal(cdn.length, 5);
  assert.deepEqual(cdn.filter((row) => row.platform === "instagram").map((row) => row.domain),
    ["cdninstagram.com", "fbcdn.net"]);

  const modules = EXTRACTORS.filter((f) => !["base.js", "registry.js"].includes(f.filename));
  assert.equal(modules.length, 5);
  for (const file of modules) {
    const parsed = parseExtractorDomains(file.filename, file.source);
    assert.ok(parsed.length >= 1, `${file.filename} yielded no domain`);
  }
  // rednote.js calls hostIs a THIRD time outside match(), in toRednoteOriginal. Reading
  // only the match body is what keeps that out.
  const rednote = parseExtractorDomains("rednote.js",
    EXTRACTORS.find((f) => f.filename === "rednote.js").source);
  assert.deepEqual(rednote.map((row) => row.domain), ["rednote.com", "xiaohongshu.com"]);
});

test("swiftPlatformFor mirrors Swift's hostIs — apex, subdomain, and no suffix spoof", () => {
  const rows = parseSwiftHostPlatforms(SWIFT);
  assert.equal(swiftPlatformFor(rows, "x.com"), "twitter");
  assert.equal(swiftPlatformFor(rows, "mobile.twitter.com"), "twitter");
  assert.equal(swiftPlatformFor(rows, "abs.twimg.com"), "twitter");
  assert.equal(swiftPlatformFor(rows, "evilx.com"), "web");
  assert.equal(swiftPlatformFor(rows, "twimg.com.evil.com"), "web");
  assert.equal(swiftPlatformFor(rows, "example.org"), "web");
});

test("a domain a JS extractor knows and Swift does not is DRIFT, and is named", () => {
  const result = checkHostTableAgreement(sources({
    swiftRows: [["x.com", "twitter"], ["twimg.com", "twitter"]],
    extractorDomains: ["x.com", "twitter.com"],
  }), NO_FLOORS);
  assert.equal(result.ok, false);
  assert.equal(result.problems.length, 1);
  assert.match(result.problems[0], /^twitter\.com is twitter in extractors\/twitter\.js but MISSING/);
  assert.match(result.problems[0], /file it as \.web/);
});

test("the same domain naming different platforms on the two sides is DRIFT", () => {
  const result = checkHostTableAgreement(sources({
    swiftRows: [["x.com", "pinterest"], ["twimg.com", "twitter"]],
  }), NO_FLOORS);
  assert.equal(result.ok, false);
  assert.equal(result.problems.length, 1);
  assert.match(result.problems[0], /x\.com is twitter in extractors\/twitter\.js but \.pinterest/);
});

test("a CDN host missing from Swift is DRIFT too (media-hosts.js is part of the JS side)", () => {
  const result = checkHostTableAgreement(sources({
    swiftRows: [["x.com", "twitter"]],
    cdn: ["twimg.com"],
  }), NO_FLOORS);
  assert.equal(result.ok, false);
  assert.match(result.problems[0], /^twimg\.com is twitter in media-hosts\.js but MISSING/);
});

test("a JS domain that is a SUBDOMAIN of a Swift row is not drift", () => {
  // Swift matches with hostIs, so a `twimg.com` row already resolves abs.twimg.com to
  // .twitter. Set equality would have called this a difference and cried wolf.
  const result = checkHostTableAgreement(sources({
    swiftRows: [["x.com", "twitter"], ["twimg.com", "twitter"]],
    extractorDomains: ["x.com"],
    cdn: ["abs.twimg.com"],
  }), NO_FLOORS);
  assert.deepEqual(result.problems, []);
});

test("a Swift-only domain passes, and is reported rather than absorbed", () => {
  const result = checkHostTableAgreement(sources({
    swiftRows: [["x.com", "twitter"], ["t.co", "twitter"], ["twimg.com", "twitter"]],
  }), NO_FLOORS);
  assert.equal(result.ok, true);
  assert.ok(result.swiftOnly.includes("t.co"));
  assert.equal(result.signals.swiftOnly, result.swiftOnly.length);
});

test("a parser that finds nothing FAILS instead of agreeing with everything", () => {
  const empty = { swift: "// no table here", mediaHosts: "// no ALLOWED", extractors: [] };
  const gone = checkHostTableAgreement(empty);
  assert.equal(gone.ok, false);
  assert.match(gone.problems[0], /hostPlatforms table not found/);

  // A Swift table that still parses, with everything else hollowed out: the floors have
  // to fire on their own, since there is nothing left to disagree with.
  const hollow = checkHostTableAgreement({
    swift: SWIFT, mediaHosts: "const ALLOWED = {\n};\n", extractors: [],
  });
  assert.equal(hollow.ok, false);
  assert.ok(hollow.problems.some((p) => /extractor modules found/.test(p)));
  assert.ok(hollow.problems.some((p) => /domains parsed from the extractors/.test(p)));
  assert.ok(hollow.problems.some((p) => /CDN domains parsed from media-hosts/.test(p)));
});

test("an extractor whose match(url) cannot be read is DRIFT, not a silent skip", () => {
  const broken = checkHostTableAgreement({
    swift: SWIFT, mediaHosts: MEDIA_HOSTS,
    extractors: [...EXTRACTORS, {
      filename: "newsite.js",
      source: `export const newsite = { platform: "newsite", match(url) { return true; } };`,
    }],
  });
  assert.equal(broken.ok, false);
  assert.match(broken.problems[0], /newsite\.js: match\(url\) names no hostIs domain/);
});

test("an ALLOWED entry that yields no host is DRIFT (the predicate shape moved)", () => {
  assert.throws(
    () => parseMediaHostDomains(`const ALLOWED = {\n  twitter: (host) => isTwimg(host),\n};\n`),
    /ALLOWED\.twitter yielded no host/);
});
