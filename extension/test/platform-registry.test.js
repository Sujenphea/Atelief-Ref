// Atelier Capture — every sweep platform is registered EVERYWHERE (098 R4/T4).
//
// Adding a sweep platform touches nine unconnected places. None of them fail at build
// time, and the failure modes are all silent:
//   · miss the manifest content_script → the MAIN-world hook never installs, the sweep
//     sees no responses, and the popup reports a stall
//   · miss the media-hosts predicate  → every byte fetch is refused as a blocked host
//   · miss the drift check            → the parser rots until a live sweep breaks
//   · miss the popup label            → the button offers a generic string
//
// This is deliberately a CONSISTENCY TEST and not an abstraction. The four platforms are
// genuinely dissimilar — Instagram needs no hook at all, Pinterest needs no MAIN world, X
// needs a request proxy — so a descriptor registry would force four shapes into one to buy
// what one test file buys for free. The test IS the registry documentation.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { SUPPORTED_PLATFORMS } from "../src/bulk-controller.js";
import { platformForHost, REASON_MESSAGE, resolveSweepSpec } from "../src/bulk-context.js";
import { isAllowedMediaHost } from "../src/media-hosts.js";
import { CHECKS } from "../src/drift.js";
import { PLATFORM_PACING } from "../src/config.js";
import { sweepLabel, expansionOption } from "../src/popup-view.js";

const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));

/** One representative page host + media CDN host per platform, plus one real page URL that
 * MUST start a sweep (Pinterest additionally needs the board's "Collage" href, which the
 * popup reads from the DOM). Kept HERE rather than imported so the test states an
 * independent expectation instead of echoing the code. */
const PLATFORMS = {
  twitter:   { page: "x.com",              media: "https://pbs.twimg.com/media/a.jpg",     drift: "x",
               sweep: { url: "https://x.com/i/bookmarks" } },
  pinterest: { page: "www.pinterest.com",  media: "https://i.pinimg.com/originals/a.jpg",  drift: "pinterest-board",
               sweep: { url: "https://www.pinterest.com/sujen/design-refs/",
                        collageHref: "/collage-creation-tool/?boardId=1084663960195879466" } },
  instagram: { page: "www.instagram.com",  media: "https://scontent.cdninstagram.com/a.jpg", drift: "instagram",
               sweep: { url: "https://www.instagram.com/lychee.web/saved/" } },
  rednote:   { page: "www.rednote.com",    media: "http://sns-i27.rednotecdn.com/key",     drift: "rednote",
               sweep: { url: "https://www.rednote.com/board/69322476000000001202811f?source=web_user_page" } },
};

/** Does any manifest content_scripts entry running `file` cover `host`? */
function contentScriptCovers(file, host) {
  return manifest.content_scripts.some((entry) =>
    entry.js.includes(file) && entry.matches.some((pattern) => matchesHost(pattern, host)));
}

/** A crude `*://*.domain/*` matcher — enough for the exact hosts named above. */
function matchesHost(pattern, host) {
  const match = /^\*:\/\/(\*\.)?([^/]+)\/\*$/.exec(pattern);
  if (!match) return false;
  const domain = match[2];
  return host === domain || host.endsWith(`.${domain}`);
}

test("the controller's supported set is derived, not a second hand-maintained list", () => {
  // 098 R6: SUPPORTED_PLATFORMS comes from the builder map's keys, so a platform can never
  // be accepted by the guard while having nothing to dispatch it to.
  assert.deepEqual([...SUPPORTED_PLATFORMS].sort(), Object.keys(PLATFORMS).sort());
});

for (const [platform, fixture] of Object.entries(PLATFORMS)) {
  test(`${platform}: registered in every place a sweep needs it`, () => {
    assert.ok(SUPPORTED_PLATFORMS.has(platform), "bulk-controller DRIVER_BUILDERS");
    assert.equal(platformForHost(fixture.page), platform, "bulk-context platformForHost");
    // Recognising the HOST is half the resolver's job; the other half is accepting a PAGE,
    // and it fails just as silently — the popup renders its guidance string on the very
    // board it was written for and no sweep can start. "Every refusal has a message" below
    // does not cover it: a platform that refuses EVERYTHING passes that test perfectly. So
    // each platform names one real page that must resolve.
    assert.equal(new URL(fixture.sweep.url).hostname, fixture.page,
      "the sweep URL must be on the host registered above");
    const resolved = resolveSweepSpec(fixture.sweep);
    assert.equal(resolved.ok, true,
      `bulk-context resolveSweepSpec refused ${fixture.sweep.url} (${resolved.reason})`);
    assert.equal(resolved.spec.platform, platform, "the spec must name this platform");
    assert.ok(resolved.spec.scope && resolved.spec.scope.length > 0,
      "a spec with no scope cannot checkpoint or resume");
    assert.equal(isAllowedMediaHost(platform, fixture.media), true, "media-hosts ALLOWED");
    assert.ok(CHECKS[fixture.drift], `drift.CHECKS.${fixture.drift}`);
    assert.ok(
      contentScriptCovers("src/bulk-loader.js", fixture.page),
      "manifest: the ISOLATED bulk-loader must run on this host, or no sweep can start");
    assert.ok(
      manifest.web_accessible_resources.some((entry) =>
        entry.matches.some((pattern) => matchesHost(pattern, fixture.page))),
      "manifest: web_accessible_resources — bulk-loader dynamic-imports the controller");
  });
}

