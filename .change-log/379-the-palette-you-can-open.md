# 379 — The Palette You Can Open

[085](../.docs/085-color-filter-plan.md) · C3, the last phase: a toolbar palette
that STARTS a color filter, and the `SearchRules` bump that lets one be saved.

## 1 · A filter you could only reach from an answer

Every other search dimension can be typed. A tag or a collection prefix-matches in
the suggestion dropdown and becomes a token. **A color cannot** — a swatch has no
text, `refreshSuggestions` only ever fetched tags and collections, and nothing
resolved the word "teal" to a bucket.

So after [377](377-the-swatch-you-can-click.md) the only way to make a `.color`
token was to already be looking at a picture that had that color. You could ask
"more like this one", never "show me the teal ones" — a filter reachable only from
an answer, never from a question.

`ColorFilterPicker` is a toolbar palette glyph opening the twelve buckets as toggle
chips. Each one toggles the SAME token the detail row and the search field use, so
the picker, the chip and the query are three views of one piece of state — the rule
`FavoritesFilterChip` already follows.

**On every pane, unlike the favorites star.** That star is collection-screens-only,
justified in a comment as "there the filter is reached by the token like any other."
It is not — `liveSuggestions` returns tags and collections, so favorites has no
typing route either and is simply unreachable on the gallery today. Whatever that
is worth for favorites, the argument cannot transfer to color: without this button
there is no first home for it to compete with.

**The chips draw `referenceHex`, not an image's color** — the opposite of the detail
row, and deliberately. This chip says what the BUCKET means, because there is no
picture in front of it to mean anything else.

### `ColorPalette.filterOrder`

The picker lays out neutrals first, then the wheel, with brown beside the orange it
darkens. Written out rather than taken from `allCases`: `ColorBucket`'s raw values
are allocation order and the enum says so — "never a sort key" — because renumbering
a case re-labels stored rows. Laying the picker out by `allCases` reads exactly that
forbidden meaning into them, and the next bucket added lands wherever its number
falls rather than where it belongs to the eye. A test fails if a new case is not
placed here, which is the point: adding a color should make someone decide where it
goes.

## 2 · `SearchRules` v2 — and the favorites field that was never there

`SearchRules`' own header claims its fields map 1:1 onto `searchAssets`' filter
arguments, "so a new `searchAssets` capability can't silently drift out of sync."
**It had drifted.** `favoritesOnly` has been a `searchAssets` argument since 011 and
the rules blob never carried it, so a saved search meaning "my favorite pins"
returned every pin. `evaluate` dropped it on the floor, and nothing failed.

v2 adds `favorites_only`, `color_buckets` and `color_match` in one bump — a second
version bump for a single boolean is worse than carrying it here.

- **Buckets are raw integers.** AtelierCore cannot see the palette (085 — Ingestion
  owns the shape, Core stores it opaquely). A value no palette version defines
  matches nothing, which IS the degrade; there is no range for this package to
  validate.
- **`colorMatch` defaults to `.any`** where `tagMatch` defaults to `.all`, so its
  unknown-token fallback had to be read off the right field. Degrading to `.all`
  would silently narrow a rule the writer meant to widen.
- **`minimumColorCoverage` is NOT a rule field.** The coverage floor is a tuning
  constant like the FTS ranking weights, not part of what a saved search means.
  Storing it would bake today's 0.15 into every blob and make retuning it a data
  migration.
- **A malformed bucket array drops the color dimension whole** rather than
  salvaging the integers out of `[3,"red",9]` — the writer meant one set, and half
  of it is a filter nobody asked for.

`dedupe` became generic so tag ids and color buckets share ONE normalization rule.
Two copies would be two rules free to diverge, and a multi-valued dimension that
canonicalized differently from its neighbour breaks `canonicalBlob`'s promise for
one field only.

**The v1 blob is what is on disk today**, and it must keep meaning what it meant: an
absent key is no filter, never "favorites only" and never "matches nothing". That is
the one compatibility case with real stored data behind it, and it has its own test.

## 3 · Tests — Core 26 codec (was 21) + 29 saved-search (was 23), Ingestion 34 (was 32), +6 app

- **`SearchRulesTests`** — the v1-blob inertness above; the key-set pin grown to the
  three new keys with `minimum_color_coverage` added to the excluded list; a bucket
  integer this build has no meaning for round-tripping anyway; the malformed array;
  `colorMatch` degrading to `.any` and not `.all`.
- **`ServicesSavedSearchTests`** — the two dimensions `evaluate` was dropping, each
  mapped; `.all` vs `.any`; an unknown bucket matching nothing rather than throwing;
  the inherited coverage floor; and a rule that survives STORAGE and still filters,
  which round-tripping in memory would not catch.
- **`ColorPaletteTests`** — `filterOrder` covers every bucket exactly once, and is a
  deliberate order rather than raw-value order.
- **`LibrarySearchModelTests`** — per-bucket selection, the button's any-color
  state, a tag token NOT lighting the palette button, and "Clear colors" leaving the
  rest of the query standing.

**One of these was vacuous when first written.** "Clear colors with nothing to clear
leaves `tokens` untouched" compared the array before and after — but `removeAll` on
a `@Published` array emits whether or not it removes anything, and the values are
equal either way. It now counts `objectWillChange` emissions, which is what the
guard actually exists to prevent: a query re-run every time someone opens a popover.

Mutation-verified: unforwarding the two rules in `evaluate` fails 7 expectations;
`colorMatch` falling back to `.all` fails 1; `hasColorFilter` reading `!tokens.isEmpty`
fails 2; `isColorSelected` ignoring its argument fails 1.

`verify.sh full` — all six Swift stages green. The Extension stage fails on
fixture staleness (drift fixtures 39d and 27d old against 30d/14d limits), which
predates this branch and touches no code here.

## Files changed

- `AtelierCore`: `Services/SearchRules.swift`, `Services/AppServices.swift`,
  `SearchRulesTests`, `ServicesSavedSearchTests`
- `AtelierIngestion`: `Imaging/ColorPalette.swift`, `ColorPaletteTests`
- `AtelierRefs`: `ColorFilterPicker.swift` (new), `LibrarySearch.swift`,
  `LibrarySearchModelTests`

## Migration notes

**No schema change.** `SearchRules.currentVersion` → 2; v1 blobs on disk decode
with the new dimensions inert and keep their own stored version, so nothing
re-writes and nothing is badged. A rule saved by this build carries `version: 2`,
which an OLDER build would badge via `referencesUnknownVersion` — the intended
behaviour, and the reason that flag exists.

`ColorPalette.version` is unchanged at 2: `filterOrder` is presentation only and
changes no assignment, so nothing re-derives.
