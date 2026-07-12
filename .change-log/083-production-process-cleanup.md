# 083 — Production readiness Phase 5b: process cleanup (G16/G18)

Closes the remaining process gaps from
[021](../.docs/021-production-readiness-plan.md) Phase 5 (G15 landed in `079`;
G16 started in `082`).

## Summary

- **G16** — [009](../.docs/009-mvp-status-overview.md) already refreshed to
  changelog head; marks Phase 5b complete.
- **G18** — Operationalized the drift canary:
  - Pure `fixtureStaleReminder` in `drift.js` (unit-tested)
  - `drift-check.js` prints the reminder and exits non-zero when fixtures are past
    `staleAfterDays`
  - `npm run drift-remind` alias; popup + options hint to run the canary before
    the ~2-week X queryId rotation window

## Files changed

- `extension/src/drift.js`, `scripts/drift-check.js`, `package.json`
- `extension/src/popup.html`, `options.html`
- `extension/test/drift.test.js`
- `.docs/009-mvp-status-overview.md`

## Migration notes

None. Schedule a personal reminder (`npm run drift-remind` from `extension/`)
every ~2 weeks or before a large bulk sweep after idle.
