// Atelier Capture — planCapture tests (096 § D7, T2.5).
//
// The decision half of a capture, pure: provenance in, a plan out. `sw.js` adds the
// localhost transport and the Safari worker will add the native one, so everything
// asserted here is asserted once for both producers.

import { test } from "node:test";
import assert from "node:assert/strict";

import { planCapture, isTextCard, CAPTURE_KIND } from "../src/capture-plan.js";
import { isAllowedMediaHost } from "../src/media-hosts.js";

const prov = (over = {}) => ({
  platform: "twitter",
  mediaUrl: "https://pbs.twimg.com/media/A?format=jpg&name=orig",
  mediaUrlFallback: null,
  ...over,
});

const CONTENT = { kind: "tweet", payload: { text: "hi" } };

// ---------------------------------------------------------------------------
// The four kinds
// ---------------------------------------------------------------------------

test("a plain image → kind image, one candidate", () => {
  const plan = planCapture(prov());
  assert.equal(plan.kind, CAPTURE_KIND.image);
  assert.deepEqual(plan.urlCandidates, ["https://pbs.twimg.com/media/A?format=jpg&name=orig"]);
  assert.equal(plan.videoUrl, null);
  assert.equal(plan.content, null);
  assert.equal(isTextCard(plan), false);
});

test("candidate order is full-res first, rendered fallback second", () => {
  const plan = planCapture(prov({ mediaUrl: "FULL", mediaUrlFallback: "RENDERED" }));
  assert.deepEqual(plan.urlCandidates, ["FULL", "RENDERED"]);
});

test("a content descriptor WITH media → kind content, candidates intact", () => {
  const plan = planCapture(prov(), { content: CONTENT });
  assert.equal(plan.kind, CAPTURE_KIND.content);
  assert.equal(plan.urlCandidates.length, 1);
  assert.equal(isTextCard(plan), false, "it has a card image, so it is not a text card");
});

test("a content descriptor with NO media → the text-card case", () => {
  const plan = planCapture(prov({ mediaUrl: null }), { content: CONTENT });
  assert.equal(plan.kind, CAPTURE_KIND.content);
  assert.deepEqual(plan.urlCandidates, []);
  assert.equal(isTextCard(plan), true);
});

test("neither media nor content → none, with a reason", () => {
  const plan = planCapture(prov({ mediaUrl: null }));
  assert.equal(plan.kind, CAPTURE_KIND.none);
  assert.equal(plan.reason, "no-media");
  assert.equal(isTextCard(plan), false);
});

// ---------------------------------------------------------------------------
// Video, and the fallback it carries with it
// ---------------------------------------------------------------------------

test("a resolved video wins, and keeps the still candidates as its fallback", () => {
  // sw.js:232 falls back to the image when a resolved video fails to ingest. The plan has
  // to carry what that fallback is, or the caller re-derives it — which is the duplication
  // this module exists to remove.
  const plan = planCapture(prov({ mediaUrlFallback: "POSTER" }), { mp4Url: "https://video/x.mp4" });
  assert.equal(plan.kind, CAPTURE_KIND.video);
  assert.equal(plan.videoUrl, "https://video/x.mp4");
  assert.deepEqual(plan.urlCandidates, ["https://pbs.twimg.com/media/A?format=jpg&name=orig", "POSTER"]);
});

test("a video on a post with NO still is still a video plan", () => {
  const plan = planCapture(prov({ mediaUrl: null }), { mp4Url: "https://video/x.mp4" });
  assert.equal(plan.kind, CAPTURE_KIND.video);
  assert.deepEqual(plan.urlCandidates, []);
});

test("a video alongside content keeps the content for the fallback path", () => {
  const plan = planCapture(prov(), { mp4Url: "https://video/x.mp4", content: CONTENT });
  assert.equal(plan.kind, CAPTURE_KIND.video);
  assert.equal(plan.content, CONTENT);
});

// ---------------------------------------------------------------------------
// The ordered video ladder (098 D5 / T6c)
// ---------------------------------------------------------------------------

