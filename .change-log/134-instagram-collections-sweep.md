# 134 — Instagram saved-collection sweep (002 · 6A, was deferred)

## Summary

A sweep can now target a specific Instagram saved **collection**, not just flat "All
posts". Live recon (2026-07-16, account `lychee.web`) settled the two unknowns that had
kept collections deferred:

- **Endpoint:** `GET /api/v1/feed/collection/<id>/posts/?max_id=<cursor>` — confirmed to
  return the **same envelope** as the flat saved feed (`items[].media`, `more_available`,
  `next_max_id`), the **same `?max_id=` pagination**, and the **same single `x-ig-app-id`
  header**. So only the request PATH differs — the parser, pagination, headers, fan-out,
  media-host guard, pacing, and account-risk warning all reuse unchanged.
- **URL shape:** `/{user}/saved/{slug}/{collectionId}/` — 4 path segments, a numeric
  trailing id (16 digits observed; matched as `\d+`, not a fixed length).

## Changes

- `bulk-instagram.js`
  - `collectionFeedPath(id)` + `isCollectionFeedRequest(url)` (route matcher, `\d+` id).
  - `buildSavedFeedURL({ …, collectionId })` — a `collectionId` targets the collection
    path; its absence walks the flat saved feed. Same `?max_id=` cursor either way.
  - `enumerateSavedFeed(fetchJson, { host, collectionId }, { cursor })` threads it through.
  - `instagramSavedDriver.enumerate(input, …)` now reads `input.collectionId` (the ONLY
    field it reads from `input`); a bare input still walks the flat feed.
- `bulk-context.js` — `resolveSweepSpec` IG arm: a `/saved/{slug}/{id}/` URL →
  `{ input: { collectionId, collectionSlug }, scope: "saved:collection:<id>" }`. Scope keys
  off the **stable numeric id** (a rename changes the slug, not the id, so a resume never
  collides/re-walks); the slug rides along for the popup label only. A saved subpath
  matching neither flat nor collection → new typed refusal `instagram-saved-unrecognized`
  (replaces the now-obsolete `instagram-collection-unsupported`).
- `popup-view.js` — `sweepLabel` names a collection by its slug ("Sweep Instagram
  collection: <slug>", falling back to "Sweep this Instagram collection"). `sweepWarning`
  / `startEnabled` are unchanged and already gate a collection sweep — it replays the same
  synthetic endpoint, so it carries the identical account-risk acknowledge gate.
- `drift.js` — `checkInstagramSaved` also asserts the collection route matcher matches its
  canonical URL (and doesn't match the flat feed).
- No `bulk-controller.js` change: `input` already rides the START message (`START_FIELDS`),
  so `input.collectionId` reaches `driver.enumerate` with no new wiring. The
  `sweepCheckpointKey` scope-fallback isolates each collection's resume for free.

## Tests

`node --test`: **361 pass / 0 fail** (+ collection route matcher, collection URL building,
driver collection routing, `resolveSweepSpec` collection success + malformed-subpath
refusal, collection label + account-risk gate).

## Migration notes

None (extension-only). Checkpoints are per-scope, so a collection sweep and the flat
saved sweep resume independently. Collection membership is not mutually exclusive (a post
can be in All posts and any number of collections); dedup keys on the per-media `pk`, so
sweeping a collection after All posts just re-skips the overlap.
