# 399 — exclusions are not a design

The user asked what the iOS app looks like. The answer was that nobody had decided.
[091](../.docs/091-ios-companion-overview.md) settled that the companion is not a
port, and [092](../.docs/092-ios-companion-plan.md) · S5 describes the phone's UI
entirely by subtraction — *"a `LazyVGrid` … No `UICollectionView` bridge. No
Spaces, no canvas, no reorder, no multiselect"*. That is a scope. It says nothing
about what a person sees.

[093](../.docs/093-ios-visual-design.md) decides three things, now rather than
inside S4b: what the share sheet does, what replaces the sidebar, and whether the
phone's grid keeps the Mac's rhythm. No code changed.

The timing is the argument. S4b writes the first UI this product has ever shown on
a phone, in the same slice that invents two Xcode targets and the entitlement
paperwork — and every default answer is one line long. A stock extension form, a
`NavigationSplitView` that collapses to something, `LazyVGrid` with a fixed
`GridItem`. Each of those quietly re-decides something the desktop argued about
across thirty-nine documents.

## The share sheet posts and dismisses

091 · D2 already forces most of this: the extension never opens SQLite, so it
cannot show a real collection list without a second copy of the collection tree
living in the App Group — the exact drift S0 was written to prevent for
provenance. But that is an architecture argument, and the doc makes the UX one
separately, because a constraint that happens to agree with good design is still
worth checking.

A share sheet interrupts a different app. Post-and-dismiss is one tap and a
second; a picker asks for a filing decision at the moment the user has the least
context — one item in hand and no view of the collection it would join. Filing is
a comparison and there is nothing to compare against. That is 091 · D1's thesis at
the level of a screen: capture happens where you are, curation happens at a desk.

What the user sees is `ToastCard`'s recipe with the buttons removed — `surface` at
`Radius.card`, a `hairline` border, `Elevation.hover` — reading **"Saved to
Unsorted"**, the same sentence the Mac's capture toast writes. "Saved" is a small
lie, since at that instant the item is an inbox record rather than an asset, and
the doc argues for keeping it: the record is committed (S2's record-as-commit-
marker), and the word describes the outcome the user is owed rather than the
mechanism.

Failure collapses to one card, not four, because `InboxWriteError`'s own doc
already proves it can: every case is a lost capture and none leave anything
partial. It uses `Colors.warning` — the app's single alarm colour — and it does
**not** auto-dismiss, since a failure nobody had time to read is a silent failure
with extra steps. No retry button either: all four cases are conditions a second
attempt hits again, and re-sharing is a retry the user already knows.

Sharing the same thing twice shows the same card twice and produces one asset. The
extension cannot know it is a duplicate — it has no database, which is the whole
point of D2 — and the doc declines to build a phone-side check. It would need a
hash set maintained by the host in the App Group: a second copy of a fact the
library owns, kept in sync across two processes, to warn about an outcome that is
already correct.

## The sidebar reduces to exactly one thing

Subtracting v1's exclusions from the Mac sidebar is the whole navigation decision.
Spaces are out per S5. Capture is not a screen — it is a pairing token and endpoint
status for a *browser* extension, and the phone has no browser. Archived goes with
the archive round-trip. Sort and trash are writes, and v1 browse is read-only.
Settings has nothing to configure.

One survivor: the collections tree. A navigation container built to hold one
destination type is a picker, not a container — so no tab bar (a two-tab
"Library / Collections" is a filter in costume) and no collections list as the
root (it puts a screen of folder *names* between the user and the artwork on every
cold launch, to answer a question the phone user usually is not asking).

The grid is the root, opening on Unsorted because that is where every share lands;
the title is the collection switcher, presenting the tree as a sheet ordered by
`CollectionTargets.galleryRoots`, the app's existing single ordering authority.

## Round-robin was the gift

The interesting finding. `LazyVGrid` does uniform rows, so S5 as written silently
changes what the library *looks* like — same content, different rhythm — and
`MasonryLayout`'s own header records that it *replaced* a uniform `.adaptive`
`LazyVGrid`. Reverting that on a surface showing the same content is undoing a
decision, not deferring one.

But the Mac's masonry is **round-robin fixed-column** — item `i` lives in column
`i % C` — not shortest-column-first packing. Column membership is therefore a
function of the index alone, so the layout decomposes: column `c` is
`stride(from: c, to: n, by: C)`, stacked with the same spacing and each cell
`columnWidth / aspect` tall. An `HStack` of `C` `LazyVStack`s reproduces the exact
frames with no solver ported, no custom `Layout`, no collection-view bridge, and
laziness intact per column. The rhythm survives because of how it was originally
chosen.

