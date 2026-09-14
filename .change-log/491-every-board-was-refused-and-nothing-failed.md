# 491 — every board was refused and nothing failed

## Summary

A test-coverage fix, no behaviour change. `resolveSweepSpec` decides whether a rednote
sweep can start at all, and it was covered **only by refusals** — `platform-registry.test.js`
asserted that `/explore/abc` and `/board/not-hex` come back with a `REASON_MESSAGE`, and
`bulk-context.test.js` said the word "rednote" nowhere. A regression that refused **every**
rednote board passed all 898 tests; it is now eight tests, and the mutation run below is the
proof rather than the claim.

The positive cases are pinned against a **real saved board**, copied verbatim out of the
address bar (`https://www.rednote.com/board/69322476000000001202811f?source=web_user_page`),
whose id is the same one the live board-feed capture carries
(`resources/rednote-board-page2.json`, `board_id=69322476000000001202811f`). Fixture, parser
and resolver now describe one board rather than three plausible inventions.

> **Index.** This entry is 491, not 489. A concurrent, unrelated session holds
> `489-the-poster-that-never-came-down.md`, and indices are never reused.

## What the resolver already did, asserted

Nothing in `src/` moved. Every property below was confirmed against the current code before
a line of test was written:

- The **real URL verbatim, query string included**. It is the one literal in the section
  that is deliberately a literal — pinning the shape a user actually has is the point, and
  it is what stops this drifting away from reality a second time.
- The **bare and trailing-slash forms**, and the `www`-less host.
- **`xiaohongshu.com` resolving identically.** The module comment says both domains are in
  `host_permissions` and both must resolve; the mainland domain had no coverage anywhere, so
  it is asserted rather than trusted — at `platformForHost` and end-to-end through
  `resolveSweepSpec`, for every spelling. A board swept from one domain and resumed from the
  other must land on the same scope or it re-walks from zero.
- **`scope` is `board:<id>` and `input.boardId` is the id**, built from the id rather than
  retyped, so the assertion reads *scope keys off the board id* and not *scope happens to be
  this string*. This is the one that matters at runtime: the driver filters the hook's replay
  buffer through `matchesScope`, and that buffer can still hold pages from a board visited
  earlier in the same tab.
- **Case-insensitive hex**, since the id regex carries `i` — and the id is carried through
  **unchanged**, because the scope is compared as a string.
- **The 16–32 length bound at both ends, and one character outside each.** The real id is 24,
  so without 16/32/15/33 the bound would be incidental rather than intended.
- **`spec` carries no `resolveVideo` and no `expandNotes`.** `deepEqual` already catches an
  extra key; both are also named out loud, because 490 changed what `resolveVideo` means and
  the reason it does not live here (`bulk-context.js:19`) is worth restating next to the
  assertion.

Two refusals that existed only in `platform-registry.test.js` now also live where the rest
of the eligibility matrix does, told apart from each other on purpose: a non-board page is
`rednote-not-a-board` ("go find a board"), a board page whose id will not parse is
`rednote-board-id-missing` ("reopen this one"). The `REASON_MESSAGE` completeness test drove
six of the eight branches and named them in a sorted set; it drives all eight now, so a
**new** rednote reason shipped without copy fails there instead of rendering blank guidance.

## The structural half: every platform must resolve something

`platform-registry.test.js` asserted that every refusal has a message. A platform that
refuses **everything** passes that test perfectly — with the popup showing its guidance
string on the very board it was written for. That is the shape of the gap, and it is not
rednote-specific: it is what the next platform gets for free.

So each entry in the file's `PLATFORMS` fixture now names one real page URL that **must**
resolve (Pinterest supplies a `collageHref` beside it, the way the existing tests do), and
the per-platform test asserts the spec comes back `ok`, names that platform, and carries a
non-empty scope. The URL is also checked to be on the host registered on the line above it,
so the two halves of the fixture cannot drift apart.

Judged in scope rather than overreach: this file's stated job is that a platform cannot be
half-added, and it already asserts `platformForHost`. Recognising the host is half of what
the resolver does; accepting a page is the other half, and it fails just as silently. The
assertion costs one URL per platform and is wired for all four.

## Files changed

`extension/test/bulk-context.test.js` (+7: the rednote section, the two-domain
`platformForHost` case, two rednote lookalikes added to the unsupported-host list, and the
two rednote branches into the `REASON_MESSAGE` completeness test),
`extension/test/platform-registry.test.js` (+1 assertion inside each of the four existing
per-platform tests, plus the `sweep` fixture they read).

No `src/` file was touched.

## Verification

`npm test` 898 → **906 total, 903 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine
arms pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm,
which pre-dates this change.

**The gap, demonstrated first.** The rednote branch rewritten to `return { ok: false, reason:
"rednote-not-a-board" }` unconditionally — every board on both domains refused, no sweep able
to start — was run against the **committed** tests: 898 total, 895 pass, **0 fail**. Against
the new ones it fails 8, and no others.

Eleven deliberate breakages of `src/bulk-context.js`, each failing the tests that name it and
nothing else:

| mutation | fails |
| --- | --- |
| the rednote branch always refuses (the regression above) | 8 — all six positive rednote tests, the `rednote:` registry arm, and the completeness test |
| `[0-9a-f]{16,32}` narrowed to `[0-9]{16,32}` | 6 — the real board's id ends in `f`, so the live URL itself stops resolving |
| the `i` flag dropped | 1 — the case test, alone, which is what it is for |
| `{16,32}` narrowed to `{24}` | 1 — the length-bound test, on 16 and 32 |
| `` scope: `board:${id}` `` → `` `rednote:${id}` `` | 5 |
| `xiaohongshu` dropped from `platformForHost` | 3 — including the refusal test, which quietly re-routes to `not-supported-site` |
| `resolveVideo: false` added to the rednote spec | 4 |
| the board id lowercased into the spec | 1 — the case test again, on the "carried through unchanged" half |
| `segments[0] !== "board"` relaxed to `false` | 2 — the non-board refusals |
| `rednote-board-id-missing` renamed to a reason with no `REASON_MESSAGE` entry | 4, both completeness tests among them |
| the X branch always refuses | 3 — including `twitter: registered in every place a sweep needs it`, which is the cross-platform arm firing for a platform that is not rednote |

No mutant survived. Every mutation was reverted before committing; `git diff` over `src/` is
empty.

## Migration notes

- Nothing at runtime. No production file changed, and the resolver's answer for every URL is
  the answer it gave at `98a44ef`.
- A **fifth platform** must now add a `sweep` entry to `platform-registry.test.js`'s
  `PLATFORMS` — one page URL, plus whatever DOM input its resolver needs — or its
  per-platform test fails on a missing fixture. That is the point of the entry.
- One lenient behaviour is recorded but deliberately **not** pinned:
  `/board/<id>/<anything>` resolves, because the rednote branch reads `segments[0]` and
  `segments[1]` and ignores the rest, where Pinterest's `pinterestBoardPath` insists on
  exactly two segments. No such route has been observed and scoping a deeper board route to
  its board would be right anyway, so there is nothing to fix; a test asserting it either way
  would be pinning an accident.
