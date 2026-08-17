# 410 — a cover almost nobody set

[409](409-the-rhythm-that-decomposed.md) shipped the phone's switcher with a note against
itself: 093 § 2 asks each row to carry a thumbnail, and the rows carry none, because the
read was not there. This is that read.

`collectionCovers(_:)` answers "which collections have a cover", and a cover is a thing the
user has to have **set**. Nothing sets one by default — `setCollectionCover` is a menu item
— so on a real library the honest answer for almost every collection is *none*, and a
surface that draws only what that returns draws a column of placeholders. The Mac never
noticed, because its gallery card asks a second question when the first comes back empty:
`collectionStackPreviews(limit:includeUnsorted:)`, the fan of three.

So the fallback already exists in this codebase; it just is not stated anywhere a second
caller could reach it.

## Stated once, in the read, opt-in

`collectionCovers(_:fallingBackToRecent:)`. With the flag on, a collection with no
surviving cover maps to its most recently added byte-backed, non-archived member.

It reaches for `stackPreviews(…)` with `limit: 1` — the *same* window query the fan card
uses, asked for one row per collection instead of three — deliberately rather than writing a
second "newest member" query. Two queries meaning "which item represents this collection"
is one query with a copy that will disagree the first time either grows a predicate, and
the predicates here are exactly the ones that have already been got wrong once
(`archived_at IS NULL`, `blob_hash IS NOT NULL` — see 023 · A and
[`ServicesShelfReadTests.swift:168`](../AtelierCore/Tests/AtelierCoreTests/ServicesShelfReadTests.swift)).
Now the phone row and the Mac fan cannot pick different pictures for the same folder.

**Off by default, and that is the load-bearing part.** The gallery card wants an explicit
cover first and a fan of three second; those are two slots with different meanings, and a
defaulted-on fallback here would quietly fill the first with what the second is for — no
call site edited, no test failing, the card just stops showing fans. The one existing caller
(`IngestionModel.swift:3096`) is untouched and keeps the shape it was measured with.

A collection with **no byte-backed member at all** is still absent from the result, under
the flag as without it. That is what lets a caller tell "empty" from "unset" and draw a
folder glyph rather than an empty frame — a colour-swatch-only collection has no bytes to
show and must read as empty here, not as broken.

## Verification

Four tests, in the file that already owns this surface. None of the existing three were
edited, so the default path is pinned unchanged by the same assertions as before.

| the rule | the test |
|---|---|
| newest byte-backed member wins | `fallsBackToRecentMember` |
| an explicit cover beats the fallback | `explicitCoverWins` |
| no byte-backed member ⇒ still absent | `emptyCollectionStaysAbsent` |
| an archived member cannot be the fallback | `archivedMemberExcluded` |

`fallsBackToRecentMember` asserts the default is `nil` for the same collection first, so it
cannot pass by the fallback being on when it should not be.

## Files

    AtelierCore/Sources/AtelierCore/           `collectionCovers(_:fallingBackToRecent:)` —
      Services/AppServices.swift               new defaulted parameter; uncovered ids go
                                               through `stackPreviews(… limit: 1)`

    AtelierCore/Tests/AtelierCoreTests/        +4 tests and a local `ingest` helper for a
      ServicesSpaceTests.swift                 byte-backed capture into a collection

## Migration notes

None. The parameter is defaulted to `false` and every existing call keeps its exact
behaviour and its exact result. The UI that consumes the flag is not in this commit — the
switcher rows are still text-only until it lands.