test("a platform with a MAIN-world hook has BOTH files, in the right order", () => {
  // hook-core publishes the installer the site hook reads off `window`; listed second, the
  // site hook ReferenceErrors into the page instead of installing.
  for (const entry of manifest.content_scripts) {
    const hook = entry.js.find((file) => /-hook\.js$/.test(file));
    if (!hook) continue;
    assert.equal(entry.world, "MAIN", `${hook} must run in the MAIN world`);
    assert.equal(entry.run_at, "document_start", `${hook} must run at document_start`);
    assert.equal(entry.js[0], "src/hook-core.js", `hook-core.js must precede ${hook}`);
  }
});

test("every platform the popup can resolve gets non-generic copy", () => {
  // A sweep the resolver accepts but the label does not know about would ship the
  // Pinterest fallback string on someone else's board.
  const specs = [
    { platform: "twitter", input: {}, scope: "bookmarks" },
    { platform: "instagram", input: {}, scope: "saved" },
    { platform: "pinterest", input: { boardId: "1" }, scope: "board:refs" },
    { platform: "rednote", input: { boardId: "abc" }, scope: "board:abc" },
  ];
  for (const spec of specs) {
    const label = sweepLabel(spec);
    assert.ok(label && label.length > 0, `${spec.platform} has no label`);
  }
  assert.match(sweepLabel(specs[3]), /rednote/i, "rednote's label names rednote");
});

test("every refusal reason the resolver can return has a message", () => {
  // The popup renders REASON_MESSAGE[reason] and silently falls back to the generic
  // string, so a missing entry is invisible until a user hits that exact page.
  const reasons = [
    resolveSweepSpec({ url: "https://example.com/" }),
    resolveSweepSpec({ url: "https://x.com/home" }),
    resolveSweepSpec({ url: "https://www.instagram.com/someone/" }),
    resolveSweepSpec({ url: "https://www.instagram.com/me/saved/slug/" }),
    resolveSweepSpec({ url: "https://www.pinterest.com/user/board/" }),
    resolveSweepSpec({ url: "https://www.pinterest.com/pin/1/" }),
    resolveSweepSpec({ url: "https://www.rednote.com/explore/abc" }),
    resolveSweepSpec({ url: "https://www.rednote.com/board/not-hex" }),
  ];
  for (const result of reasons) {
    assert.equal(result.ok, false);
    assert.ok(REASON_MESSAGE[result.reason], `no REASON_MESSAGE for "${result.reason}"`);
  }
});

test("a platform with per-platform pacing declares an engine block", () => {
  // An empty/absent entry is legitimate (X and Pinterest inherit the globals); a
  // half-written one is not.
  for (const [platform, pacing] of Object.entries(PLATFORM_PACING)) {
    assert.ok(SUPPORTED_PLATFORMS.has(platform), `pacing for unknown platform "${platform}"`);
    assert.ok(pacing.engine && typeof pacing.engine === "object", `${platform} pacing has no engine block`);
  }
});

test("a platform offering the expansion toggle declares the pacing that bounds it", () => {
  // 098 T5b adds a fifth unconnected place: a popup toggle, a pacing block, and the budget
  // the toggle promises. Offer the toggle without the pacing entry and the expansion runs
  // on the module defaults — no per-platform gap between note-opens against the one site
  // known to refuse a scripted request.
  for (const platform of SUPPORTED_PLATFORMS) {
    const option = expansionOption({ platform, scope: "s", input: {} });
    if (!option) continue;
    const pacing = PLATFORM_PACING[platform];
    assert.ok(pacing && pacing.noteOpen, `${platform} offers expansion with no PLATFORM_PACING.noteOpen`);
    for (const key of ["BUDGET", "PACING_MS", "PACING_JITTER_MS", "TIMEOUT_MS", "POLL_MS"]) {
      assert.equal(typeof pacing.noteOpen[key], "number", `${platform} noteOpen.${key}`);
    }
  }
});

test("every element popup.js reaches for exists in popup.html", () => {
  // popup.js is thin DOM glue with no unit test of its own, and a missing id does not fail
  // quietly: `els.expandRow.hidden = true` throws on null and the whole popup renders
  // nothing but "Checking this tab…". Adding a row means adding it in two files.
  const js = readFileSync(new URL("../src/popup.js", import.meta.url), "utf8");
  const html = readFileSync(new URL("../src/popup.html", import.meta.url), "utf8");
  const ids = [...js.matchAll(/getElementById\("([^"]+)"\)/g)].map((m) => m[1]);
  assert.ok(ids.length >= 10, "the id scan found nothing — the pattern moved");
  for (const id of ids) {
    assert.match(html, new RegExp(`id="${id}"`), `popup.html has no #${id}`);
  }
});
