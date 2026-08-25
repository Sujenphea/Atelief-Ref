# 436 — the decision without the transport

[096](../.docs/096-tier3-plan.md) § D7 / T2.5: the capture decision extracted from the
localhost transport it was fused to, so tier 3 can reuse the first without inheriting the
second.

## Why

`captureCore` and `ingestOne` held two things in one place. Decisions any producer needs:

- video or still (`sw.js:227`), with fail-open fallback to the image when a resolved video
  fails to ingest;
- which URL is tried first and which is the fallback (`sw.js:250`);
- whether a post with substance but no image captures as a text card (`sw.js:244`).

And decisions only the desktop can make: base64 the bytes (`sw.js:99`), POST to
`127.0.0.1` (`sw.js:160`), carry the shared-secret token. 095 § 5 measured the native
handler killed at 32 MB when bytes travel through a message, so tier 3 hands over a URL and
the native side fetches — it needs the first list and must not inherit the second.

Ported as-is that splits "which URL wins, is this a text card, is there a video" across two
producers, which is the duplication [404](404-the-mirror-nobody-checked.md) is the changelog
of and the one 435 just finished closing for permalinks.

## What landed

`extension/src/capture-plan.js` — `planCapture(provenance, { mp4Url, content, isAllowedHost })`
returning `{ kind, videoUrl, urlCandidates, content, blocked, reason }`. Pure: no browser
API, no fetch, no bytes. Plus `isTextCard(plan)`, named because both transports branch on it
and `kind === "content" && !urlCandidates.length` is the sort of condition that gets subtly
mis-copied the second time it is written.

`sw.js` now consumes it and keeps only the transport. The 40 existing `sw.test.js` cases
pass unchanged, which is the point — this is a refactor, not a behaviour change.

**Two deviations from 096 § D7's sketch, both deliberate:**

1. **The plan does not carry the request body.** § D7 wrote
   `→ { kind, urlCandidates, request }`, but a `CaptureRequest` carries base64 image bytes,
   so building one inside the shared half would drag the exact thing tier 3 must avoid back
   in. Request construction stays in `endpoint.js`, called by whichever transport needs it.
2. **`planCapture` is imported, not injected through `deps`.** `defaultDeps` (`sw.js:148`)
   exists for things that touch the network or the browser and need faking; a pure function
   needs neither. Injecting it would also have meant editing every test that overrides
   `deps` wholesale, to no benefit.

## The media-host guard is opt-in, and that is not laziness

096 § D6 has `isAllowedMediaHost` running inside `planCapture`. It does — but only when the
caller passes it, and the default is no enforcement.

`media-hosts.js`'s `ALLOWED` is deny-by-default and names four platforms: twitter,
pinterest, instagram, rednote. It has no entry for `cosmos` or `web`, so an unconditional
guard would refuse **every cosmos and web capture** the desktop makes today. Tier 3 passes
the guard because it only ever runs on the three platforms that table covers.

`blocked` carries the refused URLs rather than dropping them, and `reason` distinguishes
`blocked-host` from `no-media`, so a refusal is diagnosable instead of looking like a post
that simply had no picture.

## Files changed

- `extension/src/capture-plan.js` — new.
- `extension/src/sw.js` — `ingestOne` consumes the plan; the video, text-card and candidate
  branches now read off it.
- `extension/test/capture-plan.test.js` — new, 17 cases: the four kinds, candidate ordering,
  video carrying its still fallback, the guard blocking per platform, a suffix spoof, a
  blocked-everything post with and without content, plan-shape totality, `reason` nullity,
  and non-mutation of the input.

Full suite: 601 pass, 1 skip. `drift-check` clean.

## Migration notes

None — behaviour is unchanged on the desktop, and `sw.test.js` passing untouched is the
evidence.

**What this unblocks and what it does not.** The Safari worker (096 § T2.5's other half —
`extension/src/safari/worker.js`, `popup.js`, `capture-view.js`) is deliberately NOT here:
it has nothing to talk to until T1's target and T2's native handler exist. What is here is
the part that needed doing first and could be done without a device, and it is the piece
every later row depends on.

T0 remains the gate, and remains device-bound: the Xcode wrapper around
`manifest.probe.json`, 30 observations per platform, and the still-unread `zero=`/`medH=`
geometry question from 433.
