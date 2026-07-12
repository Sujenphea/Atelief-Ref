# 082 — Production readiness Phase 3: runtime validation (G11)

Closes the automated half of
[021](../.docs/021-production-readiness-plan.md) Phase 3. Live browser E2E boxes
in [019](../.docs/019-bulk-import-verification.md) remain for a hands-on pass.

## Summary

- **G11** — Replaced template XCUITests with load-bearing smoke:
  launch + Canvas/Library/Sweeps tab switch; Library shows Unsorted after
  bootstrap. Tab accessibility identifiers on `ContentView`.
- Refreshed [009](../.docs/009-mvp-status-overview.md) to changelog head `081`
  (G16) with a production-readiness phase table; noted G7 off-main load.
- [019](../.docs/019-bulk-import-verification.md) gains an automated validation
  snapshot (suites green, XCUITest smoke, G1/G7 notes) without falsely ticking
  live T* cases.

## Files changed

- `AtelierRefsUITests.swift`, `ContentView.swift`
- `.docs/009-mvp-status-overview.md`, `.docs/019-bulk-import-verification.md`

## Migration notes

None. Remaining Phase 3 work is manual: finish unticked 019 cases + Instruments.
