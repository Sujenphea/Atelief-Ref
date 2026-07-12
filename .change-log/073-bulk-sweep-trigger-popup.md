# 073 — Bulk sweep trigger: toolbar popup

Closes **Gap 0** (doc 019): a sweep no longer needs the service-worker console. A
toolbar popup resolves the active tab into a sweep spec and sends the existing
`atelier-bulk-start` message. The whole bulk pipeline (engine, relay, ledger,
checkpoint, pause/resume) is unchanged — this is purely a trigger surface + a pure
context resolver.

## Summary

Reviewed interactively across Architecture → Code Quality → Tests → Performance; all
recommended options taken (1A popup · 2A pure resolver · 3A injection fallback · 4A
delegate progress to the app's Sweeps tab · 5A shared message contract · 6A
discriminated result · 7A bookmarks-only X · 8A idempotency guard · 9A minimal
fixtures · 10A pure dispatch · 11A contract test · 12A runbook · 13A ISOLATED DOM read
· 14A resolve-on-open · 15A no hot-path work).

- **Popup** (`action.default_popup`) resolves the active tab on open, shows the target
  or a typed refusal reason, offers a `resolveVideo` toggle, and launches. Progress is
  delegated to the app's Sweeps tab (single source of truth) — the sweep survives the
  popup closing because the loop lives in the content script.
- **Pure resolver** `bulk-context.js`: `resolveSweepSpec({ url, collageHref })` →
  `{ ok, spec } | { ok:false, reason }`. Pinterest board id is read from the board
  page's **"Collage" button href** (`/collage-creation-tool/?boardId=<digits>`) — see
  root-cause below. X is gated to bookmarks pages — the main tab (`/i/bookmarks`) and a
  bookmark folder (`/i/bookmarks/<id>`, scoped `bookmarks:<id>` so a folder resumes
  independently) — so a wrong page can never sweep the home feed (the driver ignores
  `input`; the folder id only scopes the sweep).
- **Pure dispatch** `bulk-dispatch.js`: sends the START message; on a first failure
  (a tab with no content script — the fresh-install case) injects `bulk-loader.js`
  and retries until the controller answers.
- **Shared message contract** in `bulk-messages.js`: `START` + `buildStartMessage` /
  `readStartMessage`, so the popup and the controller can't drift on the shape.
- **Idempotency guard**: `registerBulkController` no-ops if already wired
  (`window.__atelierBulkController`), so the injection retry can't leave two listeners.
- `chrome.action.onClicked` single-item capture removed (dead once a popup is set) —
  single capture stays on the right-click context menu.

## Files changed

- **new** `extension/src/bulk-context.js` — pure tab→spec resolver + reasons.
- **new** `extension/src/bulk-dispatch.js` — pure send + cold-tab injection recovery.
- **new** `extension/src/popup.html`, `extension/src/popup.js` — the trigger UI.
- **new** `extension/test/bulk-context.test.js`, `bulk-dispatch.test.js`,
  `bulk-messages.test.js` — resolver matrix, dispatch branches, contract round-trip.
- `extension/src/bulk-messages.js` — `START`, `buildStartMessage`, `readStartMessage`.
- `extension/src/bulk-controller.js` — `registerBulkController` (guarded) reads the
  spec via `readStartMessage`.
- `extension/manifest.json` — `action.default_popup: "src/popup.html"`.
- `extension/src/sw.js` — removed the now-unreachable `action.onClicked` listener.
- `.docs/019-bulk-import-verification.md` — Gap 0 closed; Phase 10 runbook (T12–T16).

## Verification

`node --test` green (209 tests). The new units cover the full resolver matrix (site /
page / board-id / host variants), the dispatch branches (happy / resolved-error /
inject→retry / exhausted / inject-failure), and the message-contract round-trip.

## Root-cause: where the Pinterest board id lives (2026-07-07)

The first live launch failed with "Couldn't read this board's id." Verified against the
real board DOM (not guessed): **Pinterest is not a Next.js app** — there is no
`__NEXT_DATA__` script tag, so the initial resolver read nothing. The board id is
carried in the board page's **"Collage" button**, an anchor whose href is
`/collage-creation-tool/?boardId=1084663960195879466`. The resolver now reads that href
(matched by the stable, non-localized `/collage-creation-tool/` path — the button's
CSS classes are obfuscated/unstable) and parses the `boardId` query param. Fixtures use
the real observed href shape.

## Pending (real-data)

- **End-to-end launch (Phase 10 T12)** — the board-id *source* is now confirmed from
  real markup, but a full popup→sweep→ledger run still needs the reloaded unpacked
  extension + live session. The "Collage" button only appears on **your own** boards
  (the bulk-import use case); a board without it surfaces `board-id-missing`.
- **Phase 10 T13–T16** (X launch, ineligible reasons, cold-tab recovery, single-capture
  regression) not yet executed.

## Migration notes

None. No schema, protocol, or storage change. Reload the unpacked extension so the new
`default_popup` and the removed `onClicked` take effect.
