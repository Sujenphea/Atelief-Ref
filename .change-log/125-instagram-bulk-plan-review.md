# 125 — Instagram bulk-import plan review (docs only)

## Summary

Interactive review of the IG saved-posts bulk-import plan before implementation.
14 issues found and settled with the user (architecture 4, code quality 4, tests 4,
performance 2). No code changes.

Key corrections to the plan:

- The cited X "media_key fan-out" pattern no longer exists (removed by `fe1a3ee`);
  carousels now settle on per-media fan-out via the plain-image path (1A).
- The plan omitted the push→pull source layer and cited a consent gate that doesn't
  exist; both are now explicit work items — `createInterceptSource` generalization +
  popup warning UI (2A).
- The "engine halt-classification for checkpoint/429" item targeted a layer that never
  sees those signals under O1 interception; replaced by hook/source-level
  `ChallengeError` detection (3A), with tests respecified accordingly (11A).
- The export-ZIP phase (B2) contradicted shipped 001 behavior (instagram.com is
  auth-walled by design) and hid a tab-driving queue inside an "S" estimate; descoped
  to a new doc (4A).
- Hook fork replaced by a shared classic `hook-core.js` + thin per-site configs (5A);
  flat-only v1 scope with typed collection refusals (6A); reels stash
  `rawMetadata.videoUrl` so the existing resolve-video toggle works (7A); recon-first
  fixtures are a hard B0 prerequisite (8A); integration-test parity with X incl.
  replay contamination (9A); full hook test matrix (10A); drift canary respec'd —
  O2-residue App-ID check dropped, per-platform stale windows, exact-count assertions
  (12A); `PLATFORM_PACING` map for per-platform engine+source knobs (13A); re-sweep
  early-stop deferred but documented with its blocking conditions (14A).

## Files changed

- `.docs/feature-todo/002-capture-instagram-bulk.md` — rewritten in place: corrected
  citations, settled decisions dated 2026-07-15, revised phases B0–B4, revised test
  strategy, deferred-work section.
- `.docs/feature-todo/017-capture-instagram-export.md` — new: descoped export-ZIP
  backfill with the 001 auth-wall constraint and its blockers recorded.
- `.change-log/125-instagram-bulk-plan-review.md` — this entry.

## Migration notes

None (documentation only). Implementation follows 002's revised phases; B0 (recon)
requires the user's logged-in IG account and gates all parser work.
