# 419 — a number is an index when its base is there

[418](418-thirty-one-years-in-the-future.md) recorded a wart and left it: importing the
phone's "Atelier 2026-08-17 2005" twice produced "Atelier 2026-08-17 **2**". This fixes it,
in the rule rather than in the folder name.

## The ambiguity, and what resolves it

`Validation.uniqueCollectionName` stripped a trailing integer before numbering a copy, so
duplicate families collapse onto one base — "Refs 2" duplicated becomes "Refs 3", not
"Refs 2 2". Sound, and wrong for every name whose last word happens to be a number:
"Refs 2005" became "Refs 2", the year silently discarded.

**Nothing in the string says which it is.** "Refs 2" and "Refs 2005" have the same shape;
one number is a copy index and one is a year, and no regex separates them.

The siblings do. **A number is a copy index when the thing it would be a copy OF is
sitting beside it.** So the strip now happens only when the stripped base is itself a name
this parent has:

| desired | siblings | before | now |
|---|---|---|---|
| `Refs 2` | `Refs`, `Refs 2` | `Refs 3` | `Refs 3` |
| `Refs 2005` | `Refs 2005` | `Refs 2` | **`Refs 2005 2`** |
| `Refs 2005` | `Refs`, `Refs 2005` | `Refs 2` | `Refs 2` |
| `Atelier 2026-08-17 2005` | itself | `Atelier 2026-08-17 2` | **`Atelier 2026-08-17 2005 2`** |

Row 2 and row 3 differ ONLY in the siblings, which is the whole idea: the same string is
an index in one library and a year in another, and the parent is what knows.

Two lines of code. The change is which name the numbering walks from.

## The corner it accepts

"Refs 2" duplicated when there is no "Refs" beside it now nests: **"Refs 2 2"**. Deliberate
— with no base beside it, "Refs 2" is just a name, and the alternative is the guess that
loses years. Pinned by a test so it is a decision rather than a surprise.

## Verification

`AtelierCore` 771/106 — the four existing cases unchanged (the family collapse, the gap
fill, the case-insensitive match, the ` 0`/` 1` floor), two new ones for the rule and its
corner. The whole `AtelierRefsTests` suite, where the destination-naming behaviour is
exercised end to end by both archive round trips, is green; S6c's
`importingTwiceCollapses` now asserts the real name instead of merely "different".

## Files

    AtelierCore/Sources/AtelierCore/Services/     the two lines, and why
      Validation.swift
    AtelierCore/Tests/AtelierCoreTests/           2 tests: the rule, the corner
      ServicesValidationTests.swift
    AtelierRefs/AtelierRefsTests/                 asserts the name it now gets
      InboxArchiveImportTests.swift

## Migration notes

None — naming is computed at create/rename time and nothing stored changes. Collections
already named "Refs 2" by the old rule keep their names; only future duplicates differ.