test("a single resolved video still plans as ONE candidate — the other three platforms", () => {
  // The behaviour-identity claim, stated as a property rather than trusted: X, Instagram and
  // Pinterest resolve exactly one url and pass no ladder, so their plan's list has one
  // element and its head is the url they resolved. A caller that walks the list does
  // precisely what a caller that tried `videoUrl` did.
  const plan = planCapture(prov(), { mp4Url: "https://video/x.mp4" });
  assert.deepEqual(plan.videoCandidates, ["https://video/x.mp4"]);
  assert.equal(plan.videoUrl, plan.videoCandidates[0]);
});

test("a ladder rides behind mp4Url, in the order it was given", () => {
  const plan = planCapture(prov({ platform: "rednote" }), {
    mp4Url: "https://v/master.mp4",
    videoCandidates: ["https://v/master.mp4", "https://v/backup.mp4", "https://v/rung2.mp4"],
  });
  assert.equal(plan.kind, CAPTURE_KIND.video);
  // Deduped, and the duplicate here is the REAL one: a caller that both resolved a url and
  // handed over the ladder it came from would otherwise buy the rung-advance a second try
  // against a url that had just failed.
  assert.deepEqual(plan.videoCandidates,
    ["https://v/master.mp4", "https://v/backup.mp4", "https://v/rung2.mp4"]);
  assert.equal(new Set(plan.videoCandidates).size, plan.videoCandidates.length);
  assert.equal(plan.videoUrl, "https://v/master.mp4");

  // …and a resolved url that is NOT in the ladder still LEADS it. A caller that resolved one
  // url said which one it wanted tried first; appending it would make the ladder outrank the
  // answer the caller already had.
  const distinct = planCapture(prov(), {
    mp4Url: "https://v/resolved.mp4", videoCandidates: ["https://v/a.mp4", "https://v/b.mp4"],
  });
  assert.deepEqual(distinct.videoCandidates,
    ["https://v/resolved.mp4", "https://v/a.mp4", "https://v/b.mp4"]);
});

test("a ladder with NO mp4Url is still a video plan, headed by its first rung", () => {
  // rednote's shape: nothing resolves a single url, the whole ladder arrives at once.
  const plan = planCapture(prov({ platform: "rednote", mediaUrl: null }), {
    videoCandidates: ["https://v/a.mp4", "https://v/b.mp4"],
  });
  assert.equal(plan.kind, CAPTURE_KIND.video);
  assert.equal(plan.videoUrl, "https://v/a.mp4");
  assert.deepEqual(plan.urlCandidates, [], "a stream item carries no still — the cover is a separate item");
});

test("an EMPTY ladder is not a video plan", () => {
  // The refused-ladder case (`ef*`-only, empty buckets). It must fall through to the still
  // candidates, not become a video plan with nothing to fetch.
  const plan = planCapture(prov(), { videoCandidates: [] });
  assert.equal(plan.kind, CAPTURE_KIND.image);
  assert.deepEqual(plan.videoCandidates, []);
  const nothing = planCapture(prov({ mediaUrl: null }), { videoCandidates: [] });
  assert.equal(nothing.kind, CAPTURE_KIND.none);
  assert.equal(nothing.reason, "no-media");
});

test("non-string ladder entries are dropped rather than planned", () => {
  const plan = planCapture(prov(), { videoCandidates: [null, "", 7, "https://v/ok.mp4"] });
  assert.deepEqual(plan.videoCandidates, ["https://v/ok.mp4"]);
});

// ---------------------------------------------------------------------------
// The media-host guard (096 § D6) — opt-in, and why
// ---------------------------------------------------------------------------

test("no guard by default: the desktop's behaviour is unchanged", () => {
  // media-hosts.js's ALLOWED is deny-by-default and names four platforms. Enforcing it
  // unconditionally would refuse every cosmos and web capture, which is why null means
  // no enforcement rather than "deny everything".
  const plan = planCapture({ platform: "web", mediaUrl: "https://example.com/a.jpg", mediaUrlFallback: null });
  assert.deepEqual(plan.urlCandidates, ["https://example.com/a.jpg"]);
  assert.deepEqual(plan.blocked, []);
});

