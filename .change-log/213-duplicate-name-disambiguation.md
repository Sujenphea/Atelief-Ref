# 213 · Auto-disambiguate duplicate sibling names (043 open item 2 · policy 2c)

## Summary

Resolves the two 043 open items. **Gallery reorder scope (1b):** no change —
Home cards stay nest-drop-only; the sidebar tree remains the reorder surface (a
sidebar reorder already reflects on Home via shared `sortIndex`). **Duplicate
names (2c):** creating or renaming a folder to a name a sibling already has now
auto-suffixes Finder-style ("Refs" → "Refs 2" → "Refs 3") instead of leaving two
indistinguishable rows.

## What changed

- **`Validation.uniqueCollectionName(_:among:)`** (new, pure) — returns `desired`
  unchanged when free; on a collision appends the smallest ` N` (N ≥ 2) not
  already taken. An already-numbered desired name ("Refs 2") has its trailing
  index stripped first (`strippedTrailingIndex`) so a family collapses onto one
  base rather than nesting ("Refs 2 2"). Case-insensitive match; the desired
  name's own casing is preserved. GRDB-free, unit-tested in isolation.
- **`AppServices.createCollection`** — disambiguates against live sibling names
  INSIDE the write transaction (after the parent-exists check), so a race can't
  slip two identical names in.
- **`AppServices.renameCollection`** — disambiguates against the OTHER siblings
  under the folder's current parent (excludes self, so a no-op rename to the
  current name doesn't drift to " 2").
- **`AppServices.siblingNames(_:excluding:in:)`** (new private helper) — the
  per-parent name list feeding the above.

## Scope / limitation

Disambiguation runs where a name is CHOSEN — create and rename. `moveCollection`
is deliberately untouched: moving is about position/hierarchy, not naming, and
silently renaming a folder mid-drag would be surprising. So dragging "Refs" into
a parent that already has a "Refs" produces a same-name pair (still safe — they
differ by id, and the list tie-breaks by id). If move-collision handling is
wanted, that's a follow-up.

## Tests

- `ServicesValidationTests` — 7 pure cases: no-collision passthrough, first
  collision (` 2`), walking a taken sequence, filling a gap, numbered-base
  collapse, case-insensitivity, and the ` 0`/` 1` floor.
- `ServicesFolderTests` — 4 service cases: create auto-suffix (incl.
  case-insensitive), no-collision across different parents, rename onto a
  sibling, and rename-to-self is a no-op (no drift).
- `ServicesReadTests.listTieByID` — adapted: the name tie is now built across two
  parents (per-parent disambiguation keeps both "Dup"), still asserting the
  id-stable tie-break. Full suite green (451 AtelierCore + app build).
