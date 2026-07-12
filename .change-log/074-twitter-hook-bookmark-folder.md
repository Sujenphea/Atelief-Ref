# 074 — X bookmark folders: hook forwards `BookmarkFolderTimeline`

Follow-up to [073](./073-bulk-sweep-trigger-popup.md): the popup recognized bookmark
**folder** URLs (`x.com/i/bookmarks/<id>`) and launched, but a folder sweep ingested
**0** items. Root-caused on real data, not guessed.

## Root cause

The MAIN-world timeline hook (`twitter-hook.js`) only forwarded GraphQL responses
whose operation was `Bookmarks` or `Likes`. A live capture confirmed a bookmark folder
loads via a **distinct operation**, `BookmarkFolderTimeline`
(`/i/api/graphql/{queryId}/BookmarkFolderTimeline?variables={"bookmark_collection_id":…}`),
so its responses never matched `isTimelineRequest` → never reached the content script →
the source's queue stayed empty → the loop auto-scrolled to the bottom finding nothing
→ 0 items. (The "scroll works but nothing ingests" fingerprint pointed straight at the
filter, not the parser.)

The **parser was already fine**: the folder response nests the same
`TimelineTimelineItem` tweets under `data.bookmark_collection_timeline.timeline.
instructions`, which `findInstructions`' deep-search fallback already locates. The only
bug was the forward filter.

Distinguishing this from mere dedup took real data: the folder jobs had `ingested=0`
and **zero `job_item` rows**, which is ambiguous (known-set skips leave no row either).
Clearing the library (empty known-set) and re-sweeping still gave 0 with the scroll
firing — proving enumeration, not dedup, was empty.

## Changes

- `extension/src/twitter-hook.js` — `isTimelineRequest` now also matches
  `BookmarkFolderTimeline`.
- `extension/src/bulk-twitter.js` — added `bookmark_collection_timeline` to
  `findInstructions`' known-wrapper list (explicit over relying on the deep-search
  fallback) + header comment.
- `extension/test/bulk-twitter.test.js` — the `isTimelineRequest` test now asserts a
  real `BookmarkFolderTimeline` URL matches; added `findInstructions` (folder wrapper)
  and `parseTimelinePage` (folder response parses like the main tab) cases.
- `.gitignore` — ignore the stray root-level raw capture
  `twitter-bookmark-folder-response.json` (belongs in `/resources/`).

## Verification

`node --test` green (211). The captured folder request URL confirmed the operation
name; the captured response confirmed the wrapper key + that the existing tweet mapping
applies unchanged.

## Pending (real-data)

Live folder sweep after reload: reset library was in progress; re-sweep the folder →
expect ingested > 0. If a folder capture should join CI, sanitize it into
`extension/test/fixtures/` (the reused-instructions test covers the code path meanwhile).

## Migration notes

None. Reload the unpacked extension so the updated MAIN-world hook injects.
