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
import { sweepLabel } from "../src/popup-view.js";

const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));

/** One representative page host + media CDN host per platform. Kept HERE rather than
 * imported so the test states an independent expectation instead of echoing the code. */
const PLATFORMS = {
  twitter:   { page: "x.com",              media: "https://pbs.twimg.com/media/a.jpg",     drift: "x" },
  pinterest: { page: "www.pinterest.com",  media: "https://i.pinimg.com/originals/a.jpg",  drift: "pinterest-board" },
  instagram: { page: "www.instagram.com",  media: "https://scontent.cdninstagram.com/a.jpg", drift: "instagram" },
  rednote:   { page: "www.rednote.com",    media: "http://sns-i27.rednotecdn.com/key",     drift: "rednote" },
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
