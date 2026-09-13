# 468 — the key was never the last segment

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T0. `toRednoteOriginal` read the CDN
object key as the **last** path segment of a signed rednote URL. That is true for
a board-feed cover and false for a note's `image_list` images, which are keyed
`oss-sg/spectrum/<id>` — two segments the rule threw away, building a URL that
404s:

```
http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug…  → 200  240,729 B jpeg
http://sns-i27.rednotecdn.com/1040g3ug…                  → 404
```

Nothing reported it. `mediaUrlFallback` catches the 404 and the item saves as the
47,226 B signed webp, so the only symptom was a 5× quality loss on every
`oss-sg/spectrum` note — no error, no log, a capture that looked fine.

The key is **everything after the two signing segments** (`<timestamp>/<sighex>/`),
not the tail. Checked over 184 URLs from two live captures (2026-09-13), that
agrees with the API's own `file_id` **184/184**, where last-segment disagrees on
36 — and it still works on board covers, where `file_id` is `""` on every row.
`file_id` is deliberately not read: it would corroborate the rule, not correct it.

Two properties came free and are now pinned by tests: the rewrite is idempotent
on a multi-segment key (re-running it no longer eats the prefix), and a path too
short to hold a signing prefix plus a key — `sns-avatar-qc…/avatar/<id>` — is left
alone instead of being rewritten onto the origin host.

## Files changed

- `extension/src/extractors/rednote.js` — the key rule, the docstring, and the
  file header's media note.
- `extension/test/extractors.test.js` — three tests: the multi-segment regression
  (verbatim captured URLs, with the single-segment cover asserted alongside so the
  fix cannot regress the other shape), idempotence + short-path passthrough, and
  an extractor-level test asserting `mediaUrl` **and** `mediaUrlFallback` together,
  because it was the pair that made the fault invisible.

## Verification

`npm test` 636 → 639 pass, 0 fail. `npm run drift-check` clean, including the
extension ↔ iOS host-table mirror (the Swift side carries host entries only — no
rewrite to mirror, so nothing there needed changing).

## Migration notes

None. Already-ingested `oss-sg/spectrum` captures kept the webp they were saved
with; this changes only what future captures fetch. Re-capturing such a note now
yields the original, and 18A hash dedup treats it as a new asset rather than a
duplicate of the webp.