test("with the real guard, an off-CDN URL is blocked and kept for diagnosis", () => {
  const plan = planCapture(
    prov({ mediaUrl: "https://evil.example/x.jpg", mediaUrlFallback: "https://pbs.twimg.com/media/OK" }),
    { isAllowedHost: isAllowedMediaHost },
  );
  assert.deepEqual(plan.urlCandidates, ["https://pbs.twimg.com/media/OK"]);
  assert.deepEqual(plan.blocked, ["https://evil.example/x.jpg"]);
  assert.equal(plan.kind, CAPTURE_KIND.image);
});

test("the guard is applied per platform, not per host list", () => {
  const pin = planCapture(
    { platform: "pinterest", mediaUrl: "https://pbs.twimg.com/media/A", mediaUrlFallback: null },
    { isAllowedHost: isAllowedMediaHost },
  );
  assert.deepEqual(pin.urlCandidates, [], "a twitter CDN is not a pinterest CDN");
  assert.equal(pin.reason, "blocked-host");
});

test("every candidate blocked with no content → none, distinguished from no-media", () => {
  const plan = planCapture(
    prov({ mediaUrl: "https://evil.example/x.jpg" }),
    { isAllowedHost: isAllowedMediaHost },
  );
  assert.equal(plan.kind, CAPTURE_KIND.none);
  assert.equal(plan.reason, "blocked-host",
    "a refusal must not look like a post that simply had no media");
  assert.deepEqual(plan.blocked, ["https://evil.example/x.jpg"]);
});

test("every candidate blocked WITH content → the text-card path still works", () => {
  const plan = planCapture(
    prov({ mediaUrl: "https://evil.example/x.jpg" }),
    { isAllowedHost: isAllowedMediaHost, content: CONTENT },
  );
  assert.equal(isTextCard(plan), true);
  assert.deepEqual(plan.blocked, ["https://evil.example/x.jpg"]);
});

test("a suffix-spoof CDN host is blocked (the guard's own rule, threaded through)", () => {
  const plan = planCapture(
    prov({ mediaUrl: "https://pbs.twimg.com.evil.com/media/A" }),
    { isAllowedHost: isAllowedMediaHost },
  );
  assert.equal(plan.kind, CAPTURE_KIND.none);
  assert.equal(plan.reason, "blocked-host");
});

// ---------------------------------------------------------------------------
// Shape guarantees the two transports both rely on
// ---------------------------------------------------------------------------

test("the plan shape is total — every field present on every kind", () => {
  const plans = [
    planCapture(prov()),
    planCapture(prov(), { mp4Url: "V" }),
    planCapture(prov({ mediaUrl: null }), { content: CONTENT }),
    planCapture(prov({ mediaUrl: null })),
  ];
  for (const plan of plans) {
    for (const key of ["kind", "videoUrl", "videoCandidates", "urlCandidates", "content", "blocked", "reason"]) {
      assert.ok(key in plan, `${plan.kind} plan is missing ${key}`);
    }
    assert.ok(Array.isArray(plan.urlCandidates));
    assert.ok(Array.isArray(plan.blocked));
    // ALWAYS an array — `ingestOne` slices it unconditionally, so "no video" and "an empty
    // ladder" have to be the same shape rather than two the caller must tell apart.
    assert.ok(Array.isArray(plan.videoCandidates));
    assert.equal(plan.videoUrl, plan.videoCandidates[0] ?? null,
      "videoUrl must always be the head of the list, or there are two answers to one question");
  }
});

test("reason is null unless the kind is none", () => {
  assert.equal(planCapture(prov()).reason, null);
  assert.equal(planCapture(prov(), { mp4Url: "V" }).reason, null);
  assert.equal(planCapture(prov({ mediaUrl: null }), { content: CONTENT }).reason, null);
  assert.equal(planCapture(prov({ mediaUrl: null })).reason, "no-media");
});

test("planCapture does not mutate the provenance it is given", () => {
  const p = prov({ mediaUrlFallback: "B" });
  const snapshot = JSON.stringify(p);
  planCapture(p, {
    mp4Url: "V", content: CONTENT, isAllowedHost: isAllowedMediaHost,
    videoCandidates: ["V", "W"],
  });
  assert.equal(JSON.stringify(p), snapshot);
});
