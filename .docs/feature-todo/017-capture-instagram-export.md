# 017 — Capture: Instagram Export-ZIP Backfill (descoped from 002)

> The account-safe complement to the live IG saved-posts driver
> ([002](../029-capture-instagram-bulk-overview.md)): parse Meta's "Download Your Information"
> export (`saved_posts.json`) and backfill saved posts offline. **Descoped from 002 on
> 2026-07-15** (review issue 4/4A) because the path the original plan assumed is a
> dead end — see §Why this is its own feature.

## Status (re-verified 2026-08-10)

**Not started, still blocked, and the blocker is unchanged**: no fresh
`saved_posts.json` from the user's account has been obtained, so the 2026 schema
remains unverified. Nothing in the tree references it. This doc is correct as
written — it is the one backlog entry that has not drifted.

## Why this is its own feature (not an "S" parser)

The 002 draft said: parse `saved_posts.json` → URL list → "feed through 001's
resolution / extension capture." Both halves fail as written:

1. **App-side resolution is a deliberate dead end.** 001 shipped with instagram.com in
   the auth-walled host set — `IngestionModel` refuses to resolve IG page URLs and
   routes the user to the extension (001 §Status, changelog 118). Feeding IG URLs to
   the app resolver yields refusals by design; "fixing" that would save login-wall
   garbage instead of media.
2. **No headless URL-list capture mechanism exists.** Single-item extension capture
   requires an open tab + a context-menu gesture (`activeTab`). There is no batch
   "open URL → harvest → capture → close" driver. Building one is the actual substance
   of this feature: a tab-driving import queue with its own pacing, progress UI,
   failure taxonomy, and (ideally) reuse of the bulk job ledger for resumability.

So the honest shape is: **export parser (S) + tab-driving capture queue (M)** — not S.

## Blocked on

1. **A fresh export from the user's account** to verify the 2026 `saved_posts.json`
   schema: does it carry media URLs or only post URLs? timestamps? collection
   structure? (Historically: post URLs + timestamps, no media bytes, no collections.)
   No design work before this is in hand — same recon-first discipline as 002 §B0.
2. **002 shipping** — the live driver covers freshness; this is backfill, so it can
   wait, and it should reuse 002's parser/provenance pieces where schemas overlap.

## Sketch (to be designed properly once unblocked)

- Pure `parseSavedPostsExport(json)` → `[{ postUrl, savedAt, … }]`, fixture-tested
  (committed sanitized fixture from the fresh export).
- Diff against the ledger/known-set: only URLs not already ingested enter the queue.
- Tab-driving queue: open post URL (single reusable background tab), let the existing
  IG extractor + capture path run, gentle pacing (this *is* synthetic navigation —
  pace like a human reading, not like 002's ride-along interception), halt-resumable
  on challenge, job-ledger row per item for resume/progress.
- UI entry point: import a `.zip`/`.json` file (app side or extension options page —
  decide at design time; the app already has file-drop plumbing).

## Value

- Zero account risk for the *enumeration* half (Meta-sanctioned, offline).
- Complete history backfill, including saves from before the extension existed.
- Deterministic input for tests.

## Risks

- Export is stale by hours-to-days and must be re-requested manually each time.
- The navigation half is still live traffic against instagram.com — pacing and
  challenge-halt discipline from 002 apply in full.
- 2026 schema unverified (the blocking item).