The portability audit behind that is deliberately unflattering to the obvious
route. `MasonryLayout.swift` is 129 lines of pure arithmetic that ports free.
`MasonryLayoutCache` ports and is pointless — it exists for the marquee, and there
is no marquee. `MasonryCollectionLayout` contains no masonry math at all by its own
header; it is a rect-query adapter plus one invalidation rule, i.e. exactly the
bridge S5 forbids. `MasonryGridHost`'s 2,113 lines are selection, ⌫/⌘⌫, ⌘C, Quick
Look, ⌘±, drag payloads and a context menu — every one excluded by S5. So the split
is 129 portable lines inside ~2,400 lines of interaction v1 does not have.

A SwiftUI custom `Layout` was the tempting middle option, and the repo already
ships one (`TagFlowLayout`). It loses on laziness: a `Layout` receives `Subviews`,
so a 2,000-item collection builds 2,000 cells, which is the shape
[038](../.docs/038-grid-bakeoff-results.md) measured at p95 50.90 ms against a
16.67 ms budget. The doc is explicit that it is **not** re-running the 037–039
bake-off on iOS — S5 excludes it — and that the point is only to avoid walking
back into the shape that lost. If the column stacks turn out not to stay lazy, the
fallback is uniform `LazyVGrid`: a rollback of a layout container, no protocol and
no gate document. That fallback is the reason to prefer them over the `Layout`,
whose failure mode has no fallback short of the forbidden bridge.

## Tokens, hover, and the dark

Most of `Theme.swift` crosses untouched — the palette is screen-size-independent,
the 4-pt spacing scale is a rhythm rather than a density, and the nine type roles
were written as *style plus weight, never a point size* specifically so Dynamic
Type works. That reasoning was recorded for a Mac, where the setting is obscure;
it pays off on the platform where people actually use it.

What does not cross is not about size but about input device and window.
`hoverRow` / `hoverControl` have no pointer to respond to, and the doc forbids
quietly repurposing them as press states — `hoverRow` is documented as a whisper
so it cannot be confused with `selection`, and a press wants to be unmistakable.
The `Theme.NS` mirrors have no `NSView` seam to feed and are governed by their own
rule (a mirror with no reader is a copy waiting to drift). `VisualEffectBackground`
exists so the desktop shows through window margins a phone does not have. And the
content panel splits in half: `Colors.panel` supplies the tone, while the
`Spacing.md` inset and `Radius.panel` clip stay on the desktop, because they are a
window idiom rather than a look.

Every hit area in the Mac app is undersized for a finger, and all the numbers are
already written down — 28 × 28 rail glyphs, a 30 × 28 hit area named in
`Radius.control`'s own comment, an 18pt `PostBadge` capsule whose doc says "fine
for a mouse, mean at a dense zoom". The rule is not to scale the tokens: visual
size stays on them, and the hit area becomes a separate 44 × 44 `.contentShape` —
the same separation `HoverHighlight` already makes.

Hover on the Mac is *storage* for affordances that would otherwise be permanent
chrome over the pictures: the cell dim, the enter-selection circle, the 150 ms GIF
dwell, 45 tooltip sites, the right-click menu. A phone cannot borrow that space, so
v1's answer is that those affordances do not exist yet rather than being relocated
onto the tile. When multiselect arrives, its entry is a long-press, not a visible
circle.

**The phone is dark only**, matching the Mac's `.preferredColorScheme(.dark)` — and
declaring `UIUserInterfaceStyle = Dark` in *both* Info.plists, since the share
extension is its own bundle and does not inherit the host's preference. A light
mode is not a variant of these tokens, it is a second design nobody has drawn, and
shipping half of one is how ink ends up on the wrong grey. The cost is stated
rather than hidden: a dark UI in direct sun is harder to read and the user cannot
fix it. If that bites, the fix is a light palette designed once for both platforms,
not an iOS-only fork of the token layer.

## Two open questions, left open

The doc marks what it cannot decide instead of inventing an answer. Whether v1
browse should have exactly **one** write — "move to collection" — is a product
call: post-and-dismiss puts the entire sorting cost on the Mac, and one write would
let the pile clear itself where the collection is actually on screen, at the price
of a stated D1 invariant. And the confirmation card's dwell before auto-dismiss is
a feel judgement to be set once on a device; the Mac's 6-second toast TTL is
obviously wrong for a process whose job is to get out of the way.

It also states its own boundary: the item detail screen's full layout, search,
empty states, iPad, and any iOS re-run of the grid bake-off are all explicitly not
designed here. One of those is worth pulling forward — 092 · S1 · decision 3 made a
missing App Group container a typed fatal error on purpose, and nothing currently
renders it.

## Files

    .docs/093-ios-visual-design.md    new — three decisions (share sheet,
                                     navigation, grid rhythm), the token
                                     carry-over audit, touch targets and the
                                     cost of losing hover, dark-only, an
                                     explicit not-designed list, two open
                                     questions

## Migration notes

None — documentation only. No source, test, manifest or project file changed, and
nothing is built. 093 is a `design` doc under `CLAUDE.md`'s flat scheme and takes
the next free index; no existing doc was renumbered. The cross-link from 092 · S5
to 093 is added separately.
