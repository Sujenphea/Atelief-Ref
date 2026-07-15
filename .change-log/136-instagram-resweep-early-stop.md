# 135 — Re-sweep early-stop (002 · 14A, was deferred)

## Summary

A re-sweep no longer re-walks the whole Instagram saved feed once it reaches
already-synced territory. After a run of consecutive already-known items, a **fresh** sweep
whose **prior run closed failure-free** stops cleanly — cutting the account-risk page
fetches a re-sync costs (the dominant cost; dedup-skips themselves are free — no pace, no
relay, no ledger write). IG-only; X/Pinterest still re-walk in full.

**Precondition verified live (2026-07-16):** IG's saved feed is ordered newest-**save**-first
— a freshly-saved post lands at feed index 0 and pushes the rest down in order (and the feed
is NOT post-time ordered). So once a run of known items begins, the tail stays monotonically
known, which is exactly what makes early-stop safe.

## Design

- **Engine (`bulk-engine.js`)** — new `STOP_AFTER_CONSECUTIVE_SKIPS` config (default
  null = off). The engine tracks a trailing run of consecutive `skipped` outcomes over the
  **contiguous committed prefix** (so it counts in enumeration/seq order — immune to
  out-of-order completion under concurrency, reusing the existing checkpoint watermark
  machinery). On hitting the threshold it stops and closes the job **`complete`** (an
  early-stop is a clean end-of-sync, NOT a resumable halt → the checkpoint is cleared).
  Any non-skip **resets** the run, so a stray new item deeper in the feed is never walled
  off. Inert on a resume (`startCursor != null`) — a resumed walk must finish, and its
  checkpoint-page overlap would be a false skip-run at the front. `result.earlyStopped` is
  surfaced for logging.
- **Controller (`bulk-controller.js`)** — arms the threshold ONLY when the sweep is fresh
  (no outstanding checkpoint) AND the prior run of this scope closed **clean**. "Clean" is
  tracked entirely extension-side by a new persistent `:lastclean` marker
  (`sweepCleanMarkerKey`) written after every complete close — `{ clean: retryableFailed
  === 0 && permanentFailed === 0 }`. It persists separately from the checkpoint (which a
  clean close clears), so any prior failure forces the next sweep to full-walk and
  re-attempt the stray. **No app/server change.**
- **Config (`config.js`)** — `PLATFORM_PACING.instagram.reSweep.STOP_AFTER_CONSECUTIVE_SKIPS
  = 30` (~1 page of singles of margin; carousels count per-image → conservative).

## Why the clean-marker gate (the load-bearing subtlety)

A job can close `complete` while carrying `retryableFailed` items (transient CDN hiccups
deep in the feed). Those aren't in the known-set, so a re-sweep *should* re-attempt them —
but naive early-stop would halt before reaching them and strand them permanently. Gating
on "prior sweep was failure-free" prevents that: one bad item → the marker records
`clean:false` → the next sweep full-walks until everything's clean again (self-correcting).

## Tests

`node --test`: **370 pass / 0 fail**. Engine: early-stop fires after K consecutive knowns
(clean complete, not halt); a non-skip resets the run (deep new item still captured);
disabled on resume; disabled with no threshold; still stops early under concurrency.
Controller: clean-marker true/false recording; early-stop armed ONLY on fresh + prior-clean
(and NOT on a first-ever sweep or after a prior failure).

## Migration notes

None (extension-only). Behaviour is unchanged for X/Pinterest and for a first-ever IG
sweep. A `chrome.storage.local` `…:lastclean` key per swept scope is added (tiny). To force
a full re-walk, clear that scope's checkpoint/marker (or a prior failed sweep does it
automatically).
