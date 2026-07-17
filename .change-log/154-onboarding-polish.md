# 154 — Onboarding: truthful step count + live pairing confirmation (034 P2)

## Summary

Three onboarding polish fixes from the P2 backlog:

1. **Copy matched the content.** The header promised "three quick steps" but four
   numbered steps rendered. Step 4 ("You're set") is a closing note, not a setup
   step — it's now a non-numbered outro card, so the three numbered rows match the
   header.
2. **Live pairing confirmation.** Pairing happens out-of-band (the token is pasted
   into the Chrome extension), so the app couldn't confirm it worked. Added: a live
   endpoint status dot in the token row (green "Listening" / orange
   "port in use"), and a green "your first capture landed in Unsorted" callout under
   step 3 that appears the moment a capture arrives while the guide is open.
3. **Token-row loading flash.** The placeholder text ("Opening library…") is now a
   `.redacted(.placeholder)` shimmer over the token slot instead of a raw string
   swap, so the row doesn't visibly flash text before the token resolves.

## Files changed

### AtelierRefs
- `OnboardingSheet.swift` — step 4 → `outro` (non-numbered); `endpointStatus` dot +
  redacted token placeholder in `tokenRow`; `capturedConfirmation` callout gated on
  a new `receivedFirstCapture` state driven by `onChange(of: model.lastCaptureBatch)`.

## Migration notes

None. Purely presentational; the pairing flow itself is unchanged.

## Verify

- Open the guide (first run, or Settings ⌘, → replay) → the header says "three quick
  steps" and exactly three numbered rows show, with a "You're set" card below.
- The token row shows a green "Listening for captures" dot (orange if the port is
  busy); the token shimmers as a placeholder until the library opens.
- With the guide open, capture an image from the extension → a green "your first
  capture landed" line appears under step 3.
