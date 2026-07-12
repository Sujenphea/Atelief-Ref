# 075 — X sweeps: replay pages fetched before the sweep subscribes

After [074](./074-twitter-hook-bookmark-folder.md) let the hook *forward*
`BookmarkFolderTimeline`, a folder sweep **still ingested 0**. Root-caused end-to-end on
real data (a full day of layer-by-layer elimination), then fixed at the source.

## Root cause

The X driver is a **passive interceptor** — it only captures timeline responses X
fetches *after* the sweep's listener attaches. But X fetches the first page when you
**navigate** to the timeline (and caches everything you scroll past), all *before* you
click Start. Those pages are never re-fetched, so the sweep's auto-scroll only triggers
the **empty tail page** → 0 items.

Confirmed via isolated-world diagnostics: the controller *did* receive a response during
the folder sweep, but it parsed to `items=0 tweets=0 cursor=null` — the empty end-page.
Meanwhile the folder's real content page parses to 15 items. Main bookmarks (T9) hid
this: it's a long, freshly-loaded timeline, so scrolling kept fetching *new* pages the
listener caught. A short or already-scrolled timeline (a small bookmark folder) exposes
it. **This was a latent bug in every X sweep** — even a fresh multi-page timeline
silently dropped its first page.

## Fix — buffer + replay

The MAIN-world hook installs at `document_start`, so it *sees* every page including
page 1. It now keeps a **bounded buffer** (last 25 responses) of what it forwards, and
**re-emits the buffer** when the controller posts a `TIMELINE_REPLAY_SOURCE` message.
`buildTwitterDriver` posts that request right after subscribing, so a late-starting
sweep receives the pages fetched before it existed. Dedup (known-set + content hash)
makes any overlap with the live pages idempotent.

Why this and not the alternatives: re-fetching X's GraphQL ourselves means forging the
volatile `queryId` / `x-client-transaction-id` — the exact brittleness interception was
chosen to avoid ([016 research]). A page reload would tear down the sweep. Buffering is
the minimal change that closes the timing gap at its source.

## Changes

- `extension/src/twitter-hook.js` — bounded replay buffer + a `REPLAY_REQUEST_SOURCE`
  message listener that re-emits it; both interceptor paths now `forward` (buffer+post).
- `extension/src/bulk-controller.js` — `buildTwitterDriver` posts a `TIMELINE_REPLAY_SOURCE`
  request after subscribing.
- `extension/src/bulk-messages.js` — `TIMELINE_REPLAY_SOURCE` constant.
- `extension/test/bulk-twitter.test.js` — buffer/replay + bounded-buffer tests; a
  constants-in-sync test for the hook's duplicated classic-script literals.

## Verification

`node --test` green (214). An end-to-end Node sim of the exact failure — the **real**
captured folder response forwarded *before* a subscriber attaches, then a replay — now
delivers **15 items** to the late subscriber (0 before the fix).

## Pending (real-data)

Live re-sweep after reloading the extension **and** the x.com tab (the hook injects at
`document_start`, so the tab must reload to pick it up): expect the folder to ingest > 0.

## Migration notes

None. Reload the unpacked extension and the x.com tab.
