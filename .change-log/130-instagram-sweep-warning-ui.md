# 130 — Instagram sweep account-risk warning UI (002 · B4)

## Summary

The mandatory account-risk warning + acknowledge gate for the Instagram saved-posts
sweep (002 · B4 — mandatory, not optional). Before an IG sweep can start, the popup shows
an explicit throttle/checkpoint warning and keeps Start disabled until the user ticks an
"I understand the account risk" box. X and Pinterest are unaffected (no gate). Completes
the B0–B4 phased plan.

## What changed

- **`popup-view.js`** — two pure helpers (unit-tested):
  - `sweepWarning(spec)` → the IG account-risk copy (names the throttle/checkpoint risk
    and how to recover from a challenge), or `null` for X/Pinterest.
  - `startEnabled(spec, acknowledged)` → the single gate rule: a warned platform stays
    disabled until acknowledged; an unwarned platform enables immediately. Centralized so
    the gate can't be bypassed by a wiring slip.
- **`popup.html`** — a `.warn` banner + an `.ack` acknowledge checkbox row (both hidden by
  default).
- **`popup.js`** — `showTarget` shows the warning + acknowledge row for a warned platform
  and drives Start's disabled state through `startEnabled` (re-evaluated on every checkbox
  change); `showReason` hides both. Thin DOM glue, consistent with the file's existing
  role.

## Test results

`node --test`: **350 pass / 0 fail** (+3 popup-view cases: the IG label, `sweepWarning`
presence/absence, and `startEnabled` gating). The DOM wiring in popup.js is glue (not
unit-tested by design); the account-risk decision it enforces is the pure, tested rule.

## Migration notes

None (extension-only). The warning copy is the store-review / privacy disclosure the new
`instagram.com` permission (128, G14) requires the UI to surface.

## Status: 002 shipped (B0–B4)

Instagram saved-posts bulk import is complete: recon + fixtures (126), shared hook-core +
generic intercept source (127), host permission + hook (128), driver (129), warning UI
(130). Deferred, documented in 002: collections (6A), the re-sweep early-stop (14A), the
export-ZIP backfill (017). Known caveat: the mid-feed `next_max_id` cursor is IG-convention
(single-page recon account) — re-verify against a multi-page saved feed on first live use.
