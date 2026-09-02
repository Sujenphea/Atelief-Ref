# 456 — the plan, reviewed with the user

[098](../.docs/098-ios-companion-completion-plan.md) was committed this morning as an
unattended completion plan for the iOS companion: eleven findings, six phases, its own
decisions. It was then reviewed with the user, one section at a time — architecture,
code quality, tests, performance — against four independent read-only reviews of the
same tree, each of which had read every file in scope and cited the line for every
claim.

The review found more than the draft had. Fifteen issues went to the user with their
options and a recommendation; the user decided each. This entry records the amendment;
the six phases that follow each carry their own changelog.

## What changed in the plan

- **Four defects the draft did not have.** A crash mid-ingest on the phone retries
  forever, because an attempt is stamped only after the coordinator reports a failure;
  and a quarantined capture is silently dropped from the export, because the archive
  reads only the pending and ingested sites. The tier-2 media fetch in the share
  extension has no SSRF wall, though the Mac walls the identical fetch. The send count
  counts JSON files while the archive silently drops what it cannot decode, so one
  corrupt ingested record is "Send 1" forever. The writer accepts a zero-byte payload.
- **DRY the draft had not named.** `AtelierBrowse` restates the Mac's formatters,
  author rule, collection ordering and masonry constants, and one of them has already
  drifted (the author rule trims different whitespace on the two platforms). The JPEG
  fixture builder is duplicated verbatim across two suites, and a hand-rolled copy of
  the drain's retention move order lives in two more. `ShareViewController` is 848
  lines doing five jobs.
- **Two of the draft's decisions reversed, both by the user.** The draft put the
  App Group resolution fix in the seam (a defaulted `bundle:` parameter); the session
  first chose a test-side fix, then reverted to the draft's on its argument — the
  test-side fix copied three lines of the seam's own logic. The draft moved the
  thumbnail cache policy into `AtelierBrowse` as a generic decode cache; the session
  first chose to measure before building, then adopted the draft's once it became clear
  the cache's tests are what a phone-hosted unit bundle would otherwise exist for. The
  hosted bundle is therefore not added — for that reason, not the draft's.
- **Scope the draft had left open, now decided.** Companion app only; empty and error
  states, app icon and launch screen, and the item-detail layout are in; phone search
  and iPad are out; browse stays read-only (093 · Q1 closes as *no*); the analysis stack
  stays off the phone (091 · Q3); bare link shares get a host-name title fallback on the
  phone and the two docs that claimed the drain enriches them are corrected.
- **Three of the draft's findings the review had missed, kept.** The tier-2 UI test
  reads only the pending site and would fail by construction since the launch drain
  landed; the app has no display name, an empty accent and a black launch; the feed
  reads the collection twice.

## Files changed

- `.docs/098-ios-companion-completion-plan.md` — rewritten in place: the review section
  now carries the fifteen issues as they were put to the user, with the draft's findings
  folded in where they land and each reversal recorded beside the decision it replaced;
  the six phases re-cut so every decision has one carrier; the device checklist extended.

## Verification

Doc only. The tree at `bb841bd` plus the draft was baselined before any code moves:
`swift test` green in `AtelierCore` (771), `AtelierCapture` (133),
`AtelierLibraryPaths` (25), `AtelierBrowse` (82), `AtelierArchive` (65),
`AtelierTokens` (7), `AtelierIngestion` (483); `AtelierRefsMobile` builds for the
simulator; `AtelierRefsTests` passes on macOS; `node --test` in `extension/` passes 616.

## Migration notes

None. The phases that follow each state their own.
