# 076 — X sweeps: only ingest the feed you're actually sweeping

A folder sweep ingested tweets from **outside** the folder. Regression introduced by
[075](./075-twitter-hook-replay-buffer.md).

## Root cause

The MAIN-world hook is scope-blind by design — it forwards every timeline the page
fetches (`Bookmarks`, `BookmarkFolderTimeline`, `Likes`). 075 added a replay buffer
that re-emits the responses fetched *before* the sweep subscribed. But
`createTwitterSource.onResponse` queued **any** response it was handed with no check on
which feed it came from. So if you browsed your main bookmarks (or another folder, or
Likes) and then swept a specific folder, the replay dumped those buffered pre-sweep
pages into the folder sweep → tweets from outside the folder. Content-hash / known-set
dedup can't catch this: the extra tweets are genuinely distinct, they just don't belong
to the folder.

## Fix — gate responses by the sweep's scope

`matchesScope(url, scope)` (pure, in `bulk-twitter.js`) maps the response's request URL
to the sweep's scope — exactly what `resolveSweepSpec` emits:

- `"bookmarks"` → the `Bookmarks` op only (not `BookmarkFolderTimeline`, not `Likes`).
- `"bookmarks:<folderId>"` → a `BookmarkFolderTimeline` request whose `variables` carry
  `"bookmark_collection_id":"<folderId>"` — so *another* folder's pages are rejected too.
- unknown / missing scope → matches nothing (drop rather than pull the wrong feed).

`onResponse(json, url)` now drops out-of-scope responses; the controller threads the
response's `url` (already on the hook's message) and the sweep's `scope` through
`buildTwitterDriver`. `scope` unset (tests / a scope-agnostic caller) accepts everything,
preserving prior behaviour. This gates both the live stream and the replay buffer.

## Changes

- `extension/src/bulk-twitter.js` — `matchesScope(url, scope)`.
- `extension/src/twitter-source.js` — `createTwitterSource` takes `scope`; `onResponse`
  takes the response `url` and drops out-of-scope pages.
- `extension/src/bulk-controller.js` — `buildTwitterDriver` receives `scope`, forwards
  `event.data.url` into `onResponse`.
- `extension/test/bulk-twitter.test.js` — `matchesScope` unit tests (main / folder /
  cross-folder / Likes / unknown scope).
- `extension/test/twitter-source.test.js` — a folder scope drops other feeds' replayed
  pages; no scope accepts everything.

## Verification

`node --test` green (219). New tests reproduce the exact contamination — a main-bookmarks
page replayed into a folder sweep is now dropped, only the folder's own tweets ingest.

## Pending (real-data)

Live: browse your main bookmarks, then open a bookmark folder and sweep it — expect
ONLY that folder's items to appear (previously the main list leaked in). Reload the
extension and the x.com tab first.

## Migration notes

None. Reload the unpacked extension and the x.com tab.
