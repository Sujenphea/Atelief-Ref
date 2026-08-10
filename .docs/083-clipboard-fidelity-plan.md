# 083 — Clipboard Fidelity: ⌘C/⌘V Inside the App Should Not Re-Import

**Status: shipped** — C1, C2 and C3 in `c672373` ("copy-paste keeps the asset,
not its bytes"), on top of `4be6f88`'s ⌘C across surfaces. The dual write is
`AssetPasteboard.swift:143` (the private `AssetDragPayload` appended *after*
`AssetPasteboardWriter.write`, order load-bearing); the grid paste branch is
`CollectionView.resolvePaste` (`:947`) feeding `paste()` (`:957`); the board
branch is `SpaceView.pasteOntoBoard` (`:948`). Covered by `AssetPasteboardTests`
and `ServicesClipboardPasteTests`.

Promoted out of `feature-todo/019-clipboard-fidelity.md`.

> Dragging assets between collections keeps the asset row (and therefore its note,
> tags, provenance, analysis). Copy-pasting the same assets silently rebuilds them
> from bytes and can lose all of it. The board already solved this in
> [065](065-spaces-duplicate-clipboard-plan.md) §2.4–2.5 by writing a second,
> app-private pasteboard representation; the grid never got it. This doc is that
> gap, and the fix is the 065 pattern applied outside Spaces.

## Current state (verified)

- **Grid ⌘C writes bytes only.** `IngestionModel.copySelectedToPasteboard`
  (`IngestionModel.swift:1513`) → `copyToPasteboard(assets:)` (`:1500`) →
  `AssetPasteboardWriter.write` (`AssetPasteboard.swift:122`), which puts blob
  **file URLs** on the board (plus an `NSImage` for a single selection, or text for
  a media-less color/link/tweet). Nothing app-private goes on with it.
- **Grid ⌘V is the generic importer.** The hidden shortcut button
  (`CollectionView.swift:242`) calls `paste()` (`:798`) → `DirectInputReader.inputs(
  from:into:)` → `dispatch` → `IngestPipeline` → `AppServices.ingest`. It cannot
  tell our own clipboard from a file copied in Finder, because nothing on the board
  says so.
- **The re-import lands as a fresh local capture.** The file-URL branch wins, so the
  paste is a `fileInput` (`DirectInputReader.swift:48`): `platform: .localDrag`,
  `originalURL: nil`, `raw_metadata.original_path` = the blob's own path.
- **Dedup rescues only some of it.** `findDuplicate` (`AppServices.swift:2953`)
  matches on blob hash **plus provenance** — same `original_url` when one is given,
  else same `platform`:

  | the copied asset's source | grid ⌘C → ⌘V result |
  | --- | --- |
  | `.localDrag` / `.localPaste` (arrived as a file) | dedup **hits** — the same asset row is reused, only a membership is added. Nothing lost. |
  | `.web`, `.twitter`, extension capture… | dedup **misses** (incoming platform is `.localDrag`) — **new** asset + **new** source row |

  In the miss case the copy loses `asset.note`, its tags, and the source's
  `original_url` / `author` / `title`; `created_at` becomes now; analysis and
  embeddings re-run for a byte-identical image. The blob is shared by hash so no
  disk is wasted, and a second paste dedups against the first, so it is one
  duplicate — not one per paste.
- **The internal paths never had this problem.** Drag carries `AssetDragPayload`
  (asset ids + source collection) and drops route to `moveAssets` / `addAssets`
  (`IngestionModel.swift:1031`, `:1582`) — a second *membership* of one asset, so
  there is nothing to preserve. Board ⌘C/⌘V likewise carries `SpaceElementPayload`
  with `assetID` and pastes a second *placement*.
- **`handleDrop` already encodes the precedence we want.** It refuses providers
  carrying `.assetIDs` (`CollectionView.swift:807` comment) precisely because
  importing our own promised file would duplicate the asset. The paste path has no
  equivalent check — it has nothing to check for.

## The fix — 065's dual representation, outside Spaces

### A — ⌘C writes the app-private payload too

`copyToPasteboard(assets:)` gains the private write, so every surface that already
routes through it (collection grid, search grid, item detail — the 052 · 4A
unification) gets it at once:

```
AssetPasteboardWriter.write(…)                     // clears + writes file URLs / text
NSPasteboard.general.setData(payload, forType: …)  // then the private representation
```

Order is load-bearing for the same reason 065 §2.4 calls out: `write` calls
`clearContents()`, so the private data must go on **after** it — exactly the shape
of `SpaceView.copyElementsToPasteboard` (`SpaceView.swift:735`).

`AssetDragPayload` is the payload to reuse rather than inventing a second one: it is
already `{assetIDs, sourceCollectionID}`, already declared in `Info.plist`, already
decodable straight off an `NSPasteboard` (`AssetDragPayload.decode(from:)`), and
already has an `AssetDragPayload.nilSourceID` sentinel for the surfaces with no
owning collection (search, `SpaceContent`). The clipboard wants the identical facts.

**The private payload carries the whole selection**, including assets the byte
representation had to skip — a media-less `.unknown`, or an image whose blob is
missing. Pasting by id needs no bytes, so ⌘C→⌘V starts working for items that
cannot be copied out of the app at all today.

### B — ⌘V checks it first

`paste()` gets the 065 §2.5 branch order:

```
1. our own AssetDragPayload  → addAssets into the paste target
2. importable external content → unchanged (files, images, URLs)
```

Branch 1 must be first for the reason 065 gives: our representation is the most
specific thing on the board, and branch 2 will happily consume the weaker file URL
sitting next to it. Same-collection paste stays a no-op — `addAssets` ensures one
membership — and should say so rather than appearing to do nothing.

`SpaceView.pasteOntoBoard` (`SpaceView.swift:751`) gains the same branch between its
existing 1 and 2, so copying in the grid and pasting onto a board places the asset
instead of re-importing it.

Nothing about the external representation changes: Figma, Finder and Photoshop keep
receiving the file URLs they receive today.

## Schema / migration impact

**Zero.** No new types, no `Info.plist` change (`com.ref-atelier.asset-ids` is
already exported), no service change — branch 1 calls `addAssets`, which undo and
the drag path already use.

## Phased implementation

1. **C1 (S) — the dual write.** `copyToPasteboard(assets:)` writes
   `AssetDragPayload` after `AssetPasteboardWriter.write`; the whole selection, not
   just the copyable entries. Callers pass their source collection (or
   `nilSourceID`).
2. **C2 (S) — grid paste branch.** `paste()` decodes the payload first and routes to
   `copyToCollection(assetIDs:to:from:)`; falls through to the importer otherwise.
3. **C3 (S) — board paste branch.** The same check inside `pasteOntoBoard`, between
   `SpaceElementPayload` and `importExternal`.

## Test strategy

- `AssetPasteboardTests`: both representations present after a copy; the file URL is
  still the first/preferred type for external receivers; a selection whose entries
  are all skipped (media-less, missing blob) still writes the private payload.
- Paste routing (pure decode + branch, no DB): our payload wins over a board that
  also carries file URLs; a Finder-copied file still takes the import branch; an
  empty/absent payload cannot stop the chain (065's `nil`-not-empty rule).
- Service level: cross-collection paste adds exactly one membership and leaves
  `asset.note` / tags / `source` / `created_at` untouched; same-collection paste is a
  no-op; undo restores.
- Regression: paste a `.web`-sourced asset into another collection and assert the
  asset **id is unchanged** — the exact failure this doc exists for.

## Effort: **S** (three small edits on existing seams; zero schema)

## Risks & edge cases

- **A promiscuous external receiver preferring the private type.** It conforms to
  `public.data`, so a receiver that accepts anything could pick it over the file
  URL. Writing it last (and as its own representation) keeps the URL preferred;
  verify against the usual three targets before shipping.
- **The copy report's denominator.** `CopyReport` counts entries the *byte*
  representation could produce, so a selection with one `.unknown` reports "skipped"
  while an in-app paste would restore all of them. See open question 1.
- **Paste target resolution.** `importTargetID` already resolves Unsorted and the
  non-writable cases for the import branch; branch 1 must use the same target rather
  than growing its own rule.
- **Stale ids.** A copy, then a delete, then a paste: `addAssets` must fail closed on
  a missing asset id and report it, not throw at the user.

## Open questions — closed

1. ~~Copy report wording when the two representations disagree?~~ **Kept about the
   external copy.** `ExportSelection.considered` is `entries.count + skipped`
   (`AssetPasteboard.swift:35`) — the byte representation's denominator, which is
   the honest number for Figma and Finder.
2. ~~⌘V into the *same* collection: no-op with a notice, or move to the end of the
   manual order?~~ **No-op with a notice.** `resolvePaste` returns
   `.alreadyMembers` when `payload.sourceCollectionID == target`, and `paste()`
   calls `model.reportAlreadyInCollection()` (`CollectionView.swift:948`, `:983`).
3. ~~Does ⌘⌥V ("paste as new copy") earn its keystroke?~~ **Not built**, and
   deliberately: a genuinely independent asset row is what the
   [081](081-backup-plan.md) export/import round trip is for. No binding exists in
   `KeyMap`.
