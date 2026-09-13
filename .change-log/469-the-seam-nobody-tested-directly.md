# 469 — the seam nobody tested directly

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T1a. `intercept-source.js` — the push→pull
adapter a hook-driven sweep entirely runs on — had **no test file**. No test even
named it. Its whole guard was six tests in `twitter-source.test.js`, each reaching
it *through* X: X's parser, X's stall subclass, X's scope matcher. Properties X
happens not to exercise were unguarded, and 098 both adds a second consumer and
modifies the seam (R1, R7, R15).

So the seam now has 21 tests of its own, driven with fakes — which is what its own
header always invited: *"Pure/injectable: `scroll` + `sleep` are deps, so a test
drives the whole loop with no browser."*

## What was untested, and now is not

- **`expandItems`** — reachable today only via X's thread expander. Its fail-open
  rule is right for X (a failed `TweetDetail` costs the replies, the tweet still
  saves) and lossy for rednote (a failed note-detail saves 1 cover instead of 9
  images, and the sweep reports clean success). Pinned as the current contract so
  R7's reported counter lands on a known baseline.
- **`pendingError`** — the fatal route that halts a sweep resumable. It has **no
  production user**: X's parser never sets `error`, and Instagram, which does, is
  a PULL driver that never touches this seam. rednote's 461 halt would have been
  its first execution ever. Untested code on an account-safety path.
- The idle-counter **reset**, asserted by scroll count rather than by outcome —
  the previous shape would have passed without a reset ever happening.
- That `enumerate` **ignores the engine's resume cursor**, so 098 D1's finding is
  a pinned fact rather than a comment, and T1b's change to declare it will be a
  visible edit.

## One expectation the code corrected

A test written to assert that a fatal error still yields pages queued *before* it
failed. The real behaviour is the opposite: `pendingError` is checked at the top of
each iteration, so it pre-empts a non-empty queue.

That is the safer behaviour — halting the moment a challenge is seen beats draining
a backlog against a flagged account — and it costs nothing, because the sweep halts
resumable and a resume re-walks those pages with dedup-skip making the overlap
idempotent. The test now pins the actual contract and says why, rather than the
intuitive reading.

## Files changed

- `extension/test/intercept-source.test.js` (new) — 21 tests.

## Verification

`npm test` 639 → 661 total, 658 pass, 0 fail (3 pre-existing skips).

## Migration notes

None. Tests only — no source changed. This is the ordering gate for T1b, which
modifies `intercept-source.js` for R1, R7 and R15.
