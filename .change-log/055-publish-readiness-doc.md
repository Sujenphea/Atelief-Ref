# 055 — Publish-readiness doc + AGENTS.md

## Summary

Housekeeping after the review + hardening work (052, 054):

- Added `AGENTS.md` — the Codex-oriented mirror of `CLAUDE.md` (same commit / doc
  conventions), so the repo's agent instructions are available to both tools.
- Consolidated two now-stale review notes into a single accurate standing
  checklist. The earlier `.docs/014-capture-extension-readiness-overview.md` and
  `.docs/015-codebase-review-overview.md` (with changelogs 051 / 053) documented
  findings that have since been implemented in 052 and 054, so keeping them would
  enshrine "problems" that are already solved. They are replaced by
  `.docs/014-publish-readiness-overview.md`, which records only the genuinely open
  work (Chrome Web Store packaging: icons, package script, privacy/reviewer
  materials, distribution + extension-id pinning) and lists the resolved findings
  with pointers to their changelogs.

## Files changed

- `AGENTS.md` — new (Codex agent instructions, mirrors `CLAUDE.md`).
- `.docs/014-publish-readiness-overview.md` — new (consolidated standing checklist;
  the old 014/015 review overviews were never committed and are dropped).

## Migration notes

None — documentation-only. The dropped review notes (`.docs/014` readiness,
`.docs/015` codebase-review, and changelogs 051/053) were untracked and are not
part of history; their engineering findings live on in changelogs 052 and 054, and
their open publish items in the new `.docs/014`.
