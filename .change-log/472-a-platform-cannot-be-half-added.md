# 472 — a platform cannot be half-added

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T3 — rednote is wired as the fourth sweep
platform: a MAIN-world hook, a push→pull source, the popup's resolver/label/warning,
pacing, the manifest, and the controller dispatch.

Two of the review's structural decisions landed with it, and one of them immediately
paid for itself.

## The dispatch is a map, and the guard is derived from it

`bulk-controller.js` chose its driver with an if/else chain ending in a bare `else`
that fell through to **Pinterest**. Correctness therefore depended on two separate
lists agreeing — `SUPPORTED_PLATFORMS` and the chain — and a platform added to the
guard but not the chain would silently run the Pinterest driver on someone else's
site, which is the exact failure the guard was written to prevent.

`DRIVER_BUILDERS` is now a map and `SUPPORTED_PLATFORMS` is `Object.keys` of it.
One list, no default branch. Each builder still takes the whole context and
destructures what it needs, because they genuinely need different things (a
document, a location, a window, a transport) and one signature would be a worse
trade than one shared bag.

## Eight "KEEP IN SYNC" comments became a test

A MAIN-world hook is a classic script and cannot `import`, so its message tags are
retyped from `bulk-messages.js` and its matcher from the parser. Nothing enforced
any of it, and rednote doubled the duplication. `hook-sync.test.js` now evaluates
each hook the way Chrome injects it — `new Function`, the technique
`hook-core.test.js` already used — and compares its constants against the real
exports, url for url.

## The registry test caught rednote mid-add

`platform-registry.test.js` (098 R4) asserts every supported platform has a
`platformForHost` branch, a media-host predicate, a drift check, popup copy, a
manifest content-script entry and web-accessible-resources coverage — plus that any
MAIN-world hook is paired with `hook-core.js` FIRST, in the MAIN world, at
`document_start`.

It failed on first run: rednote had no `drift.CHECKS` entry. That is precisely the
class of silent rot the test exists to prevent (a parser rots until a live sweep
breaks), so `checkRednoteBoard` was pulled forward from T4 rather than the
assertion being relaxed. The check verifies the terminator and the loop guard
against synthesized pages, so those hold whatever capture is fed in.

rednote has no committed fixture yet, so `drift-check` reports it honestly:

```
⊘ rednote board feed — NEVER VERIFIED against a real response
```

using the `CAPTURE_HINT` mechanism that had been sitting unused for exactly this.

## rednote specifics

- **No proxy, no header allowlist.** hook-core's request proxy replays stored
  headers onto a different url — sound for X's url-independent bearer, useless for
  an `X-s` signed for the url it was issued for. The credential surface is absent
  rather than present-and-unused.
- **The matcher is path-pinned**, because the live probe found rednote's telemetry
  on hosts beside the feed (`t2.rnote.com`, `apm-fe.rnote.com`, `as.rednote.com`).
- **Board id is 24-char hex**, so Pinterest's `/^\d+$/` rule could not be reused.
  The id is required, and not merely for labelling: the driver scopes on it, and
  the replay buffer can hold pages from a board visited earlier in the same tab.
- **Early-stop stays disarmed.** Instagram earned `STOP_AFTER_CONSECUTIVE_SKIPS`
  with a live-verified newest-first precondition; board ordering is unverified, and
  copying it without the precondition silently truncates sweeps.
- **The popup warning states the limit**, not just the risk: one cover per note, no
  carousels, no video.

## Files changed

New: `src/rednote-hook.js`, `src/rednote-source.js`, `test/hook-sync.test.js`,
`test/platform-registry.test.js`.
Changed: `src/bulk-controller.js` (dispatch map, rednote builder, exported guard),
`src/bulk-messages.js`, `src/bulk-context.js`, `src/popup-view.js`, `src/config.js`,
`src/drift.js`, `scripts/drift-check.js`, `manifest.json`, `test/drift.test.js`.

## Verification

`npm test` 695 → 714 total, 711 pass, 0 fail. `npm run drift-check` clean, with
rednote correctly reported as awaiting a live capture.

## Migration notes

The manifest gains host coverage for `rednote.com` / `xiaohongshu.com` (hook,
bulk-loader, web-accessible resources). `host_permissions` already listed both from
K2, so this adds no new permission prompt.
